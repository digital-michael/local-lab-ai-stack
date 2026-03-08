# llama.cpp — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for llama.cpp within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- No host port published — llama.cpp is internal only, accessed via LiteLLM
- Runs on CPU-only controller nodes or Mac nodes with Metal acceleration
- Resource limits: 4 cores, 16 GB RAM, no GPU

# 2 Configuration Choices

- Default model: `llama3.1-8b.gguf` (Q4_K_M quantization)
- `CONTEXT_SIZE=4096` — matches vLLM configuration for consistent behavior
- `THREADS=4` — adjust per node based on physical core count
- `BATCH_SIZE=512` — default for balanced throughput
- Models stored in `$AI_STACK_DIR/models/` alongside vLLM models (different format)

# 3 Integration Patterns

- LiteLLM → llama.cpp (fallback inference when vLLM is unavailable or for CPU-only nodes)
- llama.cpp does not communicate with any other service
- Same model aliases in LiteLLM route to both vLLM and llama.cpp with vLLM as primary

# 4 Operational Notes

- llama.cpp restarts quickly — no model warm-up delay comparable to vLLM
- Inference speed is 5–20x slower than GPU; acceptable for fallback but not sustained high traffic
- On Mac nodes, ensure Metal backend is enabled for Apple Silicon acceleration
- When adding new models, provide both the HuggingFace format (for vLLM) and GGUF format (for llama.cpp)
