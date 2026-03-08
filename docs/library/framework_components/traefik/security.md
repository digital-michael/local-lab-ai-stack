# Traefik — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for Traefik in the AI stack.

---

## Table of Contents

1. Network Exposure
2. TLS
3. Authentication Middleware
4. Headers and CORS
5. Dashboard Security
6. Container Security

## References

- Traefik Security Advisories: https://github.com/traefik/traefik/security/advisories
- OWASP Secure Headers: https://owasp.org/www-project-secure-headers/
- Mozilla TLS Guidelines: https://wiki.mozilla.org/Security/Server_Side_TLS

---

# 1 Network Exposure

- Traefik is the **only** container that publishes ports 80 and 443 to the host
- All other user-facing services (OpenWebUI, Grafana, Flowise, Authentik) must be bound to the internal Podman network only — never publish their ports to the host
- Internal services (LiteLLM, Qdrant, PostgreSQL) must not be accessible through Traefik at all
- Restrict the Traefik API and dashboard to an internal-only entrypoint; never expose to port 80/443

# 2 TLS

- Require HTTPS for all external traffic; configure a redirect middleware on the HTTP entrypoint
- Set minimum TLS version to `VersionTLS12`; prefer `VersionTLS13` where clients support it
- Disable weak cipher suites; follow Mozilla's "Intermediate" or "Modern" TLS profile
- Renew certificates before expiry; configure ACME with a valid email for expiry notifications
- Store private keys in `$AI_STACK_DIR/configs/tls/` with file permissions `0600`

# 3 Authentication Middleware

- Configure Authentik forward-auth as a middleware on all user-facing routers
- The forward-auth middleware must reject unauthenticated requests before they reach backend services
- Define the middleware once at the file provider level; reference it by name in per-service routers
- Do not bypass forward-auth for any user-facing route except `/health` and `/ping` endpoints
- Validate that the Authentik outpost URL is reachable during startup; Traefik should fail fast, not silently pass traffic

# 4 Headers and CORS

- Add secure response headers via a global middleware:
  - `X-Frame-Options: DENY`
  - `X-Content-Type-Options: nosniff`
  - `X-XSS-Protection: 1; mode=block`
  - `Referrer-Policy: strict-origin-when-cross-origin`
  - `Content-Security-Policy`: define per-service (OpenWebUI has different CSP needs than Grafana)
- Do not configure permissive CORS (`*`) on any route; define explicit allowed origins

# 5 Dashboard Security

- Enable the Traefik API and dashboard only on a separate internal entrypoint (e.g., port 8080 bound to `127.0.0.1` or the Podman network only)
- Protect the dashboard with basic auth or forward-auth if exposed beyond localhost
- In production, consider disabling the dashboard entirely; use metrics/logs for observability instead

# 6 Container Security

- Run Traefik as a non-root user inside the container if the image supports it
- Mount config files as read-only volumes (`:ro`)
- Do not mount the Docker/Podman socket — use the file provider instead (avoids container escape via socket access)
- Apply resource limits: 0.5 CPU, 256 MB RAM is sufficient for routing workloads at this scale
