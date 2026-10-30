# P/D with DP-rank routing through the llm-d router

These demos run DeepSeek-V2-Lite with prefill/decode (P/D) disaggregation. Each vLLM pod runs the
vLLM Rust frontend (`vllm-rs serve --data-parallel-size 2`) in front of two engine ranks on **one
port**. The llm-d EPP picks a pod and a DP rank for each phase, and vLLM runs the request on that
rank.

The routing comes from llm-d-router branch
[`epp-dp-rank-header`](https://github.com/robertgshaw2-redhat/llm-d-router/tree/epp-dp-rank-header)
(issue [llm-d/llm-d-router#3757](https://github.com/llm-d/llm-d-router/issues/3757)):

| Piece | What it does |
|---|---|
| `llm-d.ai/data-parallel-size-local: "2"` (pod annotation) or `--data-parallel-size-local=2` (EPP flag, default for pods without the annotation) | Each pod becomes two endpoints, `<pod>-rank-0` and `<pod>-rank-1`, on its one target port. The value is the pod's vLLM `--data-parallel-size-local`. |
| `data-parallel-rank-header` (EPP plugin) | Writes the picked endpoint's rank to `x-data-parallel-rank`. vLLM sends the request to that engine. |
| Per-rank metrics | vLLM labels its metrics `engine="<rank>"`. Each rank endpoint reads only its own series, so queue and KV-cache scorers see each rank's load. |
| Per-rank scheduling state | In-flight counts and approximate prefix-cache state are kept per rank endpoint, so a shared prefix sticks to the rank that holds it. |
| `x-llm-d-prefiller-data-parallel-rank` | In sidecar P/D, carries the prefill rank to the decode pod's sidecar, which sets it as `x-data-parallel-rank` on the prefill request. |

The two demos differ in who runs the two phases.

```
coordinator/                                   sidecar/
client                                         client
  -> dpc-coordinator                             -> dps-envoy -> dps-epp (picks decode AND prefill rank)
       prefill call -> envoy -> dpc-epp-prefill        -> decode pod: routing sidecar :8000
            -> prefill pod :8000                            prefill request -> prefill pod :8000
               (x-data-parallel-rank: prefill rank)            (x-data-parallel-rank: prefill rank)
       decode call  -> envoy -> dpc-epp-decode              decode request  -> local vLLM :8200
            -> decode pod :8000                                (x-data-parallel-rank: decode rank)
               (x-data-parallel-rank: decode rank)
```

## Files

| Path | Contents |
|---|---|
| `common/rbac.yaml` | Role and service accounts the EPPs need for InferencePool discovery |
| `common/lib.sh` | Helpers the demo scripts share |
| `coordinator/` | vLLM pods, two InferencePools and EPPs (one per phase), Envoy, coordinator, `deploy.sh`, `demo.sh`, `teardown.sh` |
| `sidecar/` | vLLM pods (the decode pod runs the routing sidecar), one InferencePool and EPP with `disagg-profile-handler`, Envoy, `deploy.sh`, `demo.sh`, `teardown.sh` |
| `mixed/` | Coordinator P/D with prefill DP=2 and decode DP=4 in one InferencePool behind one EPP (`header-profile-handler`), rank counts set per pod with the `llm-d.ai/data-parallel-size-local` annotation, `deploy.sh`, `demo.sh`, `teardown.sh` |
| `kvevents/` | The `multinode/` layout with vLLM KV events and the precise prefix cache (token-producer with a `vllm launch render` sidecar), plus a per-rank load test, `deploy.sh`, `demo.sh`, `teardown.sh` |
| `multinode/` | Coordinator P/D where each phase is one DP=4 group over two pods (LeaderWorkerSet, 2 ranks per pod), EPPs with `--data-parallel-start-rank-label`, `deploy.sh`, `demo.sh`, `teardown.sh` |

## Prerequisites

- A Kubernetes cluster with the InferencePool CRD (`inference.networking.k8s.io/v1`) and 4 free
  NVIDIA GPUs per demo (2 per vLLM pod; 6 for `mixed/`, 8 for `multinode/` and `kvevents/`). Tested on H200s.
- For `multinode/` and `kvevents/`: the LeaderWorkerSet CRD (`leaderworkerset.x-k8s.io/v1`).
- Images:
  - `docker.io/vllm/vllm-openai:v0.32.0`
  - `ghcr.io/robertgshaw2-redhat/llm-d-router-endpoint-picker:dp-rank-a61396f6`, built from the
    branch above at `a61396f6` with `make image-build-epp TARGETARCH=amd64`
  - `ghcr.io/robertgshaw2-redhat/llm-d-router-disagg-sidecar:dp-rank-851a0215`, built at `851a0215`
    with `make image-build-sidecar TARGETARCH=amd64` (later commits do not change the sidecar)
  - `docker.io/vllm/vllm-openai-cpu:v0.31.0` for the `kvevents/` render sidecar
  - `docker.io/envoyproxy/envoy:distroless-v1.33.2`, `ghcr.io/llm-d/llm-d-router-coordinator:v1.0.0`
- Outbound access to Hugging Face for the model (about 30 GB per pod; the cache is an `emptyDir`).

NIXL runs without RDMA here. On clusters with InfiniBand or RoCE, add the RDMA device resource
(for example `rdma/ib`), the `IPC_LOCK` capability and `NCCL_IB_HCA` to the vLLM containers.

## Run

Each script uses the current kubectl context and namespace; set `CTX` and `NS` to override.

```bash
./coordinator/deploy.sh && ./coordinator/demo.sh
./sidecar/deploy.sh && ./sidecar/demo.sh
./mixed/deploy.sh && ./mixed/demo.sh
./kvevents/deploy.sh && ./kvevents/demo.sh
./multinode/deploy.sh && ./multinode/demo.sh
```

The demos send a few chat completions and print evidence. vLLM counters are cumulative, so run
counts grow across runs.

## Coordinator demo output

```
== 1. Distinct prompts spread across ranks (Envoy log: rank per phase)
profile=prefill dprank=0 upstream=10.0.5.41:8000
profile=decode dprank=0 upstream=10.0.0.192:8000
profile=prefill dprank=1 upstream=10.0.5.41:8000
profile=decode dprank=1 upstream=10.0.0.192:8000
...

== 2. A shared long prefix sticks to one rank (prefix-cache-scorer per rank)
profile=prefill dprank=0 upstream=10.0.5.41:8000
profile=decode dprank=0 upstream=10.0.0.192:8000
profile=prefill dprank=0 upstream=10.0.5.41:8000
profile=decode dprank=0 upstream=10.0.0.192:8000
...

== 3. vLLM per-engine counters (engine label = DP rank)
-- prefill pod 10.0.5.41
vllm:prompt_tokens_by_source_total{engine="0",source="local_cache_hit"} 2576
vllm:prompt_tokens_by_source_total{engine="0",source="local_compute"} 544
vllm:prompt_tokens_by_source_total{engine="1",source="local_compute"} 72
vllm:request_success_total{engine="0",finished_reason="length"} 14
vllm:request_success_total{engine="1",finished_reason="length"} 6
-- decode pod 10.0.0.192 (prompt tokens come from external_kv_transfer: NIXL from prefill)
vllm:prompt_tokens_by_source_total{engine="0",source="external_kv_transfer"} 544
vllm:prompt_tokens_by_source_total{engine="1",source="external_kv_transfer"} 72
...

== 4. EPP sees each rank as its own endpoint with its own scraped queue
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpc-decode-7bf645748b-wtmfk-rank-0",name="dpc-decode"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpc-decode-7bf645748b-wtmfk-rank-1",name="dpc-decode"} 0
```

The repeated long prefix lands on rank 0 every time, and rank 0's `local_cache_hit` counts show
the reuse. The decode pod's prompt tokens all come from `external_kv_transfer`, on both engines.

## Sidecar demo output

Not run yet. The sidecar demo deploys, but its run is pending a public sidecar image.

## KV events and load demo output

Same layout as `multinode/` (each phase one DP=4 group over two pods, 2 ranks per pod). vLLM
publishes KV events on `tcp://*:5557`, which it offsets by each engine's global rank; no per-pod
port adjustment. Both EPPs run the precise prefix cache with a `token-producer` backed by a
`vllm launch render` sidecar, plus `queue-scorer` and `running-requests-size-scorer`. Decode runs
`--max-num-seqs 8` so a flooded engine builds a waiting queue. EPP image built at `a61396f6`.

- Section 2 sends a prompt straight to one prefill engine (bypassing the EPP), then sends the
  same prompt through the coordinator. Only that engine's KV events contain its blocks, so the
  prefill EPP routes it back there.
- Section 3 sends 40 long requests straight to decode engine 0, then 6 requests through the
  coordinator. Rank 0's own `engine="0"` queue is high while rank 1 on the same pod reads 0, so
  the decode EPP avoids rank 0.

```
== 1. KV-event subscribers: one per rank endpoint, at 5557 + global rank
  dpk-prefill-0-1-rank-0 -> tcp://10.0.5.104:5559
  dpk-prefill-0-1-rank-1 -> tcp://10.0.5.104:5560
  dpk-prefill-0-rank-0 -> tcp://10.0.5.203:5557
  dpk-prefill-0-rank-1 -> tcp://10.0.5.203:5558

== 2. A prompt warmed on one engine routes back to that engine (precise prefix cache)
-- warmed on prefill engine 2, routed to:
  profile=prefill dprank=2 upstream=10.0.5.104:8000
-- warmed on prefill engine 0, routed to:
  profile=prefill dprank=0 upstream=10.0.5.203:8000
-- warmed on prefill engine 3, routed to:
  profile=prefill dprank=3 upstream=10.0.5.104:8000
-- warmed on prefill engine 1, routed to:
  profile=prefill dprank=1 upstream=10.0.5.203:8000
-- KV-event batches received per subscriber
  llm_d_epp_kv_cache_events_messages_received_total{pod_identifier="robshaw-dev/dpk-prefill-0-1-rank-0"} 2
  llm_d_epp_kv_cache_events_messages_received_total{pod_identifier="robshaw-dev/dpk-prefill-0-1-rank-1"} 2
  llm_d_epp_kv_cache_events_messages_received_total{pod_identifier="robshaw-dev/dpk-prefill-0-rank-0"} 2
  llm_d_epp_kv_cache_events_messages_received_total{pod_identifier="robshaw-dev/dpk-prefill-0-rank-1"} 2

== 3. A flooded decode engine is avoided (per-rank queue metrics)
-- decode EPP per-rank queue while engine 0 is flooded
  llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpk-decode-0-1-rank-0",name="dpk-decode"} 0
  llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpk-decode-0-1-rank-1",name="dpk-decode"} 0
  llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpk-decode-0-rank-0",name="dpk-decode"} 24
  llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpk-decode-0-rank-1",name="dpk-decode"} 0
-- decode ranks picked for 6 new requests
  profile=decode dprank=2 upstream=10.0.9.19:8000
  profile=decode dprank=3 upstream=10.0.9.19:8000
  profile=decode dprank=1 upstream=10.0.7.132:8000
  profile=decode dprank=2 upstream=10.0.9.19:8000
  profile=decode dprank=3 upstream=10.0.9.19:8000
  profile=decode dprank=1 upstream=10.0.7.132:8000
```

## Mixed DP sizes demo output

One InferencePool and one EPP serve both phases. The prefill pod runs DP=2 on 2 GPUs and is
annotated `llm-d.ai/data-parallel-size-local: "2"`; the decode pod runs DP=4 on 4 GPUs and is annotated
`"4"`. The EPP runs without `--data-parallel-size-local`, using the image built at `a61396f6`.

```
== 1. The EPP's endpoints: 2 for the prefill pod, 4 for the decode pod
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpx-decode-6b7d64f94f-8fk9b-rank-0",name="dpx"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpx-decode-6b7d64f94f-8fk9b-rank-1",name="dpx"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpx-decode-6b7d64f94f-8fk9b-rank-2",name="dpx"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpx-decode-6b7d64f94f-8fk9b-rank-3",name="dpx"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpx-prefill-7988b6d897-hrntx-rank-0",name="dpx"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpx-prefill-7988b6d897-hrntx-rank-1",name="dpx"} 0

== 2. Requests: prefill cycles ranks 0-1, decode cycles ranks 0-3 (Envoy log)
profile=prefill dprank=0 upstream=10.0.8.21:8000
profile=decode dprank=0 upstream=10.0.7.137:8000
profile=prefill dprank=1 upstream=10.0.8.21:8000
profile=decode dprank=1 upstream=10.0.7.137:8000
profile=prefill dprank=0 upstream=10.0.8.21:8000
profile=decode dprank=2 upstream=10.0.7.137:8000
profile=prefill dprank=1 upstream=10.0.8.21:8000
profile=decode dprank=3 upstream=10.0.7.137:8000
profile=prefill dprank=0 upstream=10.0.8.21:8000
profile=decode dprank=0 upstream=10.0.7.137:8000
profile=prefill dprank=1 upstream=10.0.8.21:8000
profile=decode dprank=1 upstream=10.0.7.137:8000
profile=prefill dprank=0 upstream=10.0.8.21:8000
profile=decode dprank=2 upstream=10.0.7.137:8000
profile=prefill dprank=1 upstream=10.0.8.21:8000
profile=decode dprank=3 upstream=10.0.7.137:8000

== 3. vLLM ran each request on the picked engine
-- prefill pod 10.0.8.21
  engine=0 ran 4
  engine=1 ran 4
-- decode pod 10.0.7.137
  engine=0 ran 2
  engine=1 ran 2
  engine=2 ran 2
  engine=3 ran 2

== 4. Decode read the prompt KV from prefill over NIXL, on all four engines
vllm:prompt_tokens_by_source_total{engine="0",source="external_kv_transfer"} 48
vllm:prompt_tokens_by_source_total{engine="2",source="external_kv_transfer"} 48
vllm:prompt_tokens_by_source_total{engine="3",source="external_kv_transfer"} 48
vllm:prompt_tokens_by_source_total{engine="1",source="external_kv_transfer"} 48
```

Changing the decode pod's annotation to `"2"` on the running pod (tested at `37cd9dbc`, before the
annotation was renamed from `llm-d.ai/data-parallel-ranks`) removed its `rank-2` and `rank-3`
endpoints from the EPP; setting it back to `"4"` restored them.

## Multi-node demo output

Each phase runs one DP=4 group as a LeaderWorkerSet of two pods with 2 GPUs each. Pod
`worker-index` k runs `vllm serve --data-parallel-hybrid-lb --data-parallel-size 4
--data-parallel-size-local 2 --data-parallel-start-rank 2k` with `VLLM_USE_RUST_FRONTEND=1`, so
its `vllm-rs` frontend serves global ranks 2k and 2k+1. The EPPs run with
`--data-parallel-start-rank-label=leaderworkerset.sigs.k8s.io/worker-index` and the EPP image
built at `390eb7da` (where the flag was named `--data-parallel-ranks-per-port`). The vLLM manifest requests `rdma/ib` and sets `NCCL_IB_HCA` for the test
cluster; drop them on clusters without InfiniBand.

```
== Pods (LWS worker-index k serves global ranks 2k, 2k+1)
dpm-decode-0      decode    0     10.0.7.237
dpm-prefill-0     prefill   0     10.0.0.143
dpm-decode-0-1    decode    1     10.0.7.44
dpm-prefill-0-1   prefill   1     10.0.5.56

== 1. Distinct prompts spread over global ranks 0-3 (Envoy log: rank per phase)
profile=prefill dprank=2 upstream=10.0.5.56:8000
profile=decode dprank=2 upstream=10.0.7.44:8000
profile=prefill dprank=3 upstream=10.0.5.56:8000
profile=decode dprank=3 upstream=10.0.7.44:8000
profile=prefill dprank=0 upstream=10.0.0.143:8000
profile=decode dprank=0 upstream=10.0.7.237:8000
profile=prefill dprank=1 upstream=10.0.0.143:8000
profile=decode dprank=1 upstream=10.0.7.237:8000
profile=prefill dprank=2 upstream=10.0.5.56:8000
profile=decode dprank=2 upstream=10.0.7.44:8000
profile=prefill dprank=3 upstream=10.0.5.56:8000
profile=decode dprank=3 upstream=10.0.7.44:8000
profile=prefill dprank=0 upstream=10.0.0.143:8000
profile=decode dprank=0 upstream=10.0.7.237:8000
profile=prefill dprank=1 upstream=10.0.0.143:8000
profile=decode dprank=1 upstream=10.0.7.237:8000

== 2. Each pod ran requests only on its own global ranks (vLLM engine label)
-- dpm-decode-0 (10.0.7.237)
  engine=0 ran 2
  engine=1 ran 2
-- dpm-decode-0-1 (10.0.7.44)
  engine=2 ran 2
  engine=3 ran 2
-- dpm-prefill-0 (10.0.0.143)
  engine=0 ran 2
  engine=1 ran 2
-- dpm-prefill-0-1 (10.0.5.56)
  engine=2 ran 2
  engine=3 ran 2

== 3. Decode read the prompt KV from prefill over NIXL
-- dpm-decode-0
vllm:prompt_tokens_by_source_total{engine="1",source="external_kv_transfer"} 40
vllm:prompt_tokens_by_source_total{engine="0",source="external_kv_transfer"} 40
-- dpm-decode-0-1
vllm:prompt_tokens_by_source_total{engine="2",source="external_kv_transfer"} 40
vllm:prompt_tokens_by_source_total{engine="3",source="external_kv_transfer"} 40

== 4. EPP endpoints: four per phase, each reading its own engine's queue
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpm-decode-0-1-rank-0",name="dpm-decode"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpm-decode-0-1-rank-1",name="dpm-decode"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpm-decode-0-rank-0",name="dpm-decode"} 0
llm_d_epp_per_endpoint_queue_size{model_server_endpoint="dpm-decode-0-rank-1",name="dpm-decode"} 0
```

Global ranks 2 and 3 go to the `worker-index=1` pods, and only their `engine="2"` and `engine="3"`
counters move. Decode reads every prompt from prefill over NIXL across pods.

## Limitations

- **One target port.** `--data-parallel-size-local` above 1 requires an InferencePool with
  exactly one target port, which is how `vllm-rs` serves all ranks.
- **One frontend per pod.** A data-parallel group over several pods needs one `vllm-rs` frontend
  per pod (hybrid LB, see `multinode/`). One frontend serving a group with headless engines on
  other pods is not covered.
- **Rank count is configured, not discovered.** vLLM reports `data_parallel_size_local` in
  `vllm.Control/GetServerInfo`; discovering it is a follow-up.
- **HTTP only.** The router reaches vLLM over HTTP. The gRPC path is
  [llm-d/llm-d-router#3758](https://github.com/llm-d/llm-d-router/issues/3758).

## Teardown

```bash
./coordinator/teardown.sh
./sidecar/teardown.sh
./mixed/teardown.sh
./kvevents/teardown.sh
./multinode/teardown.sh
```
