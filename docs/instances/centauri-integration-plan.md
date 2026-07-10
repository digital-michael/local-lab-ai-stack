# CENTAURI — Integration Plan (photondatum.space IAM)
**Status:** In Progress
**Last Updated:** 2026-07-10

This document tracks the work needed to fully integrate CENTAURI with the photondatum.space IAM deployment and to resolve post-migration cleanup items. It also records planned roles for SOL and TC25 for future reference.

---

## Immediate — CENTAURI Cleanup

These items are blocking or degrading service now.

### 1. Stop Stale Authentik Service (BLOCKING — causes forwardAuth 500s)

**Why:** The old Authentik container left running on CENTAURI after migration to VPS is causing Traefik forwardAuth timeouts. The embedded outpost loops on `auth.stack.localhost/ws/client/` reconnects, producing 14-second hangs and 500 errors on `agent.photondatum.space`.

**Action (run as `3pdx7` on CENTAURI):**
```bash
systemctl --user stop authentik
systemctl --user disable authentik
```

**Verify:**
```bash
# Should return 302 (Authentik redirect), not 500
curl -sk -o /dev/null -w "%{http_code}" \
  -H "Host: agent.photondatum.space" https://100.64.0.4:443
```

**See:** [Authentik lessons learned §12](../library/framework_components/authentik/lessons_learned.md#12-stale-authentik-on-controller-node-causes-forwardauth-interference)

---

### 2. Fix Forgejo ROOT_URL (causes http:// redirect_uri in OIDC)

**Why:** Forgejo builds OAuth2 `redirect_uri` from its `ROOT_URL`. Without it set to `https://`, it sends `http://` URIs. Currently worked around by registering both schemes in Authentik, but the permanent fix is cleaner and eliminates the http→https redirect hop in the OIDC flow.

**Action (requires sudo on photondatum.space as `3pdx7a`):**
```bash
sudo -e /etc/forgejo/app.ini
# Add under [server]:
#   ROOT_URL = https://git.photondatum.space
sudo systemctl restart forgejo
```

**After fix:** Remove the `http://` redirect URI from the Authentik `Forgejo OIDC` provider (Authentik admin → Providers → Forgejo OIDC → Edit → Redirect URIs). Keep only:
```
https://git.photondatum.space/user/oauth2/Authentik/callback
```

**See:** [Forgejo lessons learned §2](../library/framework_components/forgejo/lessons_learned.md#2-root_url-must-be-set-to-https-or-oidc-redirect_uri-uses-http)

---

## Short-term — CENTAURI Integration Validation

Once the immediate items are resolved, verify end-to-end integration.

### 3. Verify agent.photondatum.space Works for digital-michael

1. Navigate to `https://agent.photondatum.space` in a fresh browser session
2. Should redirect to `https://auth.photondatum.space` (Authentik login)
3. Sign in with GitHub → lands in OpenWebUI as `digital-michael`
4. Confirm bundle-admin permissions are in effect (all models accessible)

### 4. Verify flowise.photondatum.space Works

1. Navigate to `https://flowise.photondatum.space`
2. Should redirect to Authentik login
3. Sign in as `digital-michael` (bundle-admin) → lands in Flowise
4. Other users (bundle-agent) should receive a policy deny page

### 5. Verify dashboard.photondatum.space Works

1. Navigate to `https://dashboard.photondatum.space`
2. Sign in as `digital-michael` → Homepage dashboard loads
3. Confirm widgets (Grafana, Qdrant, Authentik) show data, not 401s

---

## Medium-term — CENTAURI Configuration Hardening

### 6. Remove Authentik Quadlet From CENTAURI Config

The `authentik.service` quadlet file still exists on CENTAURI at
`~/.config/containers/systemd/authentik.container`. After confirming the service
is stopped and disabled, remove it to prevent accidental restarts:

```bash
rm ~/.config/containers/systemd/authentik.container
systemctl --user daemon-reload
```

Also remove from `configs/config.json` the `authentik` entry under CENTAURI's
effective config (or mark `_suspended` like vllm) to prevent `configure.sh`
from regenerating the quadlet on the next deploy.

### 7. Update `node_profile` in CENTAURI config.json

The CENTAURI `node_profile` should be verified as `controller` (not `edge`).
The `edge` profile generates only IAM group quadlets and should not be used on
CENTAURI.

```bash
jq '.node_profile' configs/config.json
# Expected: "controller"
```

### 8. Verify Tailscale SSH ACL Covers New Nodes

With `digital-michael` now a Forgejo user and potentially connecting from new
devices, verify the Headscale ACL in `/etc/headscale/acl.json` on photondatum.space
covers any new node enrollments. SOL and TC25 will need their tags updated when
they re-enroll (see Node Plans below).

---

## Node Plans — SOL and TC25

These nodes are not active in the current deployment. Record their planned roles
here so that when they are brought back online, the deployment path is clear.

### SOL (`100.64.0.2`) — Enhanced Worker / Knowledge Worker

| Property | Planned Value |
|---|---|
| Role | `enhanced-worker` or `knowledge-worker` |
| Tailnet IP | `100.64.0.2` (last seen 10 days ago) |
| Node alias | `sol` |
| Platform | Linux |
| Headscale tags | `tag:inference`, `tag:net-ecotone-000-01` |

**Planned groups:**
- `ai-stack-infer` — Ollama (GPU or CPU inference offload from CENTAURI)
- `ai-stack-know` — Knowledge Index + Qdrant (offload knowledge pipeline)
- `ai-stack-obs` — Promtail only (ships logs to CENTAURI Loki)

**Integration with photondatum.space IAM:**
- Tailnet enrollment via `https://headscale.photondatum.space`
- No Authentik on SOL — all auth delegated to photondatum.space edge node
- Traefik forwardAuth (if SOL runs Traefik) points to `https://auth.photondatum.space`

**Activation checklist (when ready):**
- [ ] Re-enroll in Headscale: `sudo tailscale up --login-server https://headscale.photondatum.space --authkey <key> --hostname sol`
- [ ] Tag node: `sudo headscale nodes tag --identifier <id> --tags tag:inference,tag:net-ecotone-000-01`
- [ ] Deploy with `node_profile=enhanced-worker` or `knowledge-worker`
- [ ] Update CENTAURI Prometheus to scrape SOL metrics endpoint

---

### TC25 (`100.64.0.3`) — macOS Workstation / Client Node

| Property | Planned Value |
|---|---|
| Role | Client / occasional inference |
| Tailnet IP | `100.64.0.3` (last seen 4 days ago) |
| Node alias | `tc25` |
| Platform | macOS |
| Headscale tags | `tag:net-ecotone-000-01` |

**Notes:**
- macOS App Store Tailscale does not support `tailscale ssh` — use plain SSH to tailnet IP
- No Podman containers expected (macOS overhead); may run Ollama natively for local inference
- Primary role: client access to CENTAURI services via tailnet and photondatum.space proxy
- Authentik login works via browser (same `digital-michael` GitHub account)

**Activation checklist (when ready):**
- [ ] Re-enroll in Headscale (use `--force-reauth` if previously enrolled)
- [ ] Tag node: `sudo headscale nodes tag --identifier <id> --tags tag:net-ecotone-000-01`
- [ ] Verify `https://agent.photondatum.space` accessible from browser on TC25
- [ ] Optionally install Ollama natively for local model inference
- [ ] Update stale known-hosts entry if host key changed since last enrollment

---

## Completed

| Item | Date | Notes |
|---|---|---|
| Authentik migrated from CENTAURI to photondatum.space VPS | 2026-07 | All IAM now on edge node |
| Traefik forwardAuth middleware updated to auth.photondatum.space | 2026-07 | `configs/traefik/dynamic/middlewares.yaml` |
| All CENTAURI image versions pinned in config.json | 2026-07-09 | Was `latest` for several services |
| vllm suspended (GPU contention with Ollama) | 2026-07-09 | `_suspended` annotation in config.json |
| Flowise exposed via flowise.photondatum.space | 2026-07-10 | Caddy + Authentik bundle-admin policy |
| RustDesk version pinned to 1.1.15 | 2026-07-10 | Was `latest` in docker-compose.yml |
| Forgejo OIDC wired (Authentik side + Forgejo side) | 2026-07-10 | `digital-michael` linked via GitHub |
| akadmin email separated from personal account | 2026-07-10 | akadmin@photondatum.space |
