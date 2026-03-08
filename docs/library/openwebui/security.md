# OpenWebUI — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for OpenWebUI in a production AI stack.

---

## Table of Contents

1. Authentication and Authorization
2. Network Security
3. Session Management
4. Input Validation
5. Data Protection
6. Container Security

## References

- OWASP Top 10: https://owasp.org/www-project-top-ten/
- OpenWebUI Security: https://docs.openwebui.com

---

# 1 Authentication and Authorization

- Integrate with Authentik via OIDC for centralized authentication; do not rely solely on OpenWebUI's built-in auth
- Disable self-registration in production (`ENABLE_SIGNUP=false`)
- Enforce strong password policies if using local accounts as a fallback
- Use RBAC to separate admin users from standard users
- Audit user access and role assignments periodically

# 2 Network Security

- Never expose OpenWebUI directly to the internet; always place behind a TLS-terminating reverse proxy
- Bind the container to the internal Podman network only; publish the port exclusively through the proxy
- Use HTTPS with TLS 1.2+ and strong cipher suites at the proxy layer
- Set security headers: `Strict-Transport-Security`, `X-Content-Type-Options`, `X-Frame-Options`, `Content-Security-Policy`
- Rate-limit login attempts to mitigate brute-force attacks

# 3 Session Management

- Set `WEBUI_SECRET_KEY` to a cryptographically random value (minimum 32 bytes); rotate periodically
- Configure session timeouts appropriate for the deployment (e.g., 8 hours for internal use)
- Use `Secure`, `HttpOnly`, and `SameSite=Strict` cookie attributes (configure at the proxy if needed)
- Invalidate sessions on password change or role modification

# 4 Input Validation

- OpenWebUI passes user prompts to the LLM backend — ensure the backend (LiteLLM) has its own API key protection
- Be aware of prompt injection risks; OpenWebUI is the user-facing surface
- Sanitize any user-uploaded content (documents, images) before processing
- Limit file upload sizes to prevent denial-of-service

# 5 Data Protection

- Conversation history may contain sensitive data; encrypt volumes at rest using LUKS or filesystem-level encryption
- Apply access controls so users can only see their own conversations
- Implement data retention policies; provide the ability to purge old conversations
- Log access to sensitive data for audit purposes

# 6 Container Security

- Run as a non-root user inside the container (rootless Podman provides the outer layer)
- Use read-only root filesystem where possible (`--read-only` flag)
- Drop all Linux capabilities not needed by the application
- Pin the image to a specific digest to prevent supply-chain attacks
- Scan images for CVEs before deployment using `podman image scan` or Trivy
