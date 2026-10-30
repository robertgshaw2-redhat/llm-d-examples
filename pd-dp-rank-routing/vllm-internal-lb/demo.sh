#!/usr/bin/env bash
# vLLM internal load balancing across pods: one Rust frontend on the leader for
# a DP=4 group whose engines 2 and 3 run headless on the worker pod. The EPP
# treats the leader as rank endpoints 0-3 and sends the global rank.
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh
ensure_client
URL=http://dpi-envoy:8081
L=$(pod_ip app=dpi-vllm,leaderworkerset.sigs.k8s.io/worker-index=0)
W=$(pod_ip app=dpi-vllm,leaderworkerset.sigs.k8s.io/worker-index=1)
body() { printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s}' "$MODEL" "$1" "$2"; }

echo "== 1. Requests go to global ranks 0-3, including engines on the worker pod"
before=$(engine_success "$L" 8000)
start=$(phase_log_lines dpi-envoy)
for i in $(seq 1 8); do chat "$URL" "Prompt $i: name a city." 8 >/dev/null; done
show_phase_log dpi-envoy "$start" 8 | sed 's/^/  /'
echo "-- requests per engine (leader /metrics):"
engine_delta "$before" "$(engine_success "$L" 8000)"

echo
echo "== 2. The leader's /metrics covers every engine, so a busy remote engine is avoided"
"${K[@]}" delete pod dpi-flood --ignore-not-found >/dev/null
"${K[@]}" run dpi-flood --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c \
  "for i in \$(seq 1 24); do curl -s -o /dev/null -m 900 http://$L:8000/v1/chat/completions \
     -H 'content-type: application/json' -H 'x-data-parallel-rank: 2' \
     -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Flood\"}],\"max_tokens\":3000,\"ignore_eos\":true}' & done; wait" >/dev/null
"${K[@]}" wait --for=condition=Ready pod/dpi-flood --timeout=120s >/dev/null
sleep 12
echo "-- running requests per engine (leader /metrics) while engine 2 is loaded directly:"
"${K[@]}" exec dp-client -- curl -s "http://$L:8000/metrics" | grep '^vllm:num_requests_running' |
  sed -E 's/.*engine="([0-9]+)".* ([0-9.]+)$/  engine=\1 running \2/' | sort
start=$(phase_log_lines dpi-envoy)
for i in $(seq 1 6); do chat "$URL" "Load $i: name a fruit." 4 >/dev/null; done
echo "-- ranks the EPP picked for 6 new requests:"
show_phase_log dpi-envoy "$start" 6 | grep -o 'dprank=[0-9]*' | sort | uniq -c | sed 's/^/  /'
"${K[@]}" delete pod dpi-flood --ignore-not-found --wait=false >/dev/null

echo
echo "== 3. KV events: engines publish on their own pod, but the EPP only knows the leader"
for ip in $L $W; do for p in 5557 5558 5559 5560; do
  "${K[@]}" exec dp-client -- sh -c "timeout 2 nc -z $ip $p 2>/dev/null && echo '  publisher listening on $ip:$p'; true"
done; done
echo "-- EPP subscribers:"
"${K[@]}" logs deploy/dpi-epp -c epp | grep "Ensured KV-events subscriber" |
  sed -E 's/.*"endpoint":"[^/]+\/([^"]+)".*"zmq":"([^"]+)".*/  \1 -> \2/' | sort -u
text="$(printf 'The quick brown fox jumps over the lazy dog. %.0s' $(seq 1 40))"
for r in 0 1 2 3; do
  "${K[@]}" exec dp-client -- curl -s -o /dev/null "http://$L:8000/v1/chat/completions" \
    -H 'content-type: application/json' -H "x-data-parallel-rank: $r" -d "$(body "Doc $r $RANDOM. $text" 2)"
done
sleep 3
echo "-- KV-event batches received per subscriber (ranks 2 and 3 never connect):"
epp_endpoint_metric dpi-epp llm_d_epp_kv_cache_events_messages_received_total | sed 's/^/  /'
