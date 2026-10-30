# llm-d examples

| Example | Description |
|---|---|
| [pd-rust-frontend-dp](pd-rust-frontend-dp/) | Prefill/decode disaggregation of DeepSeek-V2-Lite with the vLLM Rust frontend, DP=2 per pod, and the llm-d router picking the DP rank via `X-data-parallel-rank` |
| [pd-dp-rank-routing](pd-dp-rank-routing/) | P/D with the llm-d EPP picking the vLLM data-parallel rank (`x-data-parallel-rank`) behind one port: coordinator, sidecar, and a DP group spanning pods |
