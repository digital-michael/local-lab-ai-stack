# vLLM — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for vLLM within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Host port 8000 maps to container port 8000
- GPU node only — controller nodes do not run vLLM
- CDI device passthrough: `nvidia.com/gpu=all`
- Resource limits: 4 cores, 24 GB RAM, full GPU allocation

# 2 Configuration Choices

- **Hardware baseline (RTX 3070 Ti, 8 GB VRAM):** ~5 GB usable on a desktop — X server + driver overhead consumes ~2.6 GB; a headless server gets ~7+ GB
- **Model selection:** FP16 llama3.1-8b requires ~16 GB VRAM and will immediately OOM on this card; use quantized or small models only:
  - `Qwen2.5-1.5B-Instruct` (FP16, 2.89 GB) — fits comfortably with headroom at 5 GB usable
  - `Phi-3.5-mini-AWQ` (~2.5 GB) — quantized, good quality/size balance
  - `Llama-3.2-3B-AWQ` (~2 GB) — smallest viable reasoning model
- `GPU_MEMORY_UTILIZATION=0.55` — lower than the vLLM default (0.90) to account for desktop VRAM overhead; use 0.80–0.85 on a headless/server node
- `TENSOR_PARALLEL_SIZE=1` for single-GPU nodes; increase for multi-GPU
- `MAX_MODEL_LEN=2048` — halves KV cache activation size during profiling; reduces OOM risk on tight VRAM budgets; increase to 4096 only on headless nodes
- **OOM flags for desktop GPU:** combine `--enforce-eager` (disables CUDA graph pre-capture) + `PYTORCH_ALLOC_CONF=expandable_segments:True` (releases reserved-but-unused PyTorch memory blocks) to recover ~200–400 MB of effective headroom

# 3 Integration Patterns

- LiteLLM → vLLM (primary inference path for all GPU-accelerated requests)
- LiteLLM routes embedding requests to vLLM's embedding endpoint
- vLLM never communicates with any other service directly
- Models mounted read-only from `$AI_STACK_DIR/models/`

# 4 Operational Notes

- vLLM has the slowest startup time of any service (model loading + torch.compile warmup) — 60-second health check interval accounts for this; expect 90–120 seconds before `/health` responds on first start
- OOM kills are the most common failure mode; monitor `nvidia-smi --query-compute-apps`; lower `GPU_MEMORY_UTILIZATION` or `MAX_MODEL_LEN` before re-attempting
- When adding a new model, download weights to the models directory first, then update LiteLLM's routing config
- vLLM container restarts cause a brief inference outage — LiteLLM falls back to Ollama (CPU) automatically when the vLLM backend is unhealthy
- **CPU pinning for Ollama co-deployment:** when Ollama runs on the same machine, add `CUDA_VISIBLE_DEVICES=""` to the Ollama quadlet environment — without this, Ollama claims the GPU at startup and starves vLLM
- **vLLM entrypoint requires CLI args, not env vars:** `MODEL_NAME`, `GPU_MEMORY_UTILIZATION`, etc. set as environment variables are silently ignored — pass all flags via the container CMD (quadlet `Exec=`)
- **`--served-model-name` is required:** without it, vLLM serves the model under its path (`/models/qwen2.5-1.5b`) not the friendly name (`qwen2.5-1.5b`); LiteLLM routing will fail with 404 until the names match
- **LiteLLM api_base must include `/v1`:** `api_base: http://vllm.ai-stack:8000` causes requests to go to `/chat/completions` (404); correct value is `api_base: http://vllm.ai-stack:8000/v1` so requests land at `/v1/chat/completions` (200)
- **`pull-models.sh` adds, does not update:** calling it twice creates duplicate model entries in the LiteLLM DB; use `POST /model/delete` with the stale entry's UUID before re-registering if api_base changes
