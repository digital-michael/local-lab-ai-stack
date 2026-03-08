# vLLM — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for vLLM GPU inference.

---

## Table of Contents

1. Network Isolation
2. Model Integrity
3. GPU Device Security
4. Data Protection
5. Container Security

## References

- vLLM Documentation: https://docs.vllm.ai
- NVIDIA Container Security: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/index.html

---

# 1 Network Isolation

- vLLM must not be accessible outside the internal Podman network
- Only LiteLLM should communicate with vLLM; enforce this via network policy or firewall rules
- Do not publish vLLM's port (8000) to the host unless debugging; let LiteLLM proxy all requests
- Use internal DNS (`vllm.ai-stack`) exclusively for service communication

# 2 Model Integrity

- Download models from trusted sources only (Hugging Face official repos, verified publishers)
- Use safetensors format — it is not vulnerable to arbitrary code execution, unlike pickle-based formats
- Verify model checksums after download
- Store models on encrypted storage if they contain proprietary or licensed weights
- Do not allow model uploads at runtime; models are pre-staged and mounted read-only

# 3 GPU Device Security

- Use CDI (`nvidia.com/gpu=all`) for controlled GPU access — never use `--privileged`
- CDI limits the container's access to only the GPU device, not other system devices
- Monitor GPU device access through audit logging
- Keep NVIDIA drivers and the container toolkit updated for security patches

# 4 Data Protection

- Prompts and completions transit through vLLM in memory — no persistent logging by default
- Do not enable verbose/debug logging in production; it may log prompt content
- GPU memory is not cleared between requests — be aware that residual data may persist in VRAM
- Set appropriate inference timeouts to reject maliciously long prompts

# 5 Container Security

- Run the container as a non-root user
- Mount the models directory as read-only (`:ro`)
- Pin the image to a specific tag or digest
- The container requires GPU device access but no other elevated privileges
- Drop all Linux capabilities except those required for GPU communication
- Scan the image for CVEs; vLLM images pull in CUDA and PyTorch which have a large dependency surface
