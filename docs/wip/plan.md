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
**Priority:** P1 — must precede any command-delivery work  
**Status:** not started  
**Decisions:** D-004, D-007, D-008  

Phase 1 establishes the security and resilience prerequisites before any further tailnet-dependent work.

**Steps (in order, each verified before next):**

1. **Tighten ACL to directional controller→worker**  
   Edit `/etc/headscale/acl.json` on `photondatum.space`: replace full-mesh SSH allow with  
   `src: [tag:controller] → dst: [tag:inference, tag:knowledge]` only.  
   Verify: `tailscale ssh sol` from CENTAURI works; `tailscale ssh centauri` from SOL is denied.

2. **Document LAN SSH break-glass in CENTAURI-playbook.md**  
   Add §: each node's LAN IP, SSH user, and key location. Verify SSH login to each node via LAN IP independent of tailscale. This must work before any migration step.

3. **LAN→tailnet IP migration — controller-first**  
   Update CENTAURI's own `~/.config/ai-stack/controller_url` to tailnet IP `100.64.0.1`.  
   Verify: `bash scripts/status.sh -vv` shows tailnet row `connected`; `node.sh list` shows correct data.

4. **LAN→tailnet IP migration — workers one at a time**  
   For each worker (SOL → workstation-ki → macbook-m1/TC25 last):  
   - `node.sh remote <node> 'printf "http://100.64.0.1" > ~/.config/ai-stack/controller_url'`  
   - Verify: `node.sh list` shows node online; `node.sh remote <node> bash scripts/status.sh` exits 0.

**Verification gate (all nodes):** `node.sh list` shows all nodes online with tailnet IPs; `bash scripts/status.sh -vv` tailnet row shows `connected N/N peers`.

---

### BL-012 — Distributed Node Config: node.sh configure + --refresh
**Priority:** P1 — unblocks node-exporter-ai and deprecation of static node files  
**Status:** not started  
**Decisions:** D-005  
**WIP reference:** `docs/wip/headscale-proposal.md` (§ distributed config)

**Steps:**
1. Define `node-config.json` schema: `node_id`, `alias`, `profile`, `capabilities`, `models` (from Ollama), `version`, `updated_at`.
2. Implement `node.sh configure` — writes `~/.config/ai-stack/node-config.json` on the local node.
3. Implement `node.sh list --refresh` — for each online headscale node, SSH-pulls `node-config.json`, merges with headscale presence data, writes to controller cache `~/.config/ai-stack/nodes/<hostname>.json`.
4. Update `node.sh list` (display path) to read from cache when `--headscale-url` is set and no `--refresh` flag. Show staleness warning if cache is >10 min old.
5. Run `node.sh configure` on each enrolled node. Verify `node.sh list --refresh` populates cache correctly.

**Verification gate:** `node.sh list --refresh` shows fresh data; removing a static `configs/nodes/*.json` file does not break the list output.

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

### BL-015 — Non-SSH CNC transport (replace tailscale SSH for command delivery)
**Priority:** P1 — must not remain SSH-based in production  
**Status:** not started — design phase  
**Decisions:** D-007 (TODO section)

This is the design-then-implement item that retires `tailscale ssh` as the CNC transport. Likely shape: a minimal authenticated HTTPS endpoint per node (e.g. a tiny FastAPI process, tailnet-IP-bound, with a pre-shared bearer token from `node-config.json`). Controller POSTs a command envelope; node executes from a restricted allow-list; response returned in HTTP body.

**Design gate (do before implementation):** Write a one-page spec in `docs/wip/` covering: command allow-list, auth mechanism, response format, timeout handling. Review before coding.

**Blocked by:** BL-014 (need operational SSH path first to understand what commands need transport).

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
| BL-011 | P1 | Headscale migration: ACL hardening + LAN break-glass + IP migration | not started | D-004, D-007, D-008 |
| BL-012 | P1 | Distributed node config: node.sh configure + --refresh | not started | D-005 |
| BL-009 | P1 | Content Review Layer Phase 2 (guard LLM) | Phase 1 done (`9d33dce`) | D-039 |
| BL-015 | P1 | Non-SSH CNC transport (replace tailscale SSH) | not started — design first | D-007 |
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
- **BL-015** (non-SSH CNC) must not be blocked indefinitely. If BL-014 SSH path takes >2 sprints to stabilize, promote BL-015 design phase in parallel.
- **configs/nodes/*.json** worker files are deprecated by D-005 but must not be deleted until BL-012 `--refresh` is verified working on all nodes.
