#!/usr/bin/env bash
# Writes the rdp-endpoints ConfigMap the EPPs read. Each vLLM pod appears once
# per DP rank: same address and port, dpRank attribute 0..DP_SIZE-1.
# Rerun whenever a vLLM pod gets a new IP.
#
# Uses the current kubectl context and namespace unless CTX or NS is set.
set -euo pipefail
DP_SIZE=${DP_SIZE:-2}
K=(kubectl ${CTX:+--context "$CTX"} ${NS:+-n "$NS"})

render() {
  local role=$1
  echo "endpoints:"
  for ip in $("${K[@]}" get pods -l app=rdp-vllm,llm-d.ai/role="$role" \
      -o jsonpath='{range .items[?(@.status.podIP)]}{.status.podIP}{"\n"}{end}'); do
    for ((r = 0; r < DP_SIZE; r++)); do
      cat <<ENTRY
  - name: $role-${ip//./-}-dp$r
    address: "$ip"
    port: "8000"
    labels: {llm-d.ai/role: $role}
    attributes: {dpRank: "$r"}
ENTRY
    done
  done
}

"${K[@]}" create configmap rdp-endpoints \
  --from-file=prefill.yaml=<(render prefill) \
  --from-file=decode.yaml=<(render decode) \
  --dry-run=client -o yaml | "${K[@]}" apply -f -
"${K[@]}" get configmap rdp-endpoints -o jsonpath='{.data}' |
  python3 -c 'import json, sys; [print(f"--- {k}\n{v}") for k, v in json.load(sys.stdin).items()]'
