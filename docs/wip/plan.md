# Work-in-Progress — Implementation Plan

**Tracking:** Backlog lives in `docs/meta_local/review_log.md` (Pending Tasks table).
**Sequence:** Items are worked in backlog listing order unless priority escalation is noted.
**Architecture decisions governing this plan:** D-004 through D-008 (`docs/meta_local/decisions.md`)
**Last Updated:** 2026-05-04

---

## Active

_Nothing in flight._

---

## Next (selected)

### BL-011 — Headscale Architecture Migration: Phase 1 (ACL hardening + LAN break-glass)
**Priority:** P1  
**Status:** ✅ done — all 4 steps complete 2026-05-05  
**Decisions:** D-004, D-007, D-008  

**Steps:**

1. ✅ **Tighten ACL to directional controller→worker** — deployed 2026-05-04.  
   `ssh` block changed from full-mesh (`tag:net-ecotone-000-01` → self) to directional  
   (`tag:controller` → `tag:inference`, `tag:knowledge`). Headscale restarted. Verified:  
   `tailscale ssh sol` from CENTAURI exits 0. Node 1 (stale ghost enrollment) deleted;  
   node 5 retags to `tag:controller,tag:knowledge,tag:net-ecotone-000-01`.

2. ✅ **Document LAN SSH break-glass** — added §7.11 to `output/CENTAURI-playbook.md`.  
   Table: all node LAN IPs, SSH users, key paths. ToC entry added.

3. ✅ **LAN→tailnet IP migration — controller_url** — complete 2026-05-05.  
   Both SOL and TC25: `~/.config/ai-stack/controller_url=https://100.64.0.4:8443`,  
   `~/.config/ai-stack/network_bearer_token=<64 chars>`. Heartbeats route via  
   Traefik tailnet entrypoint → `/v1/cnc/heartbeat` with Bearer auth.

4. ✅ **LAN→tailnet IP migration — workers** — complete 2026-05-05.  
   SOL: CNC heartbeats confirmed 2026-05-05 ~13:00. TC25: git pulled to `5a13f15`,  
   CNC heartbeats confirmed 2026-05-05 ~17:50; status `online`.

**Verification gate:** ✅ `node.sh list` shows SOL `online`, TC25 `online`; both posting to `/v1/cnc/heartbeat 204`.

---

### BL-012 — Distributed Node Config: node.sh configure + --refresh
**Priority:** P1 — unblocks node-exporter-ai and deprecation of static node files  
**Status:** code complete `2b51980`; verification gate pending (workers offline at commit time)  
**Decisions:** D-005  

**Steps:**
1. ✅ Define `node-config.json` schema (schema_version 1.2): `node_id`, `alias`, `profile`, `os`, `deployment`, `capabilities`, `models`, `version`, `updated_at`.
2. ✅ Implement `node.sh configure` — writes `~/.config/ai-stack/node-config.json`. Profile resolved from state file → static `configs/nodes/` lookup → default. Models from Ollama API. Tested on CENTAURI.
3. ✅ Implement `node.sh list --refresh` — for each online headscale node, SSH-pulls `node-config.json`; self-node uses local copy. Cache written to `~/.config/ai-stack/nodes/<name>.json` with `.refreshed_at` staleness marker.
4. ✅ `node.sh list` reads from cache dir first (priority over static files); staleness warning printed at >10 min.
5. ✅ **Verification gate complete (2026-05-05):**
   - SOL: `configure` ✓ → `inference-worker`, `linux`, `bare_metal`, models=[] (Ollama not running at time of test)
   - TC25: `configure` ✓ → `inference-worker`, `darwin`, `bare_metal`, `llama3.1:8b-instruct-q4_K_M`
   - `list --refresh` on controller: SOL pulled via `tailscale ssh` ✓; TC25 fell through to static file (headscale givenName is `macbook-m1`, not `tc25` — refresh tried correct name but node-config.json path differs on macOS `/Users/michaelbiggerstaff`). centauri-node local-copy ✓. All profiles and capabilities displayed correctly.
   - Known gap: TC25 `tailscale ssh macbook-m1` host key rejected by headscale coordination server; needs `tailscale ssh` key trust or SSH config entry with password. Logged in lessons-learned.

---

### BL-013 — node-exporter-ai: per-node metrics exporter
**Priority:** P2 — prerequisite for Prometheus distributed scrape  
**Status:** not started  
**Decisions:** D-006  
**Blocked by:** BL-012 (needs node-config.json for label injection)

