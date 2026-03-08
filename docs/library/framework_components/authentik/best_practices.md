# Authentik — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating Authentik as the identity provider and SSO gateway.

---

## Table of Contents

1. Deployment
2. Identity Management
3. OIDC Provider Configuration
4. Performance
5. Reliability

## References

- Authentik Documentation: https://goauthentik.io/docs/
- Authentik GitHub: https://github.com/goauthentik/authentik
- OpenID Connect Specification: https://openid.net/connect/

---

# 1 Deployment

- Deploy the Authentik server container backed by PostgreSQL for persistent storage
- Authentik requires a Redis instance for caching and task queuing — plan for this as an additional service or use an embedded alternative
- Set `AUTHENTIK_SECRET_KEY` to a strong random value (minimum 50 characters)
- Configure `AUTHENTIK_POSTGRESQL__*` environment variables to connect to the shared PostgreSQL instance
- Place behind the reverse proxy for TLS termination; Authentik serves HTTP by default

# 2 Identity Management

- Create a dedicated admin account immediately after first boot; do not use the default `akadmin` password
- Disable self-enrollment unless explicitly needed
- Use groups to manage permissions: create groups for `admins`, `operators`, and `users`
- Map groups to RBAC roles in downstream applications (OpenWebUI, Grafana, Flowise)
- Provision user accounts through Authentik's admin UI or API — centralize identity

# 3 OIDC Provider Configuration

- Create one OIDC application per downstream service (OpenWebUI, Grafana, Flowise)
- Each application gets its own client ID and client secret
- Configure redirect URIs precisely — no wildcards in production
- Use `authorization_code` grant type for web applications
- Include appropriate scopes: `openid`, `profile`, `email` at minimum
- Sign tokens with RS256 (asymmetric) for verification by relying parties

# 4 Performance

- Authentik is lightweight; 2 cores and 2 GB RAM are sufficient for small deployments
- Redis caching handles session and flow state; ensure Redis has adequate memory
- Monitor login latency — slow logins degrade user experience across all services
- Authentik's worker process handles background tasks; ensure it runs alongside the server

# 5 Reliability

- Authentik is a dependency for all SSO-enabled services — plan for high availability if SSO is critical
- Set `Restart=always` in the systemd quadlet
- Back up the PostgreSQL database (which contains Authentik's state) regularly
- Test OIDC flows after each Authentik upgrade — token format or claim behavior may change
- Export Authentik flows and blueprints to version control for disaster recovery
