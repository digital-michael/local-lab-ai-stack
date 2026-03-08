# llama.cpp — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating llama.cpp as the CPU/Mac fallback inference engine.

---

## Table of Contents

1. Deployment
2. Model Quantization
3. Performance Tuning
4. Platform Considerations
5. Reliability

## References

- llama.cpp GitHub: https://github.com/ggerganov/llama.cpp
- GGUF Format Specification: https://github.com/ggerganov/ggml/blob/master/docs/gguf.md

---

# 1 Deployment

- Deploy behind LiteLLM as a fallback for GPU-unavailable scenarios
- Use the server mode (`llama-server`) for an OpenAI-compatible API
- Pass model files via read-only bind mounts from `$AI_STACK_DIR/models/`
- Use GGUF format exclusively — it is the current standard for llama.cpp models
- Pin the container image; llama.cpp evolves rapidly

# 2 Model Quantization

- Use Q4_K_M or Q5_K_M quantization for a good balance of quality and speed on CPU
- Q8_0 provides near-full-precision quality but requires more RAM and is slower
- Choose quantization level based on available RAM: ~5 GB for Q4_K_M 8B parameter models
- Download pre-quantized models from trusted sources; verify checksums
- Test output quality after switching quantization levels

# 3 Performance Tuning

- Set `THREADS` to the number of physical cores (not hyperthreads) for optimal performance
- Set `BATCH_SIZE` to 512 for good throughput on most CPUs; reduce if memory-constrained
- Set `CONTEXT_SIZE` to match the model's training context window or less
- Enable memory-mapped model loading (`--mmap`) for faster startup after the first load
- On Apple Silicon, llama.cpp can use Metal for GPU acceleration — significant speedup

# 4 Platform Considerations

- **Linux (CPU):** Ensure AVX2/AVX-512 support for SIMD acceleration; most modern CPUs support this
- **macOS (Apple Silicon):** Use Metal backend for ~5-10x speedup over pure CPU; set `--n-gpu-layers` appropriately
- **RAM requirements:** Model size in GGUF format ≈ download size; context window adds overhead proportional to `CONTEXT_SIZE × BATCH_SIZE`
- llama.cpp is single-instance per model — run multiple containers for different models if needed

# 5 Reliability

- llama.cpp processes are lightweight and restart quickly (unlike vLLM)
- Set `Restart=always` in the systemd quadlet
- Health checks should verify the HTTP server responds, not just that the process is running
- Monitor for segfaults — they can occur with incompatible GGUF files or out-of-memory conditions
- llama.cpp is a secondary inference path; its unavailability is less critical than vLLM's
