# vLLM — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating vLLM as the primary GPU inference engine.

---

## Table of Contents

1. Deployment
2. Model Loading
3. Performance Tuning
4. GPU Management
5. Reliability

## References

- vLLM Documentation: https://docs.vllm.ai
- vLLM GitHub: https://github.com/vllm-project/vllm

---

# 1 Deployment

- Deploy vLLM behind LiteLLM — never expose it directly to users
- Use the OpenAI-compatible API server (`vllm-openai`) for drop-in compatibility with LiteLLM
- Pass models via read-only bind mounts from the shared `$AI_STACK_DIR/models/` directory
- Use CDI (Container Device Interface) for GPU passthrough rather than `--privileged`
- Pin the image tag; vLLM has frequent releases with potential breaking changes

# 2 Model Loading

- Pre-download model weights to the shared models directory before starting the container
- Use Hugging Face hub format (safetensors preferred over pickle for security)
- Set `MODEL_NAME` to the model identifier that matches the directory name in `/models/`
- For large models, verify disk space and consider NVMe storage for fast loading
- Cache tokenizer files alongside model weights to avoid network downloads at startup

# 3 Performance Tuning

- Set `GPU_MEMORY_UTILIZATION` to 0.85–0.95 depending on model size and concurrent request expectations
- Use `TENSOR_PARALLEL_SIZE` to shard large models across multiple GPUs on the same node
- Set `MAX_MODEL_LEN` to the maximum context length the model supports (or less to save memory)
- Enable continuous batching (the default) — it dramatically improves throughput under concurrent load
- Use PagedAttention (vLLM's default) for efficient KV-cache management
- Monitor TPOT (time per output token) and TTFT (time to first token) as primary latency metrics

# 4 GPU Management

- Allocate the full GPU to vLLM; do not share GPUs between vLLM and other containers
- Monitor GPU memory usage, utilization, and temperature via `nvidia-smi` or DCGM metrics
- Set `CUDA_VISIBLE_DEVICES` if multiple GPUs are present and only some should be used
- On multi-GPU nodes, use tensor parallelism rather than running multiple vLLM instances
- Ensure the NVIDIA driver version is compatible with the CUDA version in the vLLM image

# 5 Reliability

- Health check on `/health` at 60-second intervals (longer than other services due to model loading time)
- Set `Restart=always` but be aware that restarts require full model reload (slow)
- Use LiteLLM fallback routing to llama.cpp during vLLM restarts to maintain inference availability
- Monitor for OOM kills — these indicate the model is too large for available VRAM
- Log inference errors to trace model-specific failures
