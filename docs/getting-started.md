# Getting Started

**Last Updated:** 2026-03-25

A step-by-step guide to installing, configuring, deploying, and verifying the AI stack on a new Linux controller node.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Linux (Fedora/RHEL/CentOS) | Tested on Fedora 40+; other systemd-based distros should work |
| Podman 4.x+ | Rootless mode; systemd user units (quadlets) |
| Python 3.9+ | Used by `configure.sh` and the knowledge-index service |
| `git`, `jq` | Required by all scripts |
| NVIDIA GPU (optional) | Required for vLLM; Ollama runs on CPU without it |

---

## Step 1 — Clone the repository

```bash
git clone git@github.com:digital-michael/local-lab-ai-stack.git
cd local-lab-ai-stack
```

---

## Step 2 — Install system dependencies and create the storage layout

```bash
bash scripts/install.sh
```

This installs `podman`, `git`, and `python3` via `dnf`, then creates the storage layout under `$AI_STACK_DIR` (default: `~/ai-stack`).

To use a custom storage location:

```bash
AI_STACK_DIR=/opt/ai-stack bash scripts/install.sh
```

---

## Step 3 — Validate the environment

```bash
bash scripts/validate-system.sh
```

Checks that Podman is installed, the storage directory exists, and (optionally) that a GPU is detected. Exits non-zero on any error.

---

## Step 4 — Generate TLS certificates

```bash
bash scripts/generate-tls.sh
```

Creates a local CA and a server certificate under `~/ai-stack/configs/tls/`. Traefik uses these for HTTPS on all services.

> To trust the local CA in your browser, follow the instructions printed by the script.

---

## Step 5 — Review and edit configuration

Open `configs/config.json` to verify defaults. Most values are ready to use, but you should at minimum review:

