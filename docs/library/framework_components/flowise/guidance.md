# Flowise — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for Flowise within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Host port 3001 maps to container port 3000
- Flowise serves as the internal workflow engine — not a user-facing application
- Persistent storage decision deferred (SQLite local vs PostgreSQL shared — see checklist consideration #25)

# 2 Configuration Choices

- Use LiteLLM's internal endpoint (`http://litellm.ai-stack:4000`) as the sole LLM provider in all Flowise flows
- Connect to Qdrant at `http://qdrant.ai-stack:6333` for vector operations in RAG workflows
- Admin credentials provisioned via Podman secrets (`flowise_password`)
- No custom plugins initially; use built-in Flowise components

# 3 Integration Patterns

- OpenWebUI calls Flowise workflows via API for agent-style interactions
- Flowise calls LiteLLM for all inference (never directly to vLLM or llama.cpp)
- Flowise calls Knowledge Index Service for library-aware retrieval
- Workflow definitions stored in the container's data directory; export JSON to git for version control

# 4 Operational Notes

- Flowise depends on LiteLLM and Qdrant — ensure both are healthy before starting Flowise
- Monitor workflow execution times; long-running workflows typically indicate a downstream timeout
- Export workflows as part of backup procedures
- Flowise has a rapid release cadence — test new versions against existing workflows before upgrading
