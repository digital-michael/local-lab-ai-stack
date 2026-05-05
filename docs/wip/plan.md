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
**Status:** partial — steps 1+2 complete; steps 3+4 blocked by BL-015  
**Decisions:** D-004, D-007, D-008  

**Steps:**

1. ✅ **Tighten ACL to directional controller→worker** — deployed 2026-05-04.  
   `ssh` block changed from full-mesh (`tag:net-ecotone-000-01` → self) to directional  
   (`tag:controller` → `tag:inference`, `tag:knowledge`). Headscale restarted. Verified:  
   `tailscale ssh sol` from CENTAURI exits 0. Node 1 (stale ghost enrollment) deleted;  
   node 5 retags to `tag:controller,tag:knowledge,tag:net-ecotone-000-01`.

2. ✅ **Document LAN SSH break-glass** — added §7.11 to `output/CENTAURI-playbook.md`.  
   Table: all node LAN IPs, SSH users, key paths. ToC entry added.

3. ⛔ **LAN→tailnet IP migration — controller_url** — **blocked by BL-015.**  
   Port 8100 is `bind: 127.0.0.1` (intentional). Workers cannot reach the controller API  
   over the tailnet until BL-015 delivers a tailnet-accessible authenticated endpoint.  
   `controller_url` remains `https://SERVICES.mynetworksettings.com` on all nodes.

4. ⛔ **LAN→tailnet IP migration — workers** — blocked by step 3 / BL-015.

**Verification gate (when unblocked):** `node.sh list` shows all nodes online with tailnet IPs; `bash scripts/status.sh -vv` tailnet row shows `connected N/N peers`.

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
**Status:** not started  
**Decisions:** D-007  
**Blocked by:** BL-011 (ACL must be directional before this is used in anger)

**Steps:**
1. Implement `node.sh remote <node> <cmd>` — resolves node to tailnet IP from cache/headscale, invokes `tailscale ssh <node> <cmd>`.
2. Fallback: if tailscale SSH fails, attempt `ssh <user>@<lan-ip> <cmd>` (read from node-config or static map).
3. Migrate `node.sh suggestions` to use remote SSH (pull a local queue file on the node) instead of `_curl_admin`.
4. Add `node.sh remote <node> bash scripts/status.sh` as the standard worker health check.

**Verification gate:** `node.sh remote sol bash scripts/status.sh` returns exit 0 from CENTAURI.

---

### BL-015 — Tailnet-Accessible KI Endpoint + CNC Foundation
**Priority:** P1 — unblocks BL-011 steps 3+4 (LAN→tailnet IP migration)  
**Status:** spec complete (`docs/wip/bl-015-spec.md`), ready for implementation  
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
**Status:** not started  
**WIP reference:** `docs/wip/headplane-remote-deploy.md` (draft, ready to execute)  
**Decisions:** D-007 (Headplane role: network UI only)

Execute `docs/wip/headplane-remote-deploy.md` as written. Bind to tailnet IP only. Verify ACL restricts access to `tag:controller` only.

---

## Queue (full backlog in priority order)

| ID | Priority | Title | Status | Decisions |
|---|---|---|---|---|
| BL-001 | P2 | CENTAURI-playbook.md | ✅ done 2026-05-04 | — |
| BL-002 | P3 | node.sh list: headscale backend + stanza output | ✅ done 2026-05-04 | — |
| BL-003 | P3 | --json output mode for scripts | ✅ done 2026-05-04 | — |
| BL-015 | P1 | Tailnet-Accessible KI Endpoint + CNC Foundation | spec complete — ready to implement; **unblocks BL-011 steps 3+4** | D-009 |
| BL-011 | P1 | Headscale migration: ACL hardening + LAN break-glass + IP migration | partial — steps 1+2 done; steps 3+4 blocked by BL-015 | D-004, D-007, D-008 |
| BL-012 | P1 | Distributed node config: node.sh configure + --refresh | ✅ done `7813139` — verification gate complete 2026-05-05 | D-005 |
| BL-009 | P1 | Content Review Layer Phase 2 (guard LLM) | Phase 1 done (`9d33dce`) | D-039 |
| BL-013 | P2 | node-exporter-ai: per-node Prometheus metrics exporter | not started | D-006 |
| BL-014 | P2 | node.sh remote: SSH command delivery wrapper | not started | D-007 |
| BL-016 | P2 | Headplane deployment | not started | D-007 |
| BL-008 | P2 | Default credential policy | not started | — |
| BL-004 | P2 | RLM integration research | not started | — |
| BL-005 | P2 | Internal operator dashboard | not started | — |
| BL-006 | P2 | Live throughput + profiling dashboard | not started | — |
| BL-007 | P2 | Configurable domain in setup | not started | — |
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

## Notes

- **BL-009 Phase 2** (guard LLM) remains P1; held in order after BL-011/BL-012 so guard LLM deployment runs on a stable network layer.
- **BL-015** (tailnet KI endpoint) spec is complete. Implement before BL-013 (node-exporter-ai) — BL-013 depends on tailnet connectivity being proven.
- **configs/nodes/*.json** worker files are deprecated by D-005 but must not be deleted until BL-012 `--refresh` is verified working on all nodes.
