# LiteLLM — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for LiteLLM within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Host port 9000 maps to container port 4000
- LiteLLM is the **single point of entry** for all inference — no service bypasses it
- PostgreSQL dependency enforced via quadlet `After=` and `Requires=`

# 2 Configuration Choices

- Master key provisioned via Podman secret (`litellm_master_key`)
- Database URL connects to `postgres.ai-stack:5432` with the `aistack` database
- Model routing: vLLM as primary (GPU), llama.cpp as fallback (CPU) for the same model aliases
- Embedding model (`BAAI/bge-large-en-v1.5`) served by vLLM and exposed through LiteLLM as a separate endpoint
- No external API providers configured — all inference is local

# 3 Integration Patterns

- OpenWebUI → LiteLLM (chat completions, model listing)
- Flowise → LiteLLM (workflow inference calls)
- Knowledge Index → LiteLLM (embedding generation)
- LiteLLM → vLLM (GPU inference)
- LiteLLM → llama.cpp (CPU fallback inference)
- Prometheus scrapes LiteLLM metrics for token/latency/error dashboards

# 4 Operational Notes

- LiteLLM is the most critical routing component — if it goes down, all inference stops
- Health check on `/health` at 30-second intervals; alert immediately on failure
- Model configuration changes can be made at runtime via the admin API without restarting the container
- When adding new models, update both the LiteLLM config and configure.sh/config.json for consistency
