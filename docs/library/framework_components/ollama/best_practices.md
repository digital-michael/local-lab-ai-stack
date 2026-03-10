# ollama — Best Practices
**Last Updated:** 2026-03-09 UTC

## Purpose
Best practices for deploying and operating ollama as the local CPU inference engine.

---

## Table of Contents

1. Deployment
2. Model Management
3. Performance Tuning
4. Reliability

## References

- ollama GitHub: https://github.com/ollama/ollama
- ollama Docker Hub: https://hub.docker.com/r/ollama/ollama
- ollama REST API: https://github.com/ollama/ollama/blob/main/docs/api.md

---

# 1 Deployment

- Deploy behind LiteLLM as the local inference backend for CPU/memory-based workloads
- ollama exposes an OpenAI-compatible API on port 11434 — use the `ollama_chat/<model>` provider in LiteLLM
- Set `OLLAMA_HOST=0.0.0.0` so the server binds inside the container; default is `127.0.0.1` which is unreachable from other containers
- Do not publish port 11434 to the host — access exclusively via the internal Podman network
- Pin the container image to a specific semantic version tag (e.g., `0.17.7`); do not use `latest`

# 2 Model Management

- Pull models using `ollama pull <model>:<tag>` inside the running container; models are stored in `/root/.ollama/models`
- Import existing GGUF files using a Modelfile: `FROM /path/to/file.gguf` — avoids re-downloading pre-existing model files
- Pin model tags explicitly (e.g., `llama3.1:8b`) rather than relying on untagged defaults
- Persist the `/root/.ollama` directory via a named volume or bind mount so models survive container restarts
- Use `ollama list` to verify model availability; use `ollama rm <model>` to free storage

# 3 Performance Tuning

- Control parallel request handling with `OLLAMA_NUM_PARALLEL` (default 1 on CPU; increase only if RAM permits)
- Set `OLLAMA_KEEP_ALIVE` to control how long a model stays loaded in memory between requests (default 5m)
- Use Q4_K_M or Q5_K_M quantization GGUF files for a good balance of quality and speed on CPU
- RAM requirements: approximately 5–6 GB for a Q4_K_M 8B parameter model loaded at context length 4096
- Context length is controlled per-request via the `num_ctx` parameter or at the LiteLLM level via `max_tokens`

# 4 Reliability

- Set `Restart=always` in the systemd quadlet — ollama starts quickly and has no significant warm-up
- Health checks should poll `GET /` on port 11434; a 200 response confirms the server is ready
- A loaded model does not persist in memory indefinitely — ollama unloads it after `OLLAMA_KEEP_ALIVE` idle time; the next request will reload it (adds latency for the first request after an idle period)
- ollama is the primary local inference path; its unavailability means CPU inference is unavailable
- On restart, models do not need to be re-imported — they persist in the `/root/.ollama` volume
