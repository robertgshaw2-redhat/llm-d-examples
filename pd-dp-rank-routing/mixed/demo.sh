#!/usr/bin/env bash
# Mixed DP sizes demo: prefill DP=2 and decode DP=4 in one pool behind one EPP,
# each pod's rank count set by its llm-d.ai/data-parallel-ranks annotation.
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh
ensure_client
URL=http://dpx-coordinator:8080
PREFILL=$(pod_ip app=dpx-vllm,llm-d.ai/role=prefill)
DECODE=$(pod_ip app=dpx-vllm,llm-d.ai/role=decode)
prefill_before=$(engine_success "$PREFILL" 8000)
decode_before=$(engine_success "$DECODE" 8000)

echo "== 1. The EPP's endpoints: 2 for the prefill pod, 4 for the decode pod"
epp_endpoint_metric dpx-epp llm_d_epp_per_endpoint_queue_size

echo
echo "== 2. Requests: prefill cycles ranks 0-1, decode cycles ranks 0-3 (Envoy log)"
start=$(phase_log_lines dpx-envoy)
for i in $(seq 1 8); do chat "$URL" "Request $i: write one sentence about the number $i." >/dev/null; done
show_phase_log dpx-envoy "$start" 16

echo
echo "== 3. vLLM ran each request on the picked engine"
echo "-- prefill pod $PREFILL"; engine_delta "$prefill_before" "$(engine_success "$PREFILL" 8000)"
echo "-- decode pod $DECODE"; engine_delta "$decode_before" "$(engine_success "$DECODE" 8000)"

echo
echo "== 4. Decode read the prompt KV from prefill over NIXL, on all four engines"
engine_counts "$DECODE" 8000 | grep external_kv_transfer || true
