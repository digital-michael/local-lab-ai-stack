# Authentik — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for Authentik within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- No public port initially — Authentik is accessed through the reverse proxy only
- Depends on PostgreSQL; startup order enforced via quadlet dependencies
- Resource limits: 2 cores, 2 GB RAM
- Authentik OIDC integration is **deferrable** — direct authentication is acceptable for initial deployment

# 2 Configuration Choices

- Shared PostgreSQL instance (`aistack` database, `authentik` schema)
- Redis: evaluate whether Authentik's embedded worker mode can avoid a separate Redis container; if not, add Redis to the config
- Create three OIDC applications: OpenWebUI, Grafana, Flowise
- Groups: `admins` (full access), `users` (standard access)
- MFA deferred initially; enable for admin accounts as a priority

# 3 Integration Patterns

- OpenWebUI → Authentik (OIDC login)
- Grafana → Authentik (generic OAuth)
- Flowise → Authentik (OIDC login for admin UI)
- Authentik → PostgreSQL (identity data storage)
- Authentik does not interact with LiteLLM, vLLM, Qdrant, or inference services

# 4 Operational Notes

- Authentik is a deferrable component — the stack works without it, using service-native authentication
- When enabling Authentik, configure each consuming service's OIDC settings and test login flows individually
- Back up Authentik configuration by exporting flows/blueprints to git
- Authentik upgrades may require database migrations — always back up PostgreSQL before upgrading
