#!/usr/bin/env bash
# Deploys the vLLM internal-LB demo into the current kubectl context and
# namespace (override with CTX and NS).
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh

"${K[@]}" apply -f ../common/rbac.yaml -f vllm.yaml
"${K[@]}" create configmap dpi-envoy --from-file=envoy.yaml --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" apply -f epp.yaml -f gateway.yaml
"${K[@]}" wait --for=condition=Ready pod -l 'app in (dpi-epp,dpi-envoy)' --timeout=600s
ensure_client
# Only the leader serves HTTP, so wait on its /health.
until "${K[@]}" exec dp-client -- curl -sf -m 3 "http://$(pod_ip app=dpi-vllm,leaderworkerset.sigs.k8s.io/worker-index=0):8000/health" >/dev/null 2>&1; do
  sleep 10
done
