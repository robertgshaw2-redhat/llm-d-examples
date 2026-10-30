#!/usr/bin/env bash
# Coordinator P/D demo: each phase's EPP picks a (pod, DP rank) and vLLM runs
# the request on that rank.
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh
ensure_client
URL=http://dpc-coordinator:8080
PREFILL=$(pod_ip app=dpc-vllm,llm-d.ai/role=prefill)
DECODE=$(pod_ip app=dpc-vllm,llm-d.ai/role=decode)

echo "== 1. Distinct prompts spread across ranks (Envoy log: rank per phase)"
start=$(phase_log_lines dpc-envoy)
for i in 1 2 3 4 5 6; do chat "$URL" "Request $i: write one sentence about the number $i." >/dev/null; done
show_phase_log dpc-envoy "$start" 12

echo
echo "== 2. A shared long prefix sticks to one rank (prefix-cache-scorer per rank)"
PREFIX=$(printf 'You are a careful assistant. %.0s' $(seq 1 60))
start=$(phase_log_lines dpc-envoy)
for i in 1 2 3 4; do chat "$URL" "${PREFIX}Question $i: name a color." >/dev/null; done
show_phase_log dpc-envoy "$start" 8

echo
echo "== 3. vLLM per-engine counters (engine label = DP rank)"
echo "-- prefill pod $PREFILL"; engine_counts "$PREFILL" 8000
echo "-- decode pod $DECODE (prompt tokens come from external_kv_transfer: NIXL from prefill)"; engine_counts "$DECODE" 8000

echo
echo "== 4. EPP sees each rank as its own endpoint with its own scraped queue"
epp_endpoint_metric dpc-epp-decode llm_d_epp_per_endpoint_queue_size
