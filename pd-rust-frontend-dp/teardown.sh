#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
K=(kubectl ${CTX:+--context "$CTX"} ${NS:+-n "$NS"})
"${K[@]}" delete --ignore-not-found -f gateway.yaml -f epp.yaml -f vllm.yaml
"${K[@]}" delete --ignore-not-found configmap rdp-envoy rdp-coordinator rdp-endpoints rdp-proto
"${K[@]}" delete --ignore-not-found pod rdp-client rdp-grpcurl
