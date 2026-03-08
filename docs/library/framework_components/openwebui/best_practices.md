# OpenWebUI — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Industry-standard best practices for deploying and operating OpenWebUI as the primary user interface for LLM interactions.

---

## Table of Contents

1. Deployment
2. Configuration
3. Performance
4. Reliability
5. Upgrades

## References

- OpenWebUI Documentation: https://docs.openwebui.com
- OpenWebUI GitHub: https://github.com/open-webui/open-webui

---

# 1 Deployment

- Run as a non-root container user; OpenWebUI's default image supports this
- Use a reverse proxy (Caddy/Traefik/nginx) for TLS termination; never expose the raw HTTP port externally
- Mount persistent storage for user data and conversation history to survive container restarts
- Set `WEBUI_SECRET_KEY` to a strong random value for session signing
- Use environment variables or Podman secrets for all credentials — never bake them into images

# 2 Configuration

- Connect to LiteLLM as the sole OpenAI-compatible backend rather than configuring multiple model endpoints directly — this keeps model management centralized
- Set `OPENAI_API_BASE` to the internal DNS name of LiteLLM (e.g., `http://litellm.ai-stack:4000`)
- Enable OIDC/OAuth2 for authentication when available (Authentik integration) rather than relying on built-in user management
- Configure rate limiting at the proxy layer to prevent abuse
- Disable user self-registration in production; provision accounts via the identity provider

# 3 Performance

- Set appropriate memory limits; OpenWebUI is a Node.js application and will consume memory proportional to concurrent sessions
- Enable HTTP/2 at the reverse proxy for multiplexed connections
- Use connection pooling if OpenWebUI connects directly to a database backend
- Serve static assets from the reverse proxy cache where possible

# 4 Reliability

- Configure health checks on the `/health` endpoint at 30-second intervals
- Set `Restart=always` in the systemd quadlet to recover from crashes
- Back up user configuration and conversation data regularly
- Monitor container resource usage via Prometheus metrics

# 5 Upgrades

- Pin to specific image tags; test new versions in a staging environment first
- Review the changelog for breaking changes in API compatibility or database schema migrations
- Back up persistent volumes before upgrading
- Verify OIDC integration still functions after major version bumps
