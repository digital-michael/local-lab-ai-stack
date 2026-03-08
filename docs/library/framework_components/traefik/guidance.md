# Traefik — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for Traefik within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Layout
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Publishes ports 80 (HTTP) and 443 (HTTPS) to the host — the only container to do so
- No persistent data volume needed; config mounts are read-only
- Resource limits: 0.5 CPU, 256 MB RAM
- Traefik is position 2 in the startup order (after the Podman network, before all other services)
- Decision: D-011 — selected over Caddy and nginx for label-based dynamic routing and native Authentik forward-auth support

# 2 Configuration Layout

```
$AI_STACK_DIR/configs/traefik/
├── traefik.yaml              # Static configuration (entrypoints, providers, TLS options)
└── dynamic/
    ├── middlewares.yaml      # Global middlewares (HTTPS redirect, secure headers, forward-auth)
    ├── openwebui.yaml        # Router + service for OpenWebUI
    ├── grafana.yaml          # Router + service for Grafana
    ├── flowise.yaml          # Router + service for Flowise
    └── authentik.yaml        # Router + service for Authentik
```

Static config and dynamic config are separate concerns:
- `traefik.yaml` is stable; changes require a container restart
- `dynamic/` files are hot-reloaded by Traefik's file provider watcher; no restart needed

# 3 Integration Patterns

- **Authentik forward-auth:** Traefik forwards all requests to the Authentik outpost at `http://authentik.ai-stack:9000/outpost.goauthentik.io/auth/traefik` before routing to the backend. On auth failure, Authentik redirects to the login page.
- **OpenWebUI:** Routed via `Host(webui.ai-stack)` or the configured external hostname; forward-auth applied
- **Grafana:** Routed via `Host(grafana.ai-stack)`; forward-auth applied
- **Flowise:** Routed via `Host(flowise.ai-stack)`; forward-auth applied
- **LiteLLM, Qdrant, PostgreSQL:** Not routed through Traefik — internal network only

# 4 Operational Notes

- The Traefik dashboard is available at port 8080 on the internal network; not exposed to the host
- Access logs written to stdout; collected by Promtail via journald
- Prometheus metrics at `/metrics` on internal entrypoint; scraped by Prometheus
- TLS certificates stored at `$AI_STACK_DIR/configs/tls/`; certificate rotation requires remounting (or ACME auto-renewal)
- If a backend service is unhealthy and Traefik returns 502, check the backend container's health status first — Traefik is rarely the root cause
