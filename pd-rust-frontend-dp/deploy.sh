#!/usr/bin/env bash
# Deploys the example into the current kubectl context and namespace
# (override with CTX and NS).
set -euo pipefail
cd "$(dirname "$0")"
K=(kubectl ${CTX:+--context "$CTX"} ${NS:+-n "$NS"})

"${K[@]}" apply -f vllm.yaml
"${K[@]}" wait --for=condition=Ready pod -l app=rdp-vllm --timeout=1800s
./render-endpoints.sh
"${K[@]}" create configmap rdp-envoy --from-file=envoy.yaml --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" create configmap rdp-coordinator --from-file=coordinator.yaml --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" apply -f epp.yaml -f gateway.yaml
"${K[@]}" wait --for=condition=Ready pod \
  -l 'app in (rdp-epp-prefill,rdp-epp-decode,rdp-envoy,rdp-coordinator)' --timeout=300s
