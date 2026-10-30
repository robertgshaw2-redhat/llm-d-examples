#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
source ../common/lib.sh
"${K[@]}" delete --ignore-not-found -f gateway.yaml -f epp.yaml -f vllm.yaml
"${K[@]}" delete --ignore-not-found configmap dpx-envoy dpx-coordinator
