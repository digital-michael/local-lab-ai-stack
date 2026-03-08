# Prometheus — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for Prometheus metrics collection.

---

## Table of Contents

1. Network Security
2. Access Control
3. Data Protection
4. Container Security

## References

- Prometheus Security: https://prometheus.io/docs/operating/security/
- OWASP Top 10: https://owasp.org/www-project-top-ten/

---

# 1 Network Security

- Do not expose Prometheus to the public internet — metrics data reveals internal architecture
- Publish host port 9091 only for Grafana access on the internal network; or keep it unpublished and let Grafana use the Podman DNS name
- Scrape targets exclusively over the internal `ai-stack-net` network
- If remote write/read is needed, authenticate and encrypt the connection
- Block external access to the Prometheus admin API (`/-/reload`, `/-/quit`)

# 2 Access Control

- Prometheus has no built-in authentication — protect it via the reverse proxy with Authentik SSO or basic auth
- The `/api/v1/query` endpoint allows arbitrary PromQL queries; restrict access to operators
- Use `web.config.file` to enable TLS and basic auth natively if reverse proxy is not available
- Limit who can modify scrape configs and alerting rules — changes to these files affect monitoring coverage

# 3 Data Protection

- Metrics can reveal sensitive operational data (request rates, error patterns, infrastructure topology)
- Apply appropriate access controls to the Prometheus UI and API
- Drop high-cardinality labels that might contain sensitive content (user IDs, prompts, etc.) using metric relabeling
- Set data retention appropriate to compliance requirements
- Back up TSDB data encrypted if it leaves the host

# 4 Container Security

- Run as a non-root user (the official image runs as `nobody`)
- Use rootless Podman for outer isolation
- Pin the image to a specific tag or digest
- Mount configuration read-only; TSDB is the only read-write volume
- Drop all unnecessary Linux capabilities
- Scan the image for vulnerabilities before deployment
