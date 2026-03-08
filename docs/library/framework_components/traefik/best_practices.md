# Traefik — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating Traefik as the reverse proxy and TLS termination layer for the AI stack.

---

## Table of Contents

1. Deployment
2. Routing and Configuration
3. TLS Management
4. Observability
5. Reliability

## References

- Traefik Documentation: https://doc.traefik.io/traefik/
- Traefik Podman/systemd: https://doc.traefik.io/traefik/providers/docker/
- Let's Encrypt ACME: https://doc.traefik.io/traefik/https/acme/

---

# 1 Deployment

- Use the official Traefik image from Docker Hub (`traefik:v3.x`)
- Pin to a specific minor version tag; avoid `latest`
- Traefik starts immediately after the Podman network — it has no service dependencies
- Mount the static config file into the container; do not rely on CLI flags for complex configuration
- Mount the dynamic config directory as a read-only volume; Traefik watches for changes without restart

# 2 Routing and Configuration

- Use **file provider** for dynamic configuration in Podman environments — Podman does not expose a Docker-compatible socket by default
- Organize dynamic config as one file per routed service under `$AI_STACK_DIR/configs/traefik/dynamic/`
- Define entrypoints explicitly: `web` (port 80, HTTP) and `websecure` (port 443, HTTPS)
- Configure HTTP→HTTPS redirect on the `web` entrypoint as a global middleware
- Use meaningful router and service names (e.g., `openwebui-router`, `grafana-router`)
- Avoid wildcard routers; specify exact `Host()` rules per service

# 3 TLS Management

- Use TLS certificates stored in `$AI_STACK_DIR/configs/tls/` and referenced in the static config
- For internal deployments: use a self-signed CA; distribute the CA cert to client browsers
- For external deployments: use ACME (Let's Encrypt) with DNS challenge or HTTP challenge
- Set a minimum TLS version of `VersionTLS12`; prefer `VersionTLS13`
- Configure default TLS options globally rather than per-router

# 4 Observability

- Enable the Traefik dashboard on an internal-only entrypoint (do not expose to the public network)
- Enable access logs with the JSON format for Loki ingestion via Promtail
- Expose Prometheus metrics on `/metrics`; add Traefik as a scrape target in `prometheus.yml`
- Log request errors at `ERROR` level; avoid `DEBUG` in production

# 5 Reliability

- Set `Restart=always` in the quadlet `[Service]` section
- Traefik is stateless — no persistent volume needed beyond config mounts
- Health check: HTTP GET on the Traefik ping endpoint (`/ping`)
- If a backend service is down, Traefik returns 502; this is expected and does not crash Traefik
- Use circuit breakers for high-latency backends (vLLM, llama.cpp) if needed in future iterations
