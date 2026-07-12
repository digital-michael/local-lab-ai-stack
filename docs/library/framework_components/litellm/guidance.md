# LiteLLM — Guidance
**Last Updated:** 2026-07-11

## Purpose
Project-specific preferences and opinionated decisions for LiteLLM within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes
5. External Access (SSO)

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

# 5 External Access (SSO)

LiteLLM is exposed externally at `https://litellm.photondatum.space` via the same
Caddy → CENTAURI Traefik → LiteLLM container chain used by other services.

**Auth pattern: LiteLLM manages its own OAuth SSO.** Unlike OpenWebUI and Flowise,
LiteLLM has a built-in OAuth2 client (`GENERIC_*` env vars in `litellm.env`).
This means:

- The Traefik `litellm-public` router has **only `secure-headers`** — no Authentik
  forwardAuth middleware. Adding forwardAuth would force two separate Authentik
  round-trips per session (once for forwardAuth, once for LiteLLM's own OAuth).
- The Authentik application for LiteLLM uses an **OAuth2Provider**, not a
  ProxyProvider. It does not appear in the Embedded Outpost's provider list.
- `AUTO_REDIRECT_UI_LOGIN_TO_SSO=true` means LiteLLM immediately redirects
  unauthenticated users to Authentik — no LiteLLM login form is shown.

**Key env vars in `litellm.env` (live only, not in repo):**

```env
GENERIC_CLIENT_ID=<from Authentik OAuth2 provider>
GENERIC_CLIENT_SECRET=<from Authentik OAuth2 provider>
GENERIC_AUTHORIZATION_ENDPOINT=https://auth.photondatum.space/application/o/authorize/
GENERIC_TOKEN_ENDPOINT=https://auth.photondatum.space/application/o/token/
GENERIC_USERINFO_ENDPOINT=https://auth.photondatum.space/application/o/userinfo/
GENERIC_REDIRECT_URI=https://litellm.photondatum.space/sso/callback
PROXY_BASE_URL=https://litellm.photondatum.space
```

**If Authentik is migrated to a new host**, both the OAuth2 provider endpoints
AND the provider record in Authentik must be recreated. The old credentials
from a decommissioned Authentik instance are not transferable — create a new
OAuth2 provider and update all `GENERIC_*` env vars. See
[LiteLLM Lessons §3](lessons_learned.md).

# 4 Operational Notes

- LiteLLM is the most critical routing component — if it goes down, all inference stops
- Health check on `/health` at 30-second intervals; alert immediately on failure
- Model configuration changes can be made at runtime via the admin API without restarting the container
- When adding new models, update both the LiteLLM config and configure.sh/config.json for consistency
