# Flowise — Security
**Last Updated:** 2026-03-08 UTC

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

- Enable basic authentication (`FLOWISE_USERNAME` / `FLOWISE_PASSWORD`) at minimum
- Integrate with Authentik OIDC when available for centralized identity management
- Restrict admin UI access to authorized operators only; regular users interact through OpenWebUI, not Flowise directly
- Audit who creates, modifies, and executes workflows

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
