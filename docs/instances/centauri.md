# Instance: CENTAURI

**Role:** [Controller Role](../roles/controller-role.md)
**Hostname:** CENTAURI (workstation)
**Node ID:** CENTAURI
**Tailnet IP:** 100.64.0.4
**Network mode:** isolated (default — separate Podman network per group)

---

## Identity

| Property | Value |
|---|---|
| Node alias | `controller-1` |
| Tailnet IP | `100.64.0.4` |
| Stack LAN hostname | `stack.localhost` |
| Internal services | `*.stack.localhost` via Traefik |
| External access | `*.photondatum.space` proxied via photondatum.space Caddy |

---

## Active Models

| Model | Backend | Notes |
|---|---|---|
| `llama3.1:8b` | Ollama | General purpose |
| `qwen3.5:4b` | Ollama | Compact, fast |
| `qwen3:8b` | Ollama | Mid-size reasoning |
| `llama3.2:3b` | Ollama | Lightweight |

---

## Network Mode: Isolated

Each group has its own Podman network. Traefik joins all group networks
to route requests. Containers with cross-group dependencies declare
multiple `Network=` entries in their quadlet.

```
ai-stack-route    → route-traefik (host net, joins all others)
ai-stack-infer    → infer-litellm, infer-ollama, infer-vllm
ai-stack-know     → know-index, know-qdrant
ai-stack-app      → app-openwebui, app-flowise, app-homepage
ai-stack-store    → store-postgres
ai-stack-obs      → obs-prometheus, obs-grafana, obs-loki, obs-promtail
```

Cross-group network memberships:
- `ai-stack-know-index`: joins `ai-stack-know` + `ai-stack-infer` (calls LiteLLM)
- `ai-stack-app-openwebui`: joins `ai-stack-app` + `ai-stack-infer` + `ai-stack-store`
- `ai-stack-app-flowise`: joins `ai-stack-app` + `ai-stack-infer` + `ai-stack-store`
- `ai-stack-route-traefik`: joins all group networks

---

## Group: `ai-stack-route` — Instance Values

**Traefik `forwardAuth` endpoint:** `https://auth.photondatum.space`
(Edge Authentik — always-on; Traefik delegates all auth decisions there)

**Entrypoints:**
| Entrypoint | Bind | Port | Purpose |
|---|---|---|---|
| `web` | `0.0.0.0` | 80 | HTTP redirect to HTTPS |
| `websecure` | `0.0.0.0` | 443 | LAN HTTPS |
| `tailnet` | `100.64.0.4` | 8443 | Tailnet-only entry (knowledge-index, MCP) |

**Traefik hostname pattern:**
- LAN: `*.stack.localhost` → self-signed cert, browser trust required
- External: `*.photondatum.space` → Host header forwarded from Caddy on photondatum.space

**Stale router to remove:**
`openwebui-public-com` in `configs/traefik/dynamic/services.yaml` references
`chat.photondatum.com` — a domain not owned by this deployment. Remove this router.

**Temporary bypass to resolve after Authentik moves to VPS:**
`openwebui-public` bypasses `authentik` middleware because the Authentik outpost
External URL is currently `auth.stack.localhost` (LAN-only), which breaks external
browser redirects. Once Authentik is running on the VPS at `https://auth.photondatum.space`,
restore the `authentik` middleware on this router and remove the bypass.

---

## Group: `ai-stack-infer` — Instance Values

| Container | Port bind | Notes |
|---|---|---|
| `ai-stack-infer-litellm` | `127.0.0.1:9000:4000` | File config mode |
| `ai-stack-infer-ollama` | `127.0.0.1:11434:11434` | CPU inference |
| `ai-stack-infer-vllm` | — | Disabled (no GPU) |
| `ai-stack-infer-turbo` | — | Placeholder; not deployed |

LiteLLM config: `configs/litellm/proxy_config.yaml`
Ollama data: `$AI_STACK_DIR/ollama/`

---

## Group: `ai-stack-know` — Instance Values

| Container | Port bind | Resource limits |
|---|---|---|
| `ai-stack-know-index` | `0.0.0.0:8100:8100` | `--cpus=1 --memory=512m` |
| `ai-stack-know-qdrant` | `127.0.0.1:6333:6333` | `--cpus=1 --memory=1g` |

Qdrant data: `$AI_STACK_DIR/qdrant/`
Knowledge libraries: `$AI_STACK_DIR/libraries/`

Embed model: `llama3.1:8b` via LiteLLM at `http://ai-stack-infer-litellm:4000`
Chunk size: 400 tokens

---

## Group: `ai-stack-app` — Instance Values

| Container | Internal URL (via Traefik) | External URL |
|---|---|---|
| `ai-stack-app-openwebui` | `https://openwebui.stack.localhost` | `https://chat.photondatum.space` |
| `ai-stack-app-flowise` | `https://flowise.stack.localhost` | _(add Caddy route on photondatum.space)_ |
| `ai-stack-app-homepage` | `https://dashboard.stack.localhost` | _(LAN only currently)_ |

OpenWebUI: `openwebui_api_key` must equal `litellm_master_key` — see §4.3 of playbook.

---

## Group: `ai-stack-store` — Instance Values

| Container | Port bind | Databases |
|---|---|---|
| `ai-stack-store-postgres` | `127.0.0.1:5432:5432` | `openwebui`, `flowise` |

Store data: `$AI_STACK_DIR/postgres/`

Note: Authentik database lives on the edge node (`ai-stack-iam-postgres` on
photondatum.space). This PostgreSQL instance serves only application data.

---

## Group: `ai-stack-obs` — Instance Values

| Container | Port bind | Notes |
|---|---|---|
| `ai-stack-obs-prometheus` | `127.0.0.1:9091:9090` | Metrics (localhost only) |
| `ai-stack-obs-grafana` | via Traefik | `https://grafana.stack.localhost` |
| `ai-stack-obs-loki` | `127.0.0.1:3100:3100` | Log ingestion (Promtail → here) |
| `ai-stack-obs-promtail` | none | Ships from this node + workers |

Grafana config: `configs/grafana/`
Loki config: `configs/loki/local-config.yaml`
Prometheus config: `configs/prometheus/prometheus.yml`

---

## External Services on This Host (Not Containerized)

| Service | Manager | Notes |
|---|---|---|
| `tailscale` | systemd | Tailnet agent; tailnet IP `100.64.0.4` |

---

## Known Issues / Deferred Work

| Issue | Status | Resolution |
|---|---|---|
| `openwebui-public` bypasses `authentik` middleware | Temporary | Remove bypass after Authentik moves to VPS and External URL updated to `https://auth.photondatum.space` |
| Stale router `openwebui-public-com` (refs `chat.photondatum.com`) | Pending cleanup | Remove from `configs/traefik/dynamic/services.yaml` |
| Authentik in this stack (before VPS migration) | Pre-migration | Authentik currently runs here; will move to edge node once VPS RAM is confirmed |
| Forgejo+Authentik OIDC auth | Not wired | Configured on photondatum.space Forgejo, not this node |

---

## Operational Notes

- Config root: `configs/`
- Data root: `$AI_STACK_DIR/` (see `configs/config.json` → `ai_stack_dir`)
- Manage all containers: `bash scripts/start.sh` / `bash scripts/stop.sh`
- Health check: `bash scripts/status.sh`
- Full regression: `make test-all` (known failures: T-019, T-023, T-047)
- Heartbeat timer: `systemctl --user status ai-stack-heartbeat.timer`
