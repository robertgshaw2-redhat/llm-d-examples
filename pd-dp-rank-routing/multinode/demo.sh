#!/usr/bin/env bash
# Multi-node coordinator P/D demo: each phase is a DP=4 group over two pods
# (2 ranks per pod). The EPP sends global ranks; each pod's vllm-rs runs the
# request on the engine with that global index.
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh
ensure_client
URL=http://dpm-coordinator:8080

echo "== Pods (LWS worker-index k serves global ranks 2k, 2k+1)"
"${K[@]}" get pods -l app=dpm-vllm -o custom-columns='POD:.metadata.name,ROLE:.metadata.labels.llm-d\.ai/role,WORKER:.metadata.labels.leaderworkerset\.sigs\.k8s\.io/worker-index,IP:.status.podIP' --no-headers | sort -k2,2 -k3,3

pods=$("${K[@]}" get pods -l app=dpm-vllm -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.podIP}{"\n"}{end}' | sort)
snap=$(mktemp -d)
while read -r name ip; do engine_success "$ip" 8000 >"$snap/$name"; done <<<"$pods"

echo
echo "== 1. Distinct prompts spread over global ranks 0-3 (Envoy log: rank per phase)"
start=$(phase_log_lines dpm-envoy)
for i in $(seq 1 8); do chat "$URL" "Request $i: write one sentence about the number $i." >/dev/null; done
show_phase_log dpm-envoy "$start" 16

echo
echo "== 2. Each pod ran requests only on its own global ranks (vLLM engine label)"
while read -r name ip; do
  echo "-- $name ($ip)"
  engine_delta "$(cat "$snap/$name")" "$(engine_success "$ip" 8000)"
done <<<"$pods"

echo
echo "== 3. Decode read the prompt KV from prefill over NIXL"
while read -r name ip; do
  case $name in *decode*) echo "-- $name"; engine_counts "$ip" 8000 | grep external_kv_transfer || true ;; esac
done <<<"$pods"

echo
echo "== 4. EPP endpoints: four per phase, each reading its own engine's queue"
epp_endpoint_metric dpm-epp-decode llm_d_epp_per_endpoint_queue_size