- `"node_profile"` — should be `"controller"` on the primary machine
- `"models"` — add or remove models depending on your hardware (see [How-To: Add a Model](operator-faq.md#add-a-new-ollama-model))
- GPU-backed models require an NVIDIA GPU with CDI configured (see [How-To: Enable GPU Inference](operator-faq.md#enable-gpu-inference))

To run hardware detection and get a recommended configuration:

```bash
bash scripts/configure.sh detect-hardware
bash scripts/configure.sh recommend
```

---

## Step 6 — Generate LiteLLM model config

```bash
bash scripts/configure.sh generate-litellm-config
```

Reads `models[]` from `config.json` and writes `configs/models.json`, which LiteLLM uses as its routing table. Re-run this whenever you add or change models.

---

## Step 7 — Provision secrets

```bash
bash scripts/configure.sh generate-secrets
```

Prompts you to enter values for each required secret and stores them in the Podman secret store. Required secrets:

| Secret | Purpose |
|---|---|
| `postgres_password` | PostgreSQL admin password |
| `litellm_master_key` | Bearer token for LiteLLM API |
| `qdrant_api_key` | Qdrant API authentication |
| `openwebui_api_key` | OpenWebUI → LiteLLM auth (must match `litellm_master_key`) |
| `flowise_password` | Flowise admin password |
| `knowledge_index_api_key` | Knowledge Index Service API key |
| `minio_root_user` | MinIO root username |
| `minio_root_password` | MinIO root password |

> **Important:** `openwebui_api_key` must be set to the same value as `litellm_master_key`. The `generate-secrets` script derives it automatically if you leave it blank.

---

## Step 8 — Validate configuration

```bash
bash scripts/configure.sh validate
```

Checks that all required fields are present, no tags are `TBD`, and the node profile is valid. Fix any errors before continuing.

---

## Step 9 — Deploy

```bash
bash scripts/deploy.sh
```

Validates config, generates systemd quadlet files into `~/.config/containers/systemd/`, and creates the Podman network.

---

## Step 10 — Start services

```bash
bash scripts/start.sh
```

Starts all services in dependency order via systemd user units. On first run this will pull container images — allow several minutes depending on network speed.

Check progress at any time:

```bash
bash scripts/status.sh
```

---

## Step 11 — Pull and register models

```bash
# Pull models into Ollama's model store
podman exec ollama ollama pull llama3.1:8b

# Register all model routes in LiteLLM
bash scripts/pull-models.sh
```

---

## Step 12 — Verify

```bash
bash scripts/status.sh -v
```

All services should show `active`. Then open a browser and navigate to `https://localhost` — you should see the Authentik login page. Create your account and start using the stack.

Run the offline preflight tests to confirm everything is wired correctly:

```bash
bats testing/layer0_preflight.bats
```

---

## Step 13 — Enroll the node in the Headscale tailnet (multi-node deployments)

If this node needs to reach the controller (or peers) across the internet, enroll it in the WireGuard overlay mesh managed by Headscale at `headscale.photondatum.space`.

**Prerequisites:** `tailscale` installed and daemon running. A pre-auth key issued by the Headscale operator.

### 1. Clear any existing Tailscale enrollment

```bash
sudo tailscale logout
# A TLS error from the old coordination server is expected — local state is still cleared.
```

### 2. Enroll

```bash
sudo tailscale up \
  --login-server https://headscale.photondatum.space \
  --authkey <preauthkey> \
  --hostname <node-alias> \
  --reset --force-reauth
```

- `--reset` clears prior non-default flags (e.g. `--exit-node-allow-lan-access`)
- `--force-reauth` is required when a prior enrollment exists; safe to omit on a fresh node
- Do **not** pass `--ssh` or `--exit-node-allow-lan-access` — Tailscale cloud-only flags; will error on a Headscale server

### 3. Confirm enrollment

```bash
tailscale status   # node should show online with a 100.64.x.x IP
```

The Headscale operator must then tag the node on the server. **Always pass all desired tags in one command** — the `tag` subcommand replaces, not appends:

```bash
# Standard enrollment — role tag + namespace tag (required for ACL to permit the node):
sudo headscale nodes tag --identifier <node-ID> \
  --tags tag:<role>,tag:net-ecotone-000-01
# Role tags: controller  inference  knowledge

# To additionally expose the node to any peer in the tailnet (e.g. a shared inference worker):
sudo headscale nodes tag --identifier <node-ID> \
  --tags tag:<role>,tag:net-ecotone-000-01,tag:net-public
```

**ACL model:** The tailnet runs namespace-isolated ACLs. Only nodes bearing `tag:net-ecotone-000-01` can communicate by default. Nodes tagged `tag:net-public` are additionally reachable from any enrolled node (all ports). A node with neither tag cannot send or receive tailnet traffic.

For per-node commands specific to this cluster, see the CENTAURI playbook §7.8.

---

## Step 14 — Enable Tailscale SSH (optional, multi-node deployments)

Once all nodes are enrolled (Step 13), enable zero-config SSH between them via the Headscale ACL policy. No public key distribution required — authentication is handled by the tailnet.

**Prerequisites:** Step 13 complete on all target nodes; ACL `ssh` block present in `/etc/headscale/acl.json` (see CENTAURI playbook §7.9 for the full block).

### 1. Enable the SSH server on each Linux target node

```bash
sudo tailscale set --ssh
```

Repeat on every node that should accept incoming `tailscale ssh` connections. macOS App Store (sandboxed) builds do not support this — use `ssh <user>@<tailnet-ip>` directly for those nodes.

### 2. Clear stale known-hosts entries (re-enrolled nodes only)

If a node was previously enrolled in Tailscale cloud before joining this Headscale tailnet, its old host key is cached and will cause:

```
No ED25519 host key is known for <node>. Host key verification failed.
```

Run as the SSH user (**not** as root — `sudo ssh-keygen` writes to `/root/.ssh` and silently fails):

```bash
ssh-keygen -R <node>        # remove by hostname
ssh-keygen -R <tailnet-ip>  # remove by 100.64.x.x IP
# Example:
ssh-keygen -R sol && ssh-keygen -R 100.64.0.2
```

### 3. Test

```bash
# Linux nodes — use tailscale ssh:
tailscale ssh sol "hostname && tailscale ip -4"
tailscale ssh 3pdx7a@headscale-host "hostname && tailscale ip -4"

# macOS App Store node (tc25) — plain ssh to tailnet IP:
ssh 3pdx7@100.64.0.3 "hostname"
```

### Headscale-host self-enrollment note

The Headscale coordination server (photondatum.space) can self-enroll as a tailnet node — it connects to its own Caddy-proxied HTTPS endpoint. Its SSH username (`3pdx7a`) differs from cluster nodes (`3pdx7`); always specify it explicitly: `tailscale ssh 3pdx7a@headscale-host`.

A SELinux health warning (`SELinux is enabled; Tailscale SSH may not work`) appears on Fedora/RHEL nodes. The `tailscale_use_ssh` boolean does not exist on Fedora 42; SSH operates under `unconfined_service_t` and works in practice. See CENTAURI playbook §7.9 for details.

---

## Step 15 — Configure the public reverse proxy (optional, internet-facing deployments)

If you need to expose AI stack services to the internet, a Caddy instance on a public host acts as the TLS-terminating reverse proxy. Traffic is forwarded to CENTAURI through the WireGuard tailnet established in Steps 13–14.

### Architecture

```
Browser (HTTPS)
  └─► <public-host>:443  (Caddy — TLS via Let's Encrypt, TLS-ALPN-01)
           │  WireGuard tunnel (Headscale tailnet)
           ▼
      CENTAURI <tailnet-ip>:443  (Traefik — self-signed *.stack.localhost cert)
           │
           ▼
      http://<service>.ai-stack:<port>  (container network)
```

### What you need

- Caddy installed on the public host (`caddy` package or via [caddyserver.com](https://caddyserver.com/download))
- Public host enrolled in the Headscale tailnet (Step 13)
- Port 443 open and publicly reachable on the public host (for TLS-ALPN-01 certificate issuance)
- DNS `A` records pointing each subdomain at the public host's IP
- Port 80 is **not** required — Caddy uses TLS-ALPN-01

### Caddyfile pattern

Reference config: `configs/reverse-proxy/caddy/Caddyfile`

Each exposed service gets its own `server_name.yourdomain.com` block. Two Caddy behaviours require explicit configuration:

1. **Host header**: when the upstream is an IP address with TLS, Caddy sets `Host` to the upstream IP, not the original request hostname. Always use `header_up Host` to set the value Traefik's router expects.
2. **DERP / HTTP Upgrade**: Headscale's embedded DERP relay uses the HTTP/1.1 `Upgrade` mechanism. Both the frontend ALPN (`tls { alpn http/1.1 }`) and the backend transport (`transport http { versions 1.1 }`) must restrict to HTTP/1.1; fixing only one is not sufficient.

```caddy
# Headscale coordination server (if co-located on this host)
# tls { alpn } and transport versions 1.1 are both required for DERP relay.
headscale.yourdomain.com {
    tls {
        alpn http/1.1
    }
    reverse_proxy localhost:8080 {
        transport http { versions 1.1 }
    }
}

# Authentik SSO — required for external auth redirects to resolve
auth.yourdomain.com {
    reverse_proxy <centauri-tailnet-ip>:443 {
        header_up Host auth.stack.localhost
        transport http { tls_insecure_skip_verify }
    }
}

# Services using an existing *.stack.localhost Traefik router (no new Traefik config needed)
flowise.yourdomain.com {
    reverse_proxy <centauri-tailnet-ip>:443 {
        header_up Host flowise.stack.localhost
        transport http { tls_insecure_skip_verify }
    }
}

# Services exposed at their external hostname with a dedicated Traefik router
# (needed when the service must bypass Authentik for external users — see below)
chat.yourdomain.com {
    reverse_proxy <centauri-tailnet-ip>:443 {
        header_up Host chat.yourdomain.com   # matches openwebui-public router in services.yaml
        transport http { tls_insecure_skip_verify }
    }
}
```

`tls_insecure_skip_verify` is required because Traefik presents a self-signed `*.stack.localhost` certificate. This is safe — the WireGuard tunnel provides transport security.

### Authentik SSO — two approaches for external access

Traefik's `forwardAuth` redirects unauthenticated users to Authentik. The redirect URL is built from the outpost's **External URL** (configured in the Authentik admin UI). This creates a constraint for external browsers:

#### Option A — Authentik SSO for external users (full SSO flow)

Works when you have a dedicated Authentik outpost whose External URL is your public domain:

1. In Authentik admin UI, create a second outpost with External URL `https://auth.yourdomain.com`.
2. Use `header_up Host <service>.stack.localhost` in Caddy to route through the existing `*.stack.localhost` Traefik router.
3. Add a Traefik middleware pointing at the new outpost and apply it to the router.

This preserves SSO for both local and external users but requires a second Authentik outpost.

#### Option B — bypass Authentik for external users (simpler, uses the service's own auth)

Works when the service has its own authentication (e.g., OpenWebUI) and you don't want to modify the existing Authentik outpost:

1. Add a dedicated Traefik router for the external hostname that intentionally omits the `authentik` middleware (see `openwebui-public` in `configs/traefik/dynamic/services.yaml`).
2. Use `header_up Host chat.yourdomain.com` in Caddy so Traefik matches that router.

Local users continue to use Authentik SSO through the existing `*.stack.localhost` router. External users authenticate directly with the service.

The AI stack ships with Option B configured for `chat.photondatum.space` / OpenWebUI.

### Firewall rules on the public host

```bash
# HTTPS for Caddy (also used by TLS-ALPN-01 cert issuance)
sudo firewall-cmd --permanent --add-service=https

# STUN — required for DERP relay NAT traversal (UDP)
sudo firewall-cmd --permanent --add-port=3478/udp

sudo firewall-cmd --reload
```

### Verify

```bash
# Certificate issued by Let's Encrypt (not self-signed)
echo | openssl s_client -connect chat.yourdomain.com:443 \
  -servername chat.yourdomain.com 2>&1 | grep issuer

# Backend reachable through the tunnel
curl -sk -o /dev/null -w "%{http_code}" https://chat.yourdomain.com/
# Expect 200 or 302 (Authentik redirect) — not a TLS error
```

---

## Quick Reference — Day-to-Day Commands

| Goal | Command |
|---|---|
| Start all services | `bash scripts/start.sh` |
| Stop all services | `bash scripts/stop.sh` |
| Check service health | `bash scripts/status.sh` |
| Run diagnostics | `bash scripts/diagnose.sh --profile full` |
| Back up all data | `bash scripts/backup.sh` |
| Run security audit | `bash scripts/configure.sh security-audit` |
| Update model routes | `bash scripts/pull-models.sh` |

---

## Next Steps

- [Operator FAQ and How-To Guides](operator-faq.md) — add models, register nodes, ingest documents, troubleshoot
- [Feature Overview](features.md) — full capability inventory
- [Architecture](ai_stack_blueprint/ai_stack_architecture.md) — system design reference

---

## Troubleshooting

### A service shows `failed` or `inactive`

```bash
systemctl --user status <svc>.service
journalctl --user -u <svc>.service --no-pager -n 30
bash scripts/diagnose.sh <svc>
# Auto-restart all failed:
bash scripts/diagnose.sh --fix
```

Cascade: if `postgres` is down, `litellm`, `authentik`, and `knowledge-index` will also fail.

---

### LiteLLM is in a crash loop

```bash
journalctl --user -u litellm.service --no-pager -n 20
```

**Common cause — stale deployed `hooks.py`:** If the repo's `configs/litellm/hooks.py` was updated (e.g. after adding a new callback) but the deployed copy at `~/ai-stack/configs/litellm/hooks.py` was not refreshed, LiteLLM will crash on startup with `AttributeError: module 'hooks' has no attribute ...`.

Fix:
```bash
cp configs/litellm/hooks.py ~/ai-stack/configs/litellm/hooks.py
systemctl --user restart litellm.service
```

---

### Homepage dashboard widgets show errors (401 / ENOTFOUND / "pagination is undefined")

Homepage service widgets require credential env vars in the `homepage.container` quadlet. These are **not** generated automatically by `configure.sh` — they must be added manually after initial deploy (and after any quadlet regeneration).

**Fix:**
```bash
nano ~/.config/containers/systemd/homepage.container
```

Add under `[Service]`:
```ini
Environment=HOMEPAGE_VAR_GRAFANA_USER=admin
Environment=HOMEPAGE_VAR_GRAFANA_PASS=<grafana_admin_password>
Environment=HOMEPAGE_VAR_QDRANT_API_KEY=<qdrant_api_key>
Environment=HOMEPAGE_VAR_AUTHENTIK_TOKEN=<akadmin_api_token>
```

Then reload:
```bash
systemctl --user daemon-reload && systemctl --user restart homepage.service
```

Grafana password: `~/ai-stack/configs/grafana/grafana.ini` (`admin_password`).
Qdrant key: `podman secret inspect qdrant_api_key --showsecret --format '{{.SecretData}}'`.
Authentik token: `AKADMIN_API_TOKEN` in `configs/credentials.local`.

**ENOTFOUND for knowledge-index or postgres widget** — the `knowledge-index` service is inactive:
```bash
systemctl --user start knowledge-index.service
```

---

### Service unreachable in browser (502 / connection refused)

All services are served via Traefik at `https://*.stack.localhost`. If a URL returns 502 or times out:

```bash
# Check Traefik is running
systemctl --user is-active traefik.service

# Check the target service
systemctl --user is-active <svc>.service

# Verify TLS certs are present
ls ~/ai-stack/configs/traefik/certs/
# If missing: bash scripts/generate-tls.sh && systemctl --user restart traefik.service
```

---

### LiteLLM `/metrics` returns 404

The Prometheus metrics endpoint is only active when the `prometheus` callback is registered. Check `configs/litellm/proxy_config.yaml`:

```yaml
litellm_settings:
  callbacks:
    - prometheus
```

Restart LiteLLM after adding it: `systemctl --user restart litellm.service`.

---

### Qdrant / Grafana return 401 in Homepage widgets

See [Homepage dashboard widgets](#homepage-dashboard-widgets-show-errors-401--enotfound--pagination-is-undefined) above. The credential env vars in the quadlet are not set.

---

### First-time TLS errors in browser

```bash
bash scripts/generate-tls.sh
systemctl --user restart traefik.service
```

Then import the generated CA cert into your browser's trusted certificate store.

---

### SSO login loop — service redirects to login but never completes

When navigating to a service (e.g. `https://litellm.stack.localhost`) and the Authentik login page appears but clicking "Log In" loops back or shows a certificate error, the most common cause is a **missing TLS certificate SAN entry** for that hostname.

**Diagnose:**
```bash
bash scripts/diagnose.sh --profile full
# Look for lines: [FAIL] <hostname>   NOT in cert SAN list — SSO will break
```

Or check directly:
```bash
echo | openssl s_client -connect litellm.stack.localhost:443 \
  -servername litellm.stack.localhost 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

**Fix — add the missing hostname and regenerate:**

1. Open `scripts/generate-tls.sh` and add the missing service name to both SAN loops (the `if [[ "$DOMAIN" != "localhost" ]]` block and the `for svc in ...` block below it).

2. Regenerate and re-trust the CA:
```bash
DOMAIN=stack.localhost bash scripts/generate-tls.sh --force
sudo cp ~/ai-stack/configs/tls/ca.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
systemctl --user restart traefik.service
```

3. Clear your browser's certificate cache (or open a new private/incognito window) and retry.

> **Note:** The CA is regenerated along with the server cert. Any browser or OS that previously trusted the old CA will need the new `ca.crt` re-imported.

---

### Loki / Promtail entries on the dashboard have no direct UI

This is expected. Loki is an API-only log store; Promtail is a log shipping agent with no web interface. Neither should have a clickable link on the Homepage dashboard. To query logs from Loki, use **Grafana → Explore** (`https://grafana.stack.localhost/explore`).

