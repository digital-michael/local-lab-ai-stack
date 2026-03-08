# Qdrant — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for Qdrant vector storage.

---

## Table of Contents

1. Authentication
2. Network Security
3. Data Protection
4. Container Security

## References

- Qdrant Security: https://qdrant.tech/documentation/guides/security/
- OWASP Top 10: https://owasp.org/www-project-top-ten/

---

# 1 Authentication

- Always set `QDRANT__SERVICE__API_KEY` — Qdrant has no authentication by default
- Inject the API key via Podman secrets; never hardcode in configuration files
- All clients (Knowledge Index Service, Flowise) must use the API key in requests
- Rotate the API key periodically; update all consuming services when rotating
- Qdrant does not support per-user access control — enforce access boundaries at the application layer

# 2 Network Security

- Expose Qdrant only on the internal `ai-stack-net` Podman network
- Do not publish ports 6333 or 6334 to the host unless debugging
- Only the Knowledge Index Service and Flowise should communicate with Qdrant
- If external access is needed for debugging, use a VPN or SSH tunnel
- gRPC (6334) does not support TLS natively in Qdrant's default config — rely on network isolation

# 3 Data Protection

- Qdrant stores vector embeddings and metadata payloads — payloads may contain document content
- Encrypt the storage volume at rest using LUKS or filesystem-level encryption
- Implement collection-level access control in the application layer if different libraries have different sensitivity levels
- Use the snapshot API for backups; store snapshots encrypted
- Apply data retention policies; delete old collections when libraries are deprecated
- Qdrant does not redact data in logs — avoid storing highly sensitive content as payload text

# 4 Container Security

- Run as a non-root user inside the container
- Use rootless Podman for user-namespace isolation
- Pin the image to a specific tag or digest
- The container needs no special devices or capabilities
- Mount storage as read-write only for the data directory; configuration can be read-only
- Scan the image for vulnerabilities before deployment
