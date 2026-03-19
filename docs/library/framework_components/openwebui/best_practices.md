# OpenWebUI — Best Practices
**Last Updated:** 2026-03-19 UTC

## Purpose
Industry-standard best practices for deploying and operating OpenWebUI as the primary user interface for LLM interactions.

---

## Table of Contents

1. Deployment
2. Configuration
3. Performance
4. Reliability
5. Upgrades
6. Known Pitfalls (Podman / non-Docker-Compose deployments)

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

# 6 Known Pitfalls (Podman / non-Docker-Compose deployments)

## 6.1 Docker Compose defaults baked into the OCI image

The official OpenWebUI image ships with `OLLAMA_BASE_URL=/ollama` — a relative path designed for the Docker Compose nginx reverse-proxy setup. In rootless Podman this value is meaningless and causes the UI to report "Ollama: network problem" with no models visible.

**Fix**: Always set `OLLAMA_BASE_URL=http://<svc>.ai-stack:<port>` explicitly in the quadlet `[Service]` environment block before the first container start; do not rely on the image default.

## 6.2 webui.db takes precedence over env vars — first-boot ordering

OpenWebUI writes all connection config (Ollama URL, API base, etc.) to a SQLite database (`webui.db`, table `config`, JSON column `data`) **at first container start**. The Docker Compose image default `http://host.docker.internal:11434` is hard-coded into this initialization path and is written to the DB regardless of the `OLLAMA_BASE_URL` env var.

Values already present in the DB are used at runtime; the env var is not authoritative once the DB row exists.

Consequences:
- **Every fresh deployment** will have `host.docker.internal:11434` in the DB after first start, regardless of how `OLLAMA_BASE_URL` is set in the quadlet.
- Changing env vars after first boot has no effect on connection config; the DB must be patched.
- `OLLAMA_BASE_URL` only matters to prevent the image default `/ollama` (Docker Compose nginx path) from appearing in the env — it does not control what the DB is initialized with.

**Required on every fresh deployment**: after openwebui first starts, patch the DB and restart. `diagnose.sh --profile full --fix` performs this automatically via `_check_integrations() → openwebui/db-ollama-url`.

**Detection** (manual, via `diagnose.sh --profile full`):
```bash
podman exec openwebui python3 -c "
import sqlite3, json
db='<data_path>/webui.db'
row=sqlite3.connect(db).execute('SELECT data FROM config WHERE id=1').fetchone()
print(json.loads(row[0])['ollama']['base_urls'])
"
```

**Fix**: Patch the DB and restart:
```python
import sqlite3, json
conn = sqlite3.connect('<data_path>/webui.db')
row = conn.execute('SELECT data FROM config WHERE id=1').fetchone()
cfg = json.loads(row[0])
cfg['ollama']['base_urls'] = ['http://ollama.ai-stack:11434']
conn.execute('UPDATE config SET data=? WHERE id=1', (json.dumps(cfg),))
conn.commit()
```
Then `systemctl --user restart openwebui`.

`diagnose.sh --profile full --fix` performs this automatically via the `openwebui/db-ollama-url` check in `_check_integrations()`.

## 6.3 openwebui_api_key must equal litellm_master_key

OpenWebUI forwards `OPENAI_API_KEY` (sourced from the `openwebui_api_key` Podman secret) as `Authorization: Bearer <key>` on every call to LiteLLM. If this value does not match `LITELLM_MASTER_KEY`, every model listing and inference request returns HTTP 401 — surfacing in the UI as "failed to fetch models" and an empty Bearer key field on the Connections page.

**Fix**: Recreate the secret with the correct value:
```bash
podman secret rm openwebui_api_key
printf '<litellm_master_key_value>' | podman secret create openwebui_api_key -
systemctl --user restart openwebui
```

Always generate both keys from the same source of truth (e.g., `config.json`) and provision them together. `diagnose.sh --profile full --fix` detects and corrects this mismatch via the `openwebui→litellm` check in `_check_integrations()`.
