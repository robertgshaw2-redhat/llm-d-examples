#!/usr/bin/env bash
# KV events and per-rank load on a DP group spanning pods (DP=4, 2 per pod).
#  1. Each rank endpoint subscribes to its engine's KV events at 5557 + global rank.
#  2. A prompt warmed directly on one engine is routed back to that engine.
#  3. A flooded engine is avoided, from its own engine="<rank>" queue metrics.
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh
ensure_client
URL=http://dpk-coordinator:8080
ip() { "${K[@]}" get pod "$1" -o jsonpath='{.status.podIP}'; }
P0=$(ip dpk-prefill-0); P1=$(ip dpk-prefill-0-1); D0=$(ip dpk-decode-0)

# body PROMPT MAX_TOKENS: a chat completion request body.
body() { printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s}' "$MODEL" "$1" "$2"; }
# direct IP RANK PROMPT MAX_TOKENS: send straight to a pod's engine, bypassing the EPP.
direct() {
  "${K[@]}" exec dp-client -- curl -s -o /dev/null -m 600 "http://$1:8000/v1/chat/completions" \
    -H 'content-type: application/json' -H "x-data-parallel-rank: $2" -d "$(body "$3" "$4")"
}

echo "== 1. KV-event subscribers: one per rank endpoint, at 5557 + global rank"
"${K[@]}" logs deploy/dpk-epp-prefill -c epp | grep "Ensured KV-events subscriber" |
  sed -E 's/.*"endpoint":"[^/]+\/([^"]+)".*"zmq":"([^"]+)".*/  \1 -> \2/' | sort -u

echo
echo "== 2. A prompt warmed on one engine routes back to that engine (precise prefix cache)"
for rank in 2 0 3 1; do
  pod=$P0; [ "$rank" -ge 2 ] && pod=$P1
  text="Shared document $rank-$RANDOM. $(printf 'The quick brown fox jumps over the lazy dog. %.0s' $(seq 1 40))"
  direct "$pod" "$rank" "$text Summarize it." 1
  sleep 1
  start=$(phase_log_lines dpk-envoy)
  chat "$URL" "$text Summarize it." 1 >/dev/null
  echo "-- warmed on prefill engine $rank, routed to:"
  show_phase_log dpk-envoy "$start" 2 | grep prefill | sed 's/^/  /'
done

echo "-- KV-event batches received per subscriber"
epp_endpoint_metric dpk-epp-prefill llm_d_epp_kv_cache_events_messages_received_total | sed 's/^/  /'

echo
echo "== 3. A flooded decode engine is avoided (per-rank queue metrics)"
for i in $(seq 1 40); do direct "$D0" 0 "Flood $i: write a very long story about the sea." 1500 & done
sleep 15
echo "-- decode EPP per-rank queue while engine 0 is flooded"
epp_endpoint_metric dpk-epp-decode llm_d_epp_per_endpoint_queue_size | sed 's/^/  /'
start=$(phase_log_lines dpk-envoy)
for i in $(seq 1 6); do chat "$URL" "Request $i under load: name a fruit." 8 >/dev/null; done
echo "-- decode ranks picked for 6 new requests"
show_phase_log dpk-envoy "$start" 12 | grep decode | sed 's/^/  /'
kill $(jobs -p) 2>/dev/null || true
wait 2>/dev/null || true
