# Loki — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for Loki log aggregation.

---

## Table of Contents

1. Network Security
2. Access Control
3. Data Protection
4. Container Security

## References

- Loki Security: https://grafana.com/docs/loki/latest/operations/security/
- OWASP Logging Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Logging_Cheat_Sheet.html

---

# 1 Network Security

- Do not expose Loki's HTTP API (port 3100) outside the Podman network
- Only Promtail and Grafana should connect to Loki — restrict via network policy
- If external access is needed, place behind the reverse proxy with authentication
- Use TLS for Loki's HTTP listener if logs transit untrusted networks

# 2 Access Control

- Loki has no built-in authentication — rely on network isolation and the reverse proxy
- Use multi-tenancy headers (`X-Scope-OrgID`) to logically separate log streams if needed
- Restrict access to Loki's push API to Promtail only
- Limit who can query logs — log data can contain sensitive application output (prompts, API keys in error messages, PII)

# 3 Data Protection

- Logs may contain sensitive data: sanitize at the Promtail level before ingestion
- Use pipeline stages to redact or mask sensitive patterns (API keys, tokens, email addresses)
- Set retention policies to limit how long sensitive data persists
- Encrypt the data volume at rest using LUKS or filesystem-level encryption
- Do not log raw LLM prompts unless explicitly needed for debugging

# 4 Container Security

- Run as a non-root user (the official image runs as user `loki`, UID 10001)
- Use rootless Podman for outer isolation
- Pin the image to a specific tag or digest
- Mount configuration read-only; only the data volume is read-write
- Drop all unnecessary Linux capabilities
- Scan the image for vulnerabilities before deployment
