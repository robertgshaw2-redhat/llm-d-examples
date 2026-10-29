# Prefill/decode disaggregation with the vLLM Rust frontend and DP-rank routing

This example serves DeepSeek-V2-Lite with prefill/decode (P/D) disaggregation behind the
[llm-d router](https://github.com/llm-d/llm-d-router). Each vLLM pod runs two data-parallel (DP)
engine ranks behind one vLLM Rust frontend (`vllm-rs`). The router picks the pod and the DP rank
for every request and passes the rank to vLLM in the `X-data-parallel-rank` header.

- 1 prefill pod, 1 decode pod, `--data-parallel-size 2` each (4 GPUs in total)
- KV cache moves from prefill to decode over NIXL
- Clients send OpenAI `/v1/chat/completions` (streaming and non-streaming) to the coordinator

## Architecture

```
client
  |  POST /v1/chat/completions
  v
rdp-coordinator                     runs the prefill step, then the decode step
  |  each step calls back into Envoy with x-llm-d-epp-profile: prefill | decode
  v
rdp-envoy  --ext_proc-->  rdp-epp-prefill / rdp-epp-decode
  |                         picks a (pod, DP rank) endpoint and sets
  |                         x-data-parallel-rank: <rank>
  v
vllm-rs :8000 on the picked pod     sends the request to engine <rank>
  |
  +-- engine DP0 (GPU 0)
  +-- engine DP1 (GPU 1)
```

Each EPP lists every vLLM pod once per DP rank. The two entries for a pod have the same address
and port and differ only in a `dpRank` attribute:

```yaml
endpoints:
  - name: prefill-10-0-7-184-dp0
    address: "10.0.7.184"
    port: "8000"
    labels: {llm-d.ai/role: prefill}
    attributes: {dpRank: "0"}
  - name: prefill-10-0-7-184-dp1
    address: "10.0.7.184"
    port: "8000"
    labels: {llm-d.ai/role: prefill}
    attributes: {dpRank: "1"}
```

The EPP schedules over these entries as separate endpoints. After it picks one, the
`endpoint-header-stamper` plugin writes that entry's `dpRank` to `x-data-parallel-rank`:

```yaml
- type: attributes-producer
  parameters: {attributeKeys: [dpRank]}
- type: endpoint-header-stamper
  parameters:
    stamps:
      - {attributeKey: dpRank, headerName: x-data-parallel-rank}
```

The prefill EPP and the decode EPP each pick a rank on their own, so a request can prefill on
rank 0 and decode on rank 1.

## Files

| File | Contents |
|---|---|
| `vllm.yaml` | Prefill and decode Deployments running `vllm-rs serve` |
| `epp.yaml` | EPP configs and Deployments for prefill and decode |
| `render-endpoints.sh` | Writes the `rdp-endpoints` ConfigMap (one entry per pod per DP rank) from the live pod IPs |
| `envoy.yaml` | Envoy config: routes by `x-llm-d-epp-profile` to the right EPP |
| `coordinator.yaml` | Coordinator config: prefill step, then decode step, `kv-nixl` connector |
| `gateway.yaml` | Envoy and coordinator Deployments and Services |
| `deploy.sh`, `teardown.sh` | Apply and remove everything |
| `inference.proto` | vLLM v0.32.0 gRPC schema, for calling the pods' gRPC port directly |

## Prerequisites

- A Kubernetes cluster with 4 free NVIDIA GPUs, 2 on each node that runs a vLLM pod. The example
  was tested on H200s.
- Pull access to `docker.io/vllm/vllm-openai:v0.32.0`, `ghcr.io/llm-d/*` and
  `docker.io/envoyproxy/envoy`.
- Outbound access to Hugging Face to download the model (about 30 GB). The cache is an
  `emptyDir`, so each pod restart downloads again. Point `hf-cache` in `vllm.yaml` at a PVC or
  hostPath to keep the weights.

No Gateway API or InferencePool CRDs are needed: Envoy runs as a plain Deployment, and the EPPs
discover endpoints from a file.

## Deploy

```bash
# Uses the current kubectl context and namespace; override with CTX and NS.
./deploy.sh
```

`deploy.sh` applies `vllm.yaml`, waits for both vLLM pods to be ready, runs `render-endpoints.sh`,
then deploys the EPPs, Envoy and the coordinator. The first start takes several minutes (model
download, `torch.compile`, CUDA graph capture).

The endpoint files contain pod IPs. **Rerun `./render-endpoints.sh` whenever a vLLM pod restarts.**
The EPPs watch the file and reload it without a restart.

## Test

```bash
kubectl run rdp-client --image=curlimages/curl:8.10.1 --restart=Never --command -- sleep 86400

kubectl exec rdp-client -- curl -s http://rdp-coordinator:8080/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{"model":"deepseek-ai/DeepSeek-V2-Lite","messages":[{"role":"user","content":"Count from 1 to 5."}],"max_tokens":32}'
```

Add `"stream": true` to the body for server-sent events.

DeepSeek-V2-Lite is a base model, so replies to chat prompts ramble. To get chat-style answers,
change the model in `vllm.yaml` to `deepseek-ai/DeepSeek-V2-Lite-Chat`.

### Check the rank each phase used

The Envoy access log prints the rank the EPP picked for each phase:

```bash
kubectl logs deploy/rdp-envoy | grep profile=
```

```
/v1/chat/completions profile=prefill dprank=0 code=200 upstream=10.0.7.206:8000 dur=19ms
/v1/chat/completions profile=decode dprank=0 code=200 upstream=10.0.7.205:8000 dur=379ms
/v1/chat/completions profile=prefill dprank=1 code=200 upstream=10.0.7.206:8000 dur=13ms
/v1/chat/completions profile=decode dprank=1 code=200 upstream=10.0.7.205:8000 dur=376ms
```

### Check that vLLM honored the rank and that decode read KV from prefill

vLLM labels its metrics with `engine`. On the decode pod, every prompt token should come from
`external_kv_transfer`, split across both engines:

```bash
DECODE_IP=$(kubectl get pod -l app=rdp-vllm,llm-d.ai/role=decode -o jsonpath='{.items[0].status.podIP}')
kubectl exec rdp-client -- curl -s http://$DECODE_IP:8000/metrics \
  | grep -E '^vllm:(request_success_total|prompt_tokens_by_source_total)'
```

```
vllm:prompt_tokens_by_source_total{...,engine="0",source="external_kv_transfer"} 16
vllm:prompt_tokens_by_source_total{...,engine="1",source="external_kv_transfer"} 16
vllm:request_success_total{...,engine="0",finished_reason="length"} 2
vllm:request_success_total{...,engine="1",finished_reason="length"} 2
```

To pin a request to a rank by hand, send it straight to a pod with the header:

```bash
curl http://<pod-ip>:8000/v1/completions -H 'X-data-parallel-rank: 1' \
  -H 'content-type: application/json' \
  -d '{"model":"deepseek-ai/DeepSeek-V2-Lite","prompt":"hi","max_tokens":2}'
```

### Call the gRPC port

Each pod also serves the vLLM gRPC API (`vllm.Inference`) on port 50051. The rank goes in the
`x-data-parallel-rank` metadata key. The server does not support reflection, so pass the proto:

```bash
kubectl create configmap rdp-proto --from-file=inference.proto
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: rdp-grpcurl}
spec:
  restartPolicy: Never
  containers:
    - name: grpcurl
      image: fullstorydev/grpcurl:v1.9.1-alpine
      command: ["sleep", "86400"]
      volumeMounts: [{mountPath: /proto, name: proto}]
  volumes: [{name: proto, configMap: {name: rdp-proto}}]
EOF

kubectl exec rdp-grpcurl -- grpcurl -plaintext -import-path /proto -proto inference.proto \
  -H 'x-data-parallel-rank: 0' \
  -d '{"model":"deepseek-ai/DeepSeek-V2-Lite","text":"The capital of France is","stopping":{"max_new_tokens":4}}' \
  <pod-ip>:50051 vllm.Inference/Generate
```

## Limitations

- **The router reaches vLLM over HTTP, not gRPC.** The coordinator only sends HTTP to the
  gateway. The EPP's `vllmgrpc-parser` parses the `vllm.grpc.engine.VllmEngine` service of the
  Python gRPC server, not the Rust frontend's `vllm.Inference` service. The gRPC port is open on
  the pods but nothing in the router uses it.
- **Endpoints are listed by pod IP.** The EPPs use `file-discovery` instead of an InferencePool,
  because InferencePool discovery models DP as one port per rank and has no way to send the rank
  as a header. Rerun `render-endpoints.sh` after any vLLM pod restart.
- **Load balancing across ranks uses only the EPP's in-flight request counts.** Both entries for
  a pod scrape the same `/metrics`, and the EPP combines the per-engine series into one value per
  pod. Queue-depth and KV-cache-utilization scorers therefore see the same value for both ranks.
- **The EPP image is a pinned `main` build.** `endpoint-header-stamper` is not in llm-d router
  v1.0.0.
- **NIXL runs without RDMA.** `vllm.yaml` requests no RDMA devices, so KV moves over whatever UCX
  transport the nodes have. On clusters with InfiniBand or RoCE, add the RDMA device resource
  (for example `rdma/ib`), the `IPC_LOCK` capability, and `NCCL_IB_HCA` as the cluster requires.

## Teardown

```bash
./teardown.sh
```

## Versions

| Component | Version |
|---|---|
| vLLM | `vllm/vllm-openai:v0.32.0` (`vllm-rs serve`) |
| llm-d router EPP | `main` at `b6f93f55`, pinned by digest |
| llm-d router coordinator | `v1.0.0` |
| Envoy | `v1.33.2` |
