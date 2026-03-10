# ollama — Guidance
**Last Updated:** 2026-03-09 UTC

## Purpose
Project-specific preferences and opinionated decisions for ollama within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Model Import
4. Integration Patterns
5. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- No host port published — ollama is internal only, accessed by LiteLLM via `ollama.ai-stack:11434`
- Resource limits: 4 cores, 16 GB RAM, no GPU (`--cpus=4 --memory=16g`)
- Image: `docker.io/ollama/ollama:0.17.7` (pin to explicit version; update at next stack version review)

# 2 Configuration Choices

- `OLLAMA_HOST=0.0.0.0` — required for the server to accept connections from other containers
- Two volume mounts:
  - `$AI_STACK_DIR/ollama:/root/.ollama:rw,Z` — ollama's model blob storage (persists across restarts)
  - `$AI_STACK_DIR/models:/gguf:ro,Z` — shared GGUF source directory for import

# 3 Model Import

- Pre-existing GGUF files (e.g., from a prior llamacpp deployment) are reused without re-downloading.
  **Always use the full tool-calling Modelfile** (see below) — the bare `FROM <blob>` template omits
  `.Tools` handling and causes ollama to reject any request that includes a `tools` array.

  ```bash
  # Write Modelfile with llama3.1 tool-calling template (see ai_stack_configuration.md §ollama)
  podman cp /path/to/Modelfile ollama:/tmp/Modelfile
  podman exec ollama ollama create <name>:<tag> -f /tmp/Modelfile
  ```
- Default model: `llama3.1:8b` imported from `$AI_STACK_DIR/models/llama3.1-8b.gguf`
- Verify import: `podman exec ollama ollama list`
- Models persist in `$AI_STACK_DIR/ollama/` and survive container restarts

# 4 Integration Patterns

- LiteLLM routes to ollama using the `ollama_chat` provider:
  - `model`: `ollama_chat/llama3.1:8b`
  - `api_base`: `http://ollama.ai-stack:11434`
  - Registered via `scripts/pull-models.sh` from `configs/models.json`
- ollama does not communicate with any other stack service directly
- vLLM (GPU) is the primary inference path; ollama is the CPU fallback for nodes without a GPU

# 5 Operational Notes

- ollama restarts quickly — no significant warm-up delay compared to vLLM
- First inference after `OLLAMA_KEEP_ALIVE` idle period incurs a model reload (~2–5 seconds for 8B Q4)
- CPU inference speed is 5–20× slower than GPU; acceptable for fallback and interactive use at low concurrency
- When adding new models: provide the GGUF file in `$AI_STACK_DIR/models/`, import via Modelfile, register route in `configs/models.json`, re-run `pull-models.sh`
- Replaced llamacpp in the stack on 2026-03-09 — reason: llamacpp GHCR `server--bNNNN` image tag format was discontinued; ollama provides stable semantic versioning, native OpenAI-compatible API, and built-in model lifecycle management

## Lessons Learned

See `docs/repo/lessons-learned.md` §`Engineering Principles` for the full post-mortem on the llamacpp → ollama migration.
