# Shared helpers for the demo scripts. Uses the current kubectl context and
# namespace unless CTX or NS is set.
K=(kubectl ${CTX:+--context "$CTX"} ${NS:+-n "$NS"})
MODEL=${MODEL:-deepseek-ai/DeepSeek-V2-Lite}

ensure_client() {
  if ! "${K[@]}" get pod dp-client >/dev/null 2>&1; then
    "${K[@]}" run dp-client --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 86400 >/dev/null
  fi
  "${K[@]}" wait --for=condition=Ready pod/dp-client --timeout=120s >/dev/null
}

# chat URL PROMPT [MAX_TOKENS]: one non-streaming chat completion; prints the reply.
chat() {
  local body
  body=$(printf '{"model":"%s","messages":[{"role":"user","content":"%s"}],"max_tokens":%s}' "$MODEL" "$2" "${3:-16}")
  "${K[@]}" exec dp-client -- curl -s -m 120 "$1/v1/chat/completions" \
    -H 'content-type: application/json' -d "$body" |
    sed -n 's/.*"content":"\([^"]*\)".*/\1/p' | head -c 60
  echo
}

pod_ip() { "${K[@]}" get pod -l "$1" -o jsonpath='{.items[0].status.podIP}'; }

# engine_counts IP PORT: per-engine finished requests and prompt-token sources.
engine_counts() {
  "${K[@]}" exec dp-client -- curl -s "http://$1:$2/metrics" |
    grep -E '^vllm:(request_success_total|prompt_tokens_by_source_total)' |
    grep -v -E ' 0(\.0)?$' | sed 's/model_name="[^"]*",//' || true
}

# epp_endpoint_metric SERVICE METRIC: the EPP's per-endpoint series.
epp_endpoint_metric() {
  "${K[@]}" exec dp-client -- curl -s "http://$1:9090/metrics" | grep -E "^$2" || true
}

# phase_log_lines DEPLOY: number of request lines in the Envoy access log.
phase_log_lines() { "${K[@]}" logs "deploy/$1" | grep -c ' code=' || true; }

# show_phase_log DEPLOY START COUNT: waits for COUNT new access-log lines after
# START (Envoy flushes its log about once a second) and prints their routing fields.
show_phase_log() {
  for _ in $(seq 1 30); do
    [ "$(phase_log_lines "$1")" -ge $(($2 + $3)) ] && break
    sleep 1
  done
  "${K[@]}" logs "deploy/$1" | grep ' code=' | tail -n +$(($2 + 1)) |
    sed -E 's/^[^ ]+ [^ ]+ //; s/ code=[^ ]+ dropped=[^ ]+//; s/ dur=.*//'
}

# engine_success IP PORT: "engine count" lines of vllm:request_success_total.
engine_success() {
  "${K[@]}" exec dp-client -- curl -s "http://$1:$2/metrics" |
    grep -E '^vllm:request_success_total' | grep 'finished_reason="length"' |
    sed -E 's/.*engine="([0-9]+)".* ([0-9.e+]+)$/\1 \2/' | sort || true
}

# engine_delta BEFORE AFTER: per-engine difference of two engine_success outputs.
engine_delta() {
  join -a 2 -e 0 -o 0,1.2,2.2 <(echo "$1") <(echo "$2") |
    awk '{printf "  engine=%s ran %d\n", $1, $3 - $2}'
}