**Steps:**
1. Implement `services/node-exporter-ai/` — Python, binds to tailnet IP `:9200`, exposes `/metrics` in Prometheus text format. Metrics: CPU %, mem used/total, GPU VRAM (nvidia-smi), Ollama model count, node profile label.
2. Add systemd user service unit to `configs/quadlets/` (Linux) and launchd plist template for macOS fallback.
3. Update `node.sh list --refresh` to append scrape targets to `configs/prometheus/prometheus.yml`.
4. Deploy on SOL first, verify Prometheus scrapes `100.64.0.2:9200`. Then roll to remaining nodes.
5. TC25: if `:9200` bind fails (App Store sandbox), configure Pushgateway path. Document exception.

**Verification gate:** Grafana shows per-node CPU/mem/VRAM panels populated from Prometheus.

---

### BL-014 — node.sh remote: SSH command delivery wrapper
**Priority:** P2  
**Status:** ✅ done — implemented 2026-05-06  
**Decisions:** D-007  
**Blocked by:** BL-011 (ACL must be directional before this is used in anger)

**Steps:**
1. ✅ Implement `node.sh remote <node> <cmd>` — resolves node alias/node_id to tailnet IP via `tailscale status --json`; invokes `ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null <user>@<tailnet-ip> <cmd>`. (Note: `tailscale ssh` rejected by headscale — host key not served; direct SSH is the correct transport.)
2. ✅ Fallback: if SSH exits 255 (connection-level failure), retry via LAN IP (`address_fallback` from node file).
3. ⏸ Migrate `node.sh suggestions` to use remote SSH — deferred; requires workers to cache suggestions locally first (heartbeat.sh does not yet write a local queue file).
4. ✅ `node.sh remote <node> bash scripts/status.sh` is the standard worker health check pattern.

