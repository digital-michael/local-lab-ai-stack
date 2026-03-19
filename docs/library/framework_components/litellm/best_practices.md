# LiteLLM — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating LiteLLM as the centralized model routing gateway.

---

## Table of Contents

1. Deployment
2. Model Routing
3. Performance
4. Reliability
5. Observability

## References

- LiteLLM Documentation: https://docs.litellm.ai
- LiteLLM GitHub: https://github.com/BerriAI/litellm

---

# 1 Deployment

- Deploy LiteLLM as the single API gateway for all LLM inference — no service should call vLLM or llama.cpp directly
- Use a PostgreSQL backend for persistent configuration, usage tracking, and spend logging
- Set `LITELLM_MASTER_KEY` to a strong random value; inject via Podman secrets
- Configure the `DATABASE_URL` to point to the PostgreSQL instance on the internal network
- Run behind a reverse proxy for external access; internal services connect directly via DNS

# 2 Model Routing

- Define all models in a `litellm_config.yaml` or via the admin API; map model aliases to backends
- Use fallback chains: primary model on vLLM (GPU), fallback to llama.cpp (CPU) for the same model family
- Set model-level rate limits and budget caps to control resource usage
- Group models by capability (general, code, embedding) and assign appropriate routing rules
- Use the `/model/info` endpoint to verify which models are available and healthy

# 3 Performance

- LiteLLM is a lightweight proxy — CPU and memory requirements are modest (2 cores, 2 GB)
- Enable request queuing for high-concurrency scenarios
- Set timeouts per model to avoid blocking on unresponsive backends
- Monitor token throughput and latency per model to identify bottlenecks
- Use streaming responses where possible to reduce time-to-first-token perceived by users

# 4 Reliability

- Health check the `/health/liveliness` endpoint at 30-second intervals — `/health` requires the master key (returns 401 without it)
- Configure `Restart=always` in the systemd quadlet
- LiteLLM depends on PostgreSQL — enforce startup ordering in the quadlet
- Use model fallbacks to maintain service even when a specific backend is down
- Log all requests for debugging inference failures

# 5 Observability

- LiteLLM exposes Prometheus metrics natively — scrape them for token usage, latency, and error rates
- Integrate with Grafana dashboards for real-time visibility into model usage patterns
- Use the built-in spend tracking to monitor per-model and per-user costs
- Alert on high error rates, unusual latency spikes, or backend unavailability
