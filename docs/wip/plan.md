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
| 5 | BL-008 | P2 | Default credential policy | ✅ done 2026-05-06 | Sonnet | — |
| 6 | m2m track | P2 | m2m-gateway + localhost MVP | on hold — now unblocked | Sonnet | — |
| 7 | BL-004 | P2 | RLM integration research | not started | Sonnet | — |
| 8 | BL-007 | P2 | Configurable domain in setup | not started | Sonnet | — |
| 9 | BL-017 | P3 | Bats test suite rewrite — container-network pattern | not started | Sonnet | — |

### Deferred — metrics/observability track

_Deferred 2026-05-05: self-contained, no blocking dependencies on core track. Drop in at any time._

| ID | Priority | Title | Status | Model | Decisions |
|---|---|---|---|---|---|
| BL-013 | P2 | node-exporter-ai: per-node Prometheus metrics exporter | not started | Sonnet | D-006 |

### Deferred — operational improvements

| ID | Priority | Title | Status | Notes |
|---|---|---|---|---|
| BL-SSO | P3 | LiteLLM UI SSO via Authentik (https://litellm.stack.localhost/ui) | blocked — 2026-05-06 | OAuth2 provider + scope mappings (openid/email/profile) created and wired. Token exchange reaches Authentik (HTTP 200) but userinfo response triggers JSONDecodeError in fastapi_sso. Scope mismatch warning in Authentik logs (`token_has: set()`) persists even after SQL-inserting scope mappings — Authentik likely has a cached representation. Resume by: (1) restarting Authentik to bust cache, or (2) deleting the provider and re-creating via the Authentik UI with scope mappings selected in the form, which guarantees the ORM wires them correctly. |
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

---

### BL-017 — Bats Test Suite Rewrite: Container-Network Pattern
**Priority:** P3  
**Status:** not started  
**Decisions:** —  
**Context:** Port removal security hardening (`"ports": []` on all non-essential services) rendered ~25 bats tests permanently broken. Tests were written against direct `localhost:PORT` curl calls. The correct pattern — already proven in `layer2_authentik.bats` and `layer2_promtail.bats` — is `podman exec $EXEC_CONTAINER curl http://service.ai-stack:PORT/...` via an in-network container.

**Broken test map (2026-05-06 audit):**
- **layer1_smoke.bats** — T-012 through T-018, T-021a (8 tests): direct `localhost:PORT` curls to portless services (prometheus, grafana, loki, qdrant, litellm, openwebui, flowise, minio)
- **layer2_traefik.bats** — T-022, T-023 (2 tests): curl to port 80/443; need Traefik service to be active; investigate Traefik inactive state separately
- **layer2_flowise.bats** — T-048, T-049 (2 tests): direct `localhost:FLOWISE_PORT`
- **layer2_grafana.bats** — setup_file + all tests: direct `localhost:GRAFANA_PORT`
- **layer2_litellm.bats** — T-031, T-032 (2 tests): direct `localhost:LITELLM_PORT`
- **layer2_loki.bats** — T-043, T-044, T-045, T-047 (4 tests): direct `localhost:LOKI_PORT`
- **layer2_prometheus.bats** — T-040, T-041, T-042 (3 tests): direct `localhost:PROMETHEUS_PORT`
- **layer2_qdrant.bats** — T-028, T-029, T-030 (3 tests): direct `localhost:QDRANT_PORT`
- **layer2b_lifecycle.bats** — T-050, T-052, T-054 (3 tests): `wait_for_http` polls `localhost:PORT` for portless services

**Steps:**
1. Establish shared `net_curl()` helper in `testing/helpers.bash` (reusable `podman exec $EXEC_CONTAINER curl ...` wrapper; find exec container via priority list).
2. Rewrite layer1_smoke.bats tests for portless services to use `net_curl` against `service.ai-stack:container_port`.
3. Rewrite layer2_flowise, layer2_grafana, layer2_litellm, layer2_loki, layer2_prometheus, layer2_qdrant — replace all direct `localhost:PORT` curl calls with `net_curl`.
4. Rewrite layer2b_lifecycle `wait_for_http` calls for portless services — use internal DNS equivalent.
5. Investigate + fix Traefik inactive state separately (T-021, T-022, T-023, T-024 depend on Traefik running; separate from port pattern).
6. Run full `make test` — target: 0 port-pattern failures.

**Non-goals:** T-077 (Authentik forwardAuth — separate config gap, tracked in layer2_traefik). Traefik root cause investigation is a separate operational item.

**Verification gate:** `make test` shows no `curl failed (exit 7)` failures except tests explicitly marked skip.

---

## TODO

- **CENTAURI-playbook.md alignment review:** Review `output/CENTAURI-playbook.md` end-to-end and update all sections to be fully aligned with the current implementation. Verify: tailnet entrypoint config (§ Traefik), CNC bearer token provisioning (§7.12), node.sh remote pattern (§7.13), Headplane deployment (§7.14), Podman secret strength audit (Check F), any procedure that references LAN hostnames or deprecated workflows. Remove or annotate anything superseded by BL-011 through BL-008. File is gitignored — no commit required; update in place on CENTAURI.

- **Evaluate photondatum.space service containerization:** Now that Podman is installed on photondatum.space, audit all services running there (Headscale, Caddy, any future additions) and assess whether they should be managed as Podman quadlets for lifecycle consistency with the CENTAURI deployment model. Consider: image-pinned versions, restart policies, log routing, and whether Caddy should be replaced or wrapped.

- **Wire HOMEPAGE_VAR_* env vars into configure.sh:** The Grafana, Qdrant, and Authentik credentials needed by Homepage service widgets must currently be added manually to `~/.config/containers/systemd/homepage.container`. Running `configure.sh` (or any step that regenerates quadlets) will wipe them. Either: (a) add explicit `HOMEPAGE_VAR_*` generation to `configure.sh generate-quadlets` reading values from Podman secrets / `config.json`, or (b) add a post-generate hook step documented in getting-started. See lessons-learned: "HOMEPAGE_VAR_* env vars are not generated by configure.sh".

---

## Notes

- **BL-009 Phase 2** (guard LLM) is next — networking layer is now stable (BL-011/BL-012/BL-015 all done).
- **BL-015 step 9** (LAN hostname cleanup): ✅ completed 2026-05-05. Removed `SERVICES.mynetworksettings.com` from `configs/traefik/dynamic/services.yaml` admin router rule; tailnet CNC path is authoritative.
- **Metrics track deferred** (BL-013/005/006): no capability dependencies; re-insert into queue when observability becomes a priority.
- **configs/nodes/*.json** worker files deprecated by D-005; do not delete until `node.sh list --refresh` is verified working on all nodes (TC25 headscale SSH gap still open per BL-012 notes).
- **Auto model constraint:** Any item marked `Auto` must be scoped strictly to the defined work. Agent must not infer or expand scope, modify adjacent files, or act on assumptions outside the item spec.
