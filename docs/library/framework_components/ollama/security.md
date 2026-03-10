# ollama — Security
**Last Updated:** 2026-03-09 UTC

## Purpose
Security hardening and guidelines for ollama local inference within this AI stack.

---

## Table of Contents

1. Network Isolation
2. Model Integrity
3. Input Validation
4. Container Security

## References

- ollama GitHub: https://github.com/ollama/ollama
- GGUF format security notes: https://github.com/ggerganov/ggml/blob/master/docs/gguf.md

---

# 1 Network Isolation

- ollama must not be accessible outside the internal Podman network (`ai-stack-net`)
- Only LiteLLM should communicate with ollama on port 11434
- Do not publish port 11434 to the host; omit `ports` entirely from the quadlet
- Access ollama exclusively via its internal DNS alias (`ollama.ai-stack`)
- `OLLAMA_HOST=0.0.0.0` binds to all container interfaces — this is safe because the container network is isolated; it does not expose the port to the host

# 2 Model Integrity

- Pull models from `ollama.com` (the official registry) only; treat third-party Modelfile `FROM` URLs as untrusted
- When importing GGUF files, use only files sourced from trusted repositories and with verified checksums
- Mount the host models directory as read-only (`:ro`) inside the container — ollama should never modify source GGUF files
- The `/root/.ollama` data volume (where ollama stores imported model blobs) should be writable but locally scoped; do not expose it across nodes

# 3 Input Validation

- LiteLLM handles user-facing input validation and rate limiting before requests reach ollama
- Set `max_tokens` bounds in LiteLLM routing config to prevent runaway context allocation
- ollama respects `num_ctx` per request — configure a reasonable default in the LiteLLM `litellm_params`
- Monitor for abnormally slow or large requests via Prometheus metrics and Loki logs

# 4 Container Security

- The official `ollama/ollama` image runs as root inside the container; this is expected and allowlisted in the security test suite (`KNOWN_ROOT_CONTAINERS`)
- Mount the source models directory read-only (`:ro`); the ollama data volume (`.ollama`) read-write
- Pin the image to an explicit version tag — never use `latest` in production
- No GPU device passthrough required on CPU-only deployments (`AddDevice` not needed)
- ollama has a smaller attack surface than vLLM: no Python runtime in the hot path, single-binary server
