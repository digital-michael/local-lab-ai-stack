# BL-015 Spec — Tailnet-Accessible KI Endpoint + CNC Foundation

**Status:** Approved — implementation pending  
**Decision:** D-009  
**Unblocks:** BL-011 steps 3+4 (controller_url LAN→tailnet migration)  
**Priority:** P1

---

## Problem

`knowledge-index` binds to `127.0.0.1:8100`. Worker nodes on SOL and TC25 cannot reach it over the tailnet. `controller_url` in `node-config.json` still points to the LAN hostname `SERVICES.mynetworksettings.com`. This is the last LAN dependency for worker→controller traffic.

---

## Solution Overview

Add a `tailnet` Traefik entrypoint bound to the controller's tailnet IP (`100.64.0.4:8443`). Route `/v1/*`, `/mcp/*`, and `/v1/cnc/*` through it with bearer token auth. Add `/v1/config` (public bootstrap endpoint) and `/v1/cnc/*` handlers to knowledge-index. Migrate `controller_url` on all workers to `https://100.64.0.4:8443`.

---

## Implementation Steps

### Step 1 — Traefik: add `tailnet` entrypoint

**File:** `configs/traefik/traefik.yaml`

Add under `entryPoints`:
```yaml
tailnet:
  address: "100.64.0.4:8443"
  http:
    tls: {}
```

**File:** Traefik quadlet (wherever `PublishPort` is configured)

Add: `PublishPort=100.64.0.4:8443:8443`

**TLS toggle:** `configure.sh` reads `config.json → tailnet_tls`. If `false`, render `address: "100.64.0.4:8443"` without the `http.tls` block. Default: `true`.

---

### Step 2 — Traefik: add tailnet routers

**File:** `configs/traefik/dynamic/services.yaml`

Add three new routers (all use `tailnet` entryPoint):

```yaml
# Tailnet: /v1/* — worker queries + ingest — bearer token validated in KI
knowledge-index-tailnet-api:
  rule: "Host(`100.64.0.4`) && PathPrefix(`/v1`)"
  entryPoints:
    - tailnet
  service: knowledge-index
  middlewares:
    - secure-headers
  tls: {}

# Tailnet: /mcp/* — MCP tool server access for future agentic workers
knowledge-index-tailnet-mcp:
  rule: "Host(`100.64.0.4`) && PathPrefix(`/mcp`)"
  entryPoints:
    - tailnet
  service: knowledge-index
  middlewares:
    - secure-headers
  tls: {}

# Tailnet: /v1/cnc/* — CNC namespace (register, heartbeat, future commands)
# Note: covered by knowledge-index-tailnet-api PathPrefix(/v1) above.
# Separate router only needed if CNC gets distinct middleware in future.
```

