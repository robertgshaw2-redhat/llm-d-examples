#!/usr/bin/env bash
# Deploys the coordinator P/D demo into the current kubectl context and namespace
# (override with CTX and NS).
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh

"${K[@]}" apply -f ../common/rbac.yaml -f vllm.yaml
"${K[@]}" create configmap dpx-envoy --from-file=envoy.yaml --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" create configmap dpx-coordinator --from-file=coordinator.yaml --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" apply -f epp.yaml -f gateway.yaml
"${K[@]}" wait --for=condition=Ready pod -l app=dpx-vllm --timeout=1800s
