# Promtail — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for Promtail log shipping.

---

## Table of Contents

1. Access and Privileges
2. Data Protection
3. Network Security
4. Container Security

## References

- Promtail Documentation: https://grafana.com/docs/loki/latest/send-data/promtail/
- OWASP Logging Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html

---

# 1 Access and Privileges

- Promtail needs read access to container log files — mount log directories read-only
- In rootless Podman, Promtail must run with the same UID or in the same user namespace as the other containers
- Do not grant Promtail write access to any directories other than its positions file
- Promtail does not need network access to any service except Loki

# 2 Data Protection

- Promtail is the first point where log sanitization should occur
- Use `replace` pipeline stages to redact sensitive patterns before logs reach Loki:
  - API keys: `replace { expression: "(Bearer\\s+)[\\w-]+" replace: "${1}***REDACTED***" }`
  - Email addresses, IP addresses, and other PII as appropriate
- Drop log lines that contain raw LLM prompts unless debugging is active
- Promtail does not store logs persistently — only the positions file persists

# 3 Network Security

- Promtail connects to Loki over the internal Podman network — no external exposure needed
- Do not publish any host ports for Promtail
- If shipping to a remote Loki instance, use TLS for the HTTP push connection
- Set `X-Scope-OrgID` header to the stack's tenant ID for all pushed log streams

# 4 Container Security

- Run as a non-root user when possible (may need UID mapping for log file access)
- Use rootless Podman for outer isolation
- Pin the image to a specific tag or digest matching the Loki version
- Mount only the specific log directories needed — not the entire filesystem
- Drop all unnecessary Linux capabilities
- Scan the image for vulnerabilities before deployment