Note: `/v1/cnc/*` is within `/v1/*` — no separate router needed unless CNC auth diverges from `/v1/*` (it won't in this BL). Document this overlap explicitly.

**Also add** `Host('100.64.0.4')` to `knowledge-index-admin` rule's negation (it should never match on tailnet entrypoint — the entryPoint binding handles this, but belt-and-suspenders is fine):

No change needed — `/admin` routes only have `entryPoints: [websecure]`. They cannot be reached on the `tailnet` entrypoint regardless of Host rule.

---

### Step 3 — config.json: add network_domains + tailnet config

```json
"tailnet": {
  "controller_ip": "100.64.0.4",
  "port": 8443,
  "tls": true,
  "controller_url": "https://100.64.0.4:8443"
},
"network_domains": {
  "ecotone-000-01": {
    "tag": "tag:net-ecotone-000-01",
    "bearer_token": "<generate: openssl rand -hex 32>"
  }
}
```

Token generated once at deploy time, stored in `config.json` (gitignored credential fields should move to `credentials.local` — follow existing pattern).

---

### Step 4 — knowledge-index app.py: bearer token middleware

Add FastAPI dependency `verify_bearer_token(request)`:
- Reads `Authorization: Bearer <token>` header
- Validates against `network_domains[domain].bearer_token` (loaded from env or config at startup)
- Returns `HTTP 401` if missing/invalid
- Apply to all `/v1/*` and `/mcp/*` routes (not `/v1/config` — that's the public bootstrap endpoint)

---

### Step 5 — knowledge-index app.py: `/v1/config` endpoint

```
GET /v1/config
Auth: none (public within tailnet — no bearer token required)
Response:
{
  "controller_url": "https://100.64.0.4:8443",
  "schema_version": "1.2",
  "domain": "ecotone-000-01",
  "capabilities": ["inference", "knowledge", "routing"]
}
```

Values sourced from `config.json` / env at startup. Workers call this at boot and on `node.sh configure --refresh-config`.

---

### Step 6 — knowledge-index app.py: `/v1/cnc/*` handlers

Replace the LAN `/admin/v1/nodes/*` path for worker-initiated operations:

```
POST /v1/cnc/register    — body: node-config.json payload; stores in nodes DB; returns node_id
POST /v1/cnc/heartbeat   — body: { node_id, alias, status }; updates last_seen; returns 204
```

Auth: same `verify_bearer_token` dependency as `/v1/*`.

Existing `/admin/v1/nodes` and `/admin/v1/nodes/{id}/heartbeat` are **not removed** — they remain for operator/localhost use. New `/v1/cnc/*` endpoints are additive.

---

### Step 7 — node.sh configure: write controller_url from config discovery

`node.sh configure` adds a step after writing `node-config.json`:
1. If `--controller-url <url>` flag provided, use it directly.
2. Otherwise, if `CONTROLLER_URL` set in `config.json`, use it.
3. Otherwise, attempt `GET https://100.64.0.4:8443/v1/config` (hardcoded bootstrap IP) and extract `controller_url`.
4. Write `controller_url` into `node-config.json`.

`node.sh configure --refresh-config` re-runs step 3 only and updates `controller_url` if it changed.

---

### Step 8 — heartbeat.sh: migrate to /v1/cnc/heartbeat

Update `heartbeat.sh` POST target from `$CONTROLLER_URL/admin/v1/nodes/$NODE_ID/heartbeat` to `$CONTROLLER_URL/v1/cnc/heartbeat`. Add `Authorization: Bearer $BEARER_TOKEN` header (token read from `node-config.json → network.bearer_token`).

---

### Step 9 — LAN cleanup

After all workers verified on tailnet:
1. Remove `Host('SERVICES.mynetworksettings.com')` from `knowledge-index-admin` router rule in `services.yaml`.
2. Update `docs/wip/plan.md` BL-011 steps 3+4 to complete.
3. Note in CENTAURI-playbook.md that LAN hostname is no longer a routing target.

---

## Verification Gate

```bash
# From controller — confirm tailnet entrypoint is up
curl -sk https://100.64.0.4:8443/v1/config | python3 -m json.tool

# From SOL over tailnet — confirm bearer token auth works
curl -sk -H "Authorization: Bearer <token>" https://100.64.0.4:8443/v1/health

# From SOL — confirm /admin is not reachable on tailnet port
curl -sk https://100.64.0.4:8443/admin/v1/nodes  # expect: connection refused or 404, not 200

# From controller — confirm CNC heartbeat works from worker
# (run on SOL after step 8)
tailscale ssh sol "bash scripts/heartbeat.sh --once"  # expect: 204 response

# node.sh list --refresh shows workers with controller_url updated
bash scripts/node.sh list --refresh
```

---

## Non-Goals (this BL)

- Authentik forward-auth on tailnet (deferred to operator CNC BL)
- MCP client on inference workers (deferred — agentic executor BL)
- stdio MCP transport (deferred)
- Headplane deployment (BL-016, independent)
- node-exporter-ai (BL-013, unblocked after this BL)
