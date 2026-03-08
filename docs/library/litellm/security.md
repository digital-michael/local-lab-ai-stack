# LiteLLM — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for LiteLLM as the model routing gateway.

---

## Table of Contents

1. API Key Management
2. Network Security
3. Access Control
4. Data Protection
5. Container Security

## References

- LiteLLM Security: https://docs.litellm.ai
- OWASP API Security Top 10: https://owasp.org/www-project-api-security/

---

# 1 API Key Management

- Set a strong `LITELLM_MASTER_KEY` (minimum 32 characters, cryptographically random)
- Inject the master key via Podman secrets — never in environment files or config maps in plaintext
- Issue per-user or per-service API keys via LiteLLM's key management API for granular access control
- Rotate keys periodically; LiteLLM supports key creation and revocation via API
- Never log API key values; mask them in log output

# 2 Network Security

- LiteLLM listens on port 4000 internally; expose only port 9000 on the host via the reverse proxy
- Internal services (OpenWebUI, Flowise) connect via `http://litellm.ai-stack:4000` on the Podman network
- Do not expose LiteLLM's admin API to untrusted networks
- Use TLS at the reverse proxy layer; internal traffic uses plain HTTP over the isolated bridge network
- Block direct access to vLLM and llama.cpp from outside the Podman network — all inference goes through LiteLLM

# 3 Access Control

- Use LiteLLM's built-in user/team key system to enforce per-model access policies
- Restrict expensive models (e.g., llama3.1-70b) to specific API keys
- Set budget limits per key to prevent runaway usage
- Audit API key usage through LiteLLM's spend tracking database
- Disable unused model endpoints to reduce attack surface

# 4 Data Protection

- Prompts and completions pass through LiteLLM — this is sensitive data
- Enable request logging to PostgreSQL for auditability, but protect the database with appropriate access controls
- Do not enable verbose logging in production — it may expose prompt content in log files
- Apply data retention policies to request logs; purge old entries periodically
- If request logging is enabled, ensure the PostgreSQL connection uses the secret-injected password

# 5 Container Security

- Run as a non-root user inside the container
- Use rootless Podman for user-namespace isolation
- Pin the image to a specific tag or digest
- The container needs no special capabilities or device access
- Scan the image for vulnerabilities before deployment