**Verification gate:** ✅ `node.sh remote sol echo BL-014` returns `BL-014`, exit 0 from CENTAURI. SSH transport confirmed via tailnet IP 100.64.0.2 → SOL hostname. (Note: SOL's repo is at `~/Projects/active/local-lab-ai-stack/`, not `~/ai-stack/scripts/`.)

---

### BL-015 — Tailnet-Accessible KI Endpoint + CNC Foundation
**Priority:** P1 — unblocks BL-011 steps 3+4 (LAN→tailnet IP migration)  
**Status:** ✅ done — all 8 steps implemented; verification gate passed 2026-05-05  
**Decisions:** D-009

**Problem:** `knowledge-index` binds `127.0.0.1:8100`. Workers can't reach it over the tailnet. `controller_url` still points to LAN hostname. This is the last LAN dependency for worker→controller traffic.

**Steps:**
1. Traefik: add `tailnet` entrypoint at `100.64.0.4:8443`; `PublishPort` in quadlet; TLS on by default (`config.json → tailnet_tls` toggle)
2. Traefik: add `knowledge-index-tailnet-api` and `knowledge-index-tailnet-mcp` routers in `services.yaml`
3. `config.json`: add `tailnet.*` block + `network_domains.ecotone-000-01.bearer_token` (generate token)
4. KI `app.py`: add `verify_bearer_token` FastAPI dependency; apply to `/v1/*` + `/mcp/*` (not `/v1/config`)
5. KI `app.py`: add `GET /v1/config` public bootstrap endpoint (returns `controller_url`, domain, schema, capabilities)
6. KI `app.py`: add `POST /v1/cnc/register` + `POST /v1/cnc/heartbeat` (additive — `/admin/*` unchanged)
7. `node.sh configure`: add `controller_url` resolution (flag → config.json → `/v1/config` discovery); write to `node-config.json`
8. `heartbeat.sh`: migrate POST to `/v1/cnc/heartbeat` with `Authorization: Bearer` header
9. LAN cleanup: remove `SERVICES.mynetworksettings.com` from `services.yaml` after workers verified on tailnet

**Verification gate:** see `docs/wip/bl-015-spec.md` § Verification Gate

**Non-goals:** Authentik on tailnet, MCP client on workers (agentic executor BL), node-exporter-ai (BL-013)

---

### BL-016 — Headplane deployment on photondatum.space
**Priority:** P2  
**Status:** ✅ done — deployed 2026-05-06  
**WIP reference:** `docs/wip/headplane-remote-deploy.md`  
**Decisions:** D-007 (Headplane role: network UI only)

Headplane v0.6.2 deployed on photondatum.space as a Podman quadlet. Bound to tailnet IP `100.64.0.5:3000` only. `tailscale0` assigned to firewalld `trusted` zone; port 3000 blocked on `public` zone.

**Verification gate:** ✅ `curl http://100.64.0.5:3000/admin` → 302 from CENTAURI; `curl http://photondatum.space:3000/admin` → connection refused.

---

## Queue (core-functionality order — metrics track deferred)

**Model guidance:** Each item is annotated with recommended agent model.
`Auto` = narrow, fully-specified, zero design decisions — agent MUST NOT execute work outside the item's defined scope.
`Sonnet` = standard implementation with moderate judgment. `Opus` = architecture / L3-L4 design.

### Core track (execute in order)

| # | ID | Priority | Title | Status | Model | Decisions |
|---|---|---|---|---|---|---|
| 1 | BL-009 Ph.2 | P1 | Content Review Layer Phase 2 (guard LLM) | ✅ done — guard LLM (Category D) implemented 2026-05-05 | Sonnet | D-039 |
| 2 | BL-015 step 9 | P1 | LAN cleanup — remove SERVICES hostname from services.yaml | ✅ done 2026-05-05 | **Auto** | D-009 |
| 3 | BL-014 | P2 | node.sh remote: SSH command delivery wrapper | ✅ done 2026-05-06 | Sonnet | D-007 |
| 4 | BL-016 | P2 | Headplane deployment on photondatum.space | ✅ done 2026-05-06 | Sonnet | D-007 |
| 5 | BL-008 | P2 | Default credential policy | not started | Sonnet | — |
| 6 | m2m track | P2 | m2m-gateway + localhost MVP | on hold — now unblocked | Sonnet | — |
| 7 | BL-004 | P2 | RLM integration research | not started | Sonnet | — |
| 8 | BL-007 | P2 | Configurable domain in setup | not started | Sonnet | — |

### Deferred — metrics/observability track

_Deferred 2026-05-05: self-contained, no blocking dependencies on core track. Drop in at any time._

| ID | Priority | Title | Status | Model | Decisions |
|---|---|---|---|---|---|
| BL-013 | P2 | node-exporter-ai: per-node Prometheus metrics exporter | not started | Sonnet | D-006 |
| BL-005 | P2 | Internal operator dashboard | not started | Sonnet | — |
| BL-006 | P2 | Live throughput + profiling dashboard | not started | Sonnet | — |

### Completed

| ID | Priority | Title | Status | Decisions |
|---|---|---|---|---|
| BL-001 | P2 | CENTAURI-playbook.md | ✅ done 2026-05-04 | — |
| BL-002 | P3 | node.sh list: headscale backend + stanza output | ✅ done 2026-05-04 | — |
| BL-003 | P3 | --json output mode for scripts | ✅ done 2026-05-04 | — |
| BL-015 | P1 | Tailnet-Accessible KI Endpoint + CNC Foundation | ✅ done 2026-05-05 | D-009 |
| BL-011 | P1 | Headscale migration: ACL hardening + LAN break-glass + IP migration | ✅ done 2026-05-05 | D-004, D-007, D-008 |
| BL-012 | P1 | Distributed node config: node.sh configure + --refresh | ✅ done `7813139` 2026-05-05 | D-005 |
| BL-010 | P3 | Evaluate peer/node registration architecture | deferred | — |

---

## WIP Document Status

| File | Status | Action |
|---|---|---|
| `docs/wip/headscale-proposal.md` | KEEP — rationale reference | Archive after D-004–D-008 are committed; no further edits needed |
| `docs/wip/headscale-install-fedora.md` | KEEP — operational runbook | Keep as reference for re-enrollment and DERP tuning |
| `docs/wip/headplane-remote-deploy.md` | KEEP — execute as BL-016 | No changes needed; execute as-is |
| `docs/wip/m2m-localhost-mvp.md` | PARTIAL — parallel track | Hold until BL-011/BL-012 stable; m2m depends on networking layer |
| `docs/wip/m2m-localhost-mvp-checklist.md` | PARTIAL — parallel track | Hold same as above |
| `docs/wip/m2m-ki-interoperability-lite.md` | PARTIAL — parallel track | Hold; orthogonal to networking migration |

---

## TODO

- **Evaluate photondatum.space service containerization:** Now that Podman is installed on photondatum.space, audit all services running there (Headscale, Caddy, any future additions) and assess whether they should be managed as Podman quadlets for lifecycle consistency with the CENTAURI deployment model. Consider: image-pinned versions, restart policies, log routing, and whether Caddy should be replaced or wrapped.

---

## Notes

- **BL-009 Phase 2** (guard LLM) is next — networking layer is now stable (BL-011/BL-012/BL-015 all done).
- **BL-015 step 9** (LAN hostname cleanup): ✅ completed 2026-05-05. Removed `SERVICES.mynetworksettings.com` from `configs/traefik/dynamic/services.yaml` admin router rule; tailnet CNC path is authoritative.
- **Metrics track deferred** (BL-013/005/006): no capability dependencies; re-insert into queue when observability becomes a priority.
- **configs/nodes/*.json** worker files deprecated by D-005; do not delete until `node.sh list --refresh` is verified working on all nodes (TC25 headscale SSH gap still open per BL-012 notes).
- **Auto model constraint:** Any item marked `Auto` must be scoped strictly to the defined work. Agent must not infer or expand scope, modify adjacent files, or act on assumptions outside the item spec.
