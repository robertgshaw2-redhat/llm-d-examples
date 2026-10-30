#!/usr/bin/env bash
# Sidecar P/D demo: one EPP run picks a decode (pod, rank) and a prefill
# (pod, rank). The decode rank reaches the decode pod's sidecar as
# x-data-parallel-rank; the prefill rank reaches it as
# x-llm-d-prefiller-data-parallel-rank, and the sidecar sets it as
# x-data-parallel-rank on the prefill request.
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh
ensure_client
URL=http://dps-envoy:8081
PREFILL=$(pod_ip app=dps-vllm,llm-d.ai/role=prefill)
DECODE=$(pod_ip app=dps-vllm,llm-d.ai/role=decode)

prefill_before=$(engine_success "$PREFILL" 8000)
decode_before=$(engine_success "$DECODE" 8200)

echo "== 1. Each request: prefill rank and decode rank the EPP picked (Envoy log)"
start=$(phase_log_lines dps-envoy)
for i in 1 2 3 4 5 6; do chat "$URL" "Request $i: write one sentence about the number $i." >/dev/null; done
show_phase_log dps-envoy "$start" 6 | tee /tmp/dps-demo-log.txt

echo
echo "== 2. vLLM ran each phase on the rank the EPP picked"
echo "-- picked by the EPP:"
sed -nE 's/.*prefill_dprank=([0-9]+).*/  prefill rank \1/p' /tmp/dps-demo-log.txt | sort | uniq -c
sed -nE 's/.* dprank=([0-9]+).*/  decode rank \1/p' /tmp/dps-demo-log.txt | sort | uniq -c
echo "-- prefill pod $PREFILL, requests per engine:"
engine_delta "$prefill_before" "$(engine_success "$PREFILL" 8000)"
echo "-- decode pod $DECODE, requests per engine:"
engine_delta "$decode_before" "$(engine_success "$DECODE" 8200)"

echo
echo "== 3. Decode read the prompt KV from prefill over NIXL, on both engines"
engine_counts "$DECODE" 8200 | grep prompt_tokens_by_source

echo
echo "== 4. A shared long prefix sticks to one prefill rank and one decode rank"
PREFIX=$(printf 'You are a careful assistant. %.0s' $(seq 1 60))
start=$(phase_log_lines dps-envoy)
for i in 1 2 3 4; do chat "$URL" "${PREFIX}Question $i: name a color." >/dev/null; done
show_phase_log dps-envoy "$start" 4

echo
echo "== 5. Prefill and decode ranks are picked separately"
echo "Load decode engine 0 directly, so decode avoids it while prefill keeps alternating."
"${K[@]}" delete pod dps-flood --ignore-not-found >/dev/null
"${K[@]}" run dps-flood --restart=Never --image=curlimages/curl:8.10.1 --command -- sh -c \
  "for i in \$(seq 1 24); do curl -s -o /dev/null -m 900 http://$DECODE:8200/v1/chat/completions \
     -H 'content-type: application/json' -H 'x-data-parallel-rank: 0' \
     -d '{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Flood\"}],\"max_tokens\":3000,\"ignore_eos\":true}' & done; wait" >/dev/null
"${K[@]}" wait --for=condition=Ready pod/dps-flood --timeout=120s >/dev/null
sleep 10
prefill_before=$(engine_success "$PREFILL" 8000)
start=$(phase_log_lines dps-envoy)
for i in 1 2 3 4 5 6; do chat "$URL" "Split request $i: name a planet." >/dev/null; done
show_phase_log dps-envoy "$start" 6 | tee /tmp/dps-demo-split.txt
echo "-- ranks the EPP picked (prefill / decode):"
sed -nE 's/.*prefill_dprank=([0-9]+) dprank=([0-9]+).*/  prefill \1 \/ decode \2/p' /tmp/dps-demo-split.txt | sort | uniq -c
echo "-- prefill ranks the EPP picked:"
sed -nE 's/.*prefill_dprank=([0-9]+).*/  prefill rank \1/p' /tmp/dps-demo-split.txt | sort | uniq -c
echo "-- prefill pod $PREFILL, requests per engine (must match the prefill ranks above):"
engine_delta "$prefill_before" "$(engine_success "$PREFILL" 8000)"
"${K[@]}" delete pod dps-flood --ignore-not-found --wait=false >/dev/null
