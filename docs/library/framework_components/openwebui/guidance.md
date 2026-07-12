# OpenWebUI — Guidance
**Last Updated:** 2026-07-11

## Purpose
Project-specific preferences and opinionated decisions for OpenWebUI within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet — no Docker, no Compose
- Use `configure.sh generate-quadlets` to produce the unit file from `configs/config.json`
- Mount no persistent volume for OpenWebUI itself initially; conversation history is ephemeral until backup procedures are defined
- Host port 9090 maps to container port 8080

# 2 Configuration Choices

- LiteLLM is the **only** backend configured in OpenWebUI — all model routing decisions happen in LiteLLM, not in the UI
- Single `OPENAI_API_KEY` secret shared with LiteLLM's master key for simplicity in the initial deployment
- Disable built-in model management and RAG features in OpenWebUI — these responsibilities belong to LiteLLM and the Knowledge Index Service respectively
- Keep the default OpenWebUI theme; no custom branding initially

# 3 Integration Patterns

- Authentication: Authentik forwardAuth with trusted email header (`WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-authentik-email`, `WEBUI_AUTH_TRUSTED_NAME_HEADER=X-authentik-name`). Authentik injects the user's email after validating the proxy session; OpenWebUI auto-signs the user in via the injected header — no login form is shown. See [lessons_learned.md §1](lessons_learned.md#1-webui_auth_trusted_email_header--how-auto-login-works).
- Admin account: the first registered user becomes OpenWebUI admin. Currently `michaelbiggerstaff7@gmail.com`. To add a second admin, promote via admin panel → Workspace → Users → change role to Admin after their first login.
- API: OpenWebUI → LiteLLM internal DNS (`http://litellm.ai-stack:4000`)
- Flowise workflows accessible through OpenWebUI as tool integrations when available
- No direct database connection from OpenWebUI; all data flows through APIs

# 4 Operational Notes

- OpenWebUI is a user-facing component — prioritize uptime and fast restarts
- Monitor with health checks on `/health` at 30-second intervals
- Plan for OpenWebUI to be the most frequently upgraded component as it has a rapid release cadence
- When upgrading, test with a parallel container before replacing the live instance
