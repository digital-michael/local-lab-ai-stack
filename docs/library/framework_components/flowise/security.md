# Flowise — Security
**Last Updated:** 2026-07-10

## Purpose
Security standards and hardening guidelines for Flowise in a production AI stack.

---

## Table of Contents

1. Authentication and Authorization
2. Network Security
3. API Security
4. Credential Management
5. Container Security

## References

- Flowise Documentation: https://docs.flowiseai.com
- OWASP API Security Top 10: https://owasp.org/www-project-api-security/

---

# 1 Authentication and Authorization

- Authentik forwardAuth via Traefik is the sole auth gate — `FLOWISE_USERNAME` and `FLOWISE_PASSWORD` are intentionally not set. Do not re-enable internal auth while forwardAuth is active (double-auth breaks the flow).
- Flowise's built-in auth can only be disabled by omitting `FLOWISE_USERNAME` from the quadlet environment; if the env var is present, Flowise always enforces its own login regardless of proxy headers.
- Restrict admin UI access to `bundle-admin` users via the `access-flowise` Authentik ExpressionPolicy; regular users interact through OpenWebUI or API keys, not the Flowise UI directly.
- Audit who creates, modifies, and executes workflows via Authentik event logs (forwardAuth records each access).

# 2 Network Security

- Do not expose Flowise ports to the public network — it is an internal orchestration service
- Access the admin UI through a VPN or SSH tunnel; never expose the Flowise UI on a public interface
- Communicate with LiteLLM and Qdrant exclusively over the internal `ai-stack-net` Podman network
- If external webhook triggers are needed, use the reverse proxy with strict path-based routing and authentication

# 3 API Security

- Protect Flowise API endpoints with API keys; do not allow unauthenticated workflow execution
- Validate and sanitize inputs to workflows, especially when they accept user-provided data from OpenWebUI
- Rate-limit API calls to prevent abuse
- Log all API requests for audit and troubleshooting

# 4 Credential Management

- Store API keys for LiteLLM, Qdrant, and other services as Podman secrets — never in workflow JSON exports
- When exporting workflows, verify that sensitive credentials are not embedded in the export file
- Rotate credentials periodically and update the corresponding Podman secrets
- Do not log or expose secret values in workflow execution outputs

# 5 Container Security

- Run as a non-root user inside the container
- Use rootless Podman for user-namespace isolation
- Pin the container image to a specific tag or digest
- Limit container capabilities; Flowise does not need privileged access
- Scan the image for vulnerabilities before deployment
