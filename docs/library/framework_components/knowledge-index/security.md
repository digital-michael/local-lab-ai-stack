# Knowledge Index Service — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for the Knowledge Index Service in the AI stack.

---

## Table of Contents

1. Network Security
2. Input Validation
3. Library Integrity Verification
4. Authentication and Authorization
5. Container Security

## References

- OWASP API Security Top 10: https://owasp.org/www-project-api-security/
- OWASP Input Validation Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/Input_Validation_Cheat_Sheet.html
- Python Security Practices: https://python.org/dev/security/

---

# 1 Network Security

- The Knowledge Index Service is **internal only** — never route it through Traefik or expose its port to the host
- Bind to the internal Podman network (`ai-stack-net`) only
- Accepts connections from Flowise and other internal services; reject all external traffic
- Do not expose the OpenAPI docs endpoint (`/v1/docs`) in production if access control is not enforced

# 2 Input Validation

- Validate all query strings and library names at the API boundary; reject inputs that fail schema validation with HTTP 400
- Sanitize library names before using them as Qdrant collection names or PostgreSQL identifiers — prevent injection via crafted library names
- Do not accept file paths from API consumers; library discovery is filesystem-driven, not consumer-driven
- Set maximum query length and maximum result count limits; reject requests exceeding them

# 3 Library Integrity Verification

- Verify `checksums.txt` for every library before ingestion, regardless of discovery profile
- For `local` profile: verify `signature.asc` if present; log a warning if absent
- For `WAN` profile: `signature.asc` is mandatory — reject libraries without a valid signature
- Use constant-time comparison for checksum verification; do not short-circuit on mismatch
- Log all integrity failures as `WARNING` with the library name, file, and failure reason
- Never ingest a library that fails integrity or signature verification

# 4 Authentication and Authorization

- The service is internal to the Podman network; external authentication is handled by Traefik + Authentik
- For MVP: no per-request authentication on the internal API — network isolation is the trust boundary
- Future: if the service is exposed to a broader network, add API key or OIDC token validation per request
- Do not log query contents unless explicitly required for debugging — queries may contain sensitive intent

# 5 Container Security

- Run as a non-root user inside the container; define `USER` in the Dockerfile
- Mount library volumes as read-only in the container — ingestion reads files, does not modify them
- Do not mount the Podman socket or any sensitive host path
- Apply resource limits: 1 CPU, 512 MB RAM
- Use a minimal base image (e.g., `python:3.12-slim`); avoid full OS images
- Pin all Python dependencies with exact version hashes in `requirements.txt`
