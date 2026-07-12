# Grafana — Security
**Last Updated:** 2026-07-10

## Purpose
Security standards and hardening guidelines for Grafana dashboards and visualization.

---

## Table of Contents

1. Authentication and Authorization
2. Network Security
3. Dashboard Security
4. API Security
5. Container Security

## References

- Grafana Security: https://grafana.com/docs/grafana/latest/setup-grafana/configure-security/
- OWASP Top 10: https://owasp.org/www-project-top-ten/

---

# 1 Authentication and Authorization

- SSO via Authentik `auth.proxy`: Grafana trusts the `X-authentik-username` header injected by the Authentik outpost after forwardAuth passes. This is simpler than OAuth2 for proxy-fronted deployments — no client secret needed.
- Whitelist the Podman network CIDR (`10.89.0.0/24`) in `auth.proxy.whitelist` to prevent header spoofing from outside the container network.
- Disable the Grafana login form (`disable_login_form = true`) — users must authenticate through Authentik; direct password login is not available.
- Set `auto_sign_up = true` so Grafana auto-creates an account on first SSO login.
- Auto-assign `Admin` role for all SSO users (`auto_assign_org_role = Admin`) — role management happens in Authentik, not Grafana.
- Disable anonymous access; no `GF_AUTH_ANONYMOUS_ENABLED` needed when login form is disabled and auth.proxy is the gate.
- Additional headers (`Email:X-authentik-email Name:X-authentik-name`) keep Grafana user profiles in sync with Authentik identity.

# 2 Network Security

- Do not expose Grafana directly to the internet without a reverse proxy with TLS
- Host port 3001 maps to container port 3000; restrict to internal network
- Use the internal Podman network for data source connections
- Set `GF_SERVER_ROOT_URL` correctly for proper OAuth redirect handling
- Allow embedding only for trusted origins: configure `GF_SECURITY_ALLOW_EMBEDDING=false`

# 3 Dashboard Security

- Dashboards can reveal infrastructure details, metrics patterns, and operational data
- Restrict dashboard folder permissions by team/role
- Avoid embedding sensitive data directly in dashboard variables or annotations
- Use Grafana's audit log to track dashboard creation and modification
- Export critical dashboards to version control for auditability

# 4 API Security

- Generate API tokens with specific roles (Viewer, Editor); do not share the admin token
- Set token expiration; avoid long-lived tokens
- Use service accounts for automated provisioning instead of personal admin accounts
- Rate-limit API access at the proxy layer
- Disable unused API endpoints if possible

# 5 Container Security

- Run as a non-root user (the official image uses user `grafana`, UID 472)
- Use rootless Podman for outer isolation
- Pin the image to a specific tag or digest
- Mount provisioning files read-only; only the Grafana database volume is read-write
- Drop all unnecessary Linux capabilities
- Scan the image for vulnerabilities before deployment
