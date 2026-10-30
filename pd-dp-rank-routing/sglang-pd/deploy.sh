#!/usr/bin/env bash
# Deploys the sidecar P/D demo into the current kubectl context and namespace
# (override with CTX and NS).
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh

"${K[@]}" apply -f ../common/rbac.yaml -f sglang.yaml
"${K[@]}" create configmap dpq-envoy --from-file=envoy.yaml --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" apply -f epp.yaml -f gateway.yaml
"${K[@]}" wait --for=condition=Ready pod -l app=dpq-sglang --timeout=1800s
