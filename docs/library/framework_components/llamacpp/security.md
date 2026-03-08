# llama.cpp — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for llama.cpp CPU/Mac inference.

---

## Table of Contents

1. Network Isolation
2. Model Integrity
3. Input Validation
4. Container Security

## References

- llama.cpp GitHub: https://github.com/ggerganov/llama.cpp
- GGUF Security: https://github.com/ggerganov/ggml/blob/master/docs/gguf.md

---

# 1 Network Isolation

- llama.cpp must not be accessible outside the internal Podman network
- Only LiteLLM should communicate with llama.cpp
- Do not publish llama.cpp's server port to the host
- Use internal DNS (`llamacpp.ai-stack`) exclusively

# 2 Model Integrity

- Use only GGUF format — it uses a flat binary format that does not execute arbitrary code, unlike pickle-based formats
- Download from trusted sources and verify checksums
- Mount models as read-only — the inference engine should never modify model files
- Do not support runtime model uploads or hot-swapping via API in production

# 3 Input Validation

- Set `CONTEXT_SIZE` to a reasonable maximum to prevent excessive memory allocation from overly long prompts
- Configure request timeouts to reject maliciously crafted inputs that cause excessive computation
- LiteLLM handles user-facing input validation; llama.cpp should only receive sanitized requests
- Monitor for abnormally large or slow requests in logs

# 4 Container Security

- Run as a non-root user inside the container
- Mount models directory read-only (`:ro`)
- Pin the image to a specific tag or digest
- No GPU device access needed on CPU-only nodes (no `--device` flags)
- Drop all unnecessary Linux capabilities
- llama.cpp has a smaller attack surface than vLLM due to fewer dependencies
