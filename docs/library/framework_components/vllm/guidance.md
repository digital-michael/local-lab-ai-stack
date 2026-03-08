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

- Default model: `llama3.1-8b` — fits in 24 GB VRAM with room for KV cache
- `TENSOR_PARALLEL_SIZE=1` for single-GPU nodes; increase for multi-GPU
- `MAX_MODEL_LEN=4096` — conservative context window to start; increase as needed
- `GPU_MEMORY_UTILIZATION=0.9` — reserve 10% for system overhead
- Embedding model (`BAAI/bge-large-en-v1.5`) also served by this vLLM instance

# 3 Integration Patterns

- LiteLLM → vLLM (primary inference path for all GPU-accelerated requests)
- LiteLLM routes embedding requests to vLLM's embedding endpoint
- vLLM never communicates with any other service directly
- Models mounted read-only from `$AI_STACK_DIR/models/`

# 4 Operational Notes

- vLLM has the slowest startup time of any service (model loading) — 60-second health check interval accounts for this
- OOM kills are the most common failure mode; monitor `gpu_memory_used_percent`
- When adding a new model, download weights to the models directory first, then update LiteLLM's routing config
- vLLM container restarts cause a brief inference outage — LiteLLM should fall back to llama.cpp automatically
