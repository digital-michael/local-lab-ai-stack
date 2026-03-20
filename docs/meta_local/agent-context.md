# Agent Working Context
**Date:** 2026-03-19
**HEAD:** `c70f1f0` (main, origin/main)
**Repo:** `git@github.com:digital-michael/local-lab-ai-stack.git`
**Target Audience:** LLM Agent resuming work

---

## Session Summary — What Was Done

### Phase 7 — MCP Integration ✅ Code Complete, Not Yet Runtime-Verified

All Phase 7 code was implemented and committed at `0b997bc`. See [docs/ai_stack_blueprint/ai_stack_checklist.md](../ai_stack_blueprint/ai_stack_checklist.md) §Phase 7 for the full spec.

**What landed:**
- `services/knowledge-index/requirements.txt` — added `mcp[server]>=1.6.0`
- `services/knowledge-index/app.py` — MCP HTTP/SSE transport added alongside REST API
  - `GET /mcp/sse` — SSE stream endpoint (MCP clients connect here)
  - `POST /mcp/messages` — MCP message channel
  - Tools: `search_knowledge`, `ingest_document`
  - Auth: `API_KEY` env var (bearer token); auth disabled when unset
  - Sync I/O wrapped in `asyncio.to_thread()` — event loop safe
- `configs/traefik/dynamic/services.yaml` — `knowledge-index` router + service entry (`PathPrefix('/mcp')`)
- `configs/config.json` — `mcp{}` metadata block added to knowledge-index service
- `testing/layer3_model/test_mcp_tools.py` — T-MCP-001..004 (SSE headers, tool discovery, ingest, search)
- `docs/library/framework_components/knowledge-index/guidance.md` — MCP integration section + HOW-TO for adding new tools (`8367dc0`)

**⚠ Pending before Phase 7 tests will pass:**
1. Rebuild the knowledge-index container image (picks up `mcp[server]`):
   ```
   podman build -t localhost/knowledge-index:0.1.0 services/knowledge-index/
   ```
2. Restart the service: `systemctl --user restart knowledge-index.service`
3. Run: `pytest testing/layer3_model/test_mcp_tools.py -v`
4. Mark Phase 7 ✅ COMPLETE in [docs/ai_stack_blueprint/ai_stack_checklist.md](../ai_stack_blueprint/ai_stack_checklist.md) (Phase 7 header line ~390)

### Phase 8 — GPU Enablement ✅ COMPLETE (`63764f1`)

Already done before this session. vLLM running on RTX 3070 Ti with Qwen2.5-1.5B-Instruct; Ollama CPU-pinned. See checklist §Phase 8 for details.

### Repo Housekeeping (`2ec84c9`, `dce8a67`, `c70f1f0`)

- `docs/meta_local/decisions.md` → **moved** to `docs/decisions.md`
  - All cross-references updated in `README-agent.md` and `ai_stack_checklist.md`
- `docs/meta` (symlink), `docs/meta_local/dynamics.md`, `docs/meta_local/review_log.md` — removed from git tracking, added to `.gitignore` (files still present locally)
- `LICENSE` brought in via merge of GitHub's auto-generated `master` branch

---

## Current State

| Item | Status |
|---|---|
| Working tree | Clean |
| Remote | `origin/main` up to date |
| Phase 1–6 | ✅ Complete |
| Phase 7 | ✅ Code complete — needs image rebuild + test run + checklist update |
| Phase 8 | ✅ Complete |
| Phase 9 | ⬜ Not started |
| Phase 10 | ⬜ Not started |

---

## What's Next — Phase 9 (Remote Inference Nodes)

Full spec in [docs/ai_stack_blueprint/ai_stack_checklist.md](../ai_stack_blueprint/ai_stack_checklist.md) §Phase 9 (~line 519).

**Goal:** Enable a macOS M1 to contribute inference capacity to the controller's LiteLLM. Steps:

| Step | What |
|---|---|
| 9.1 | Add `node_profile` field to `config.json` (`controller`/`inference-worker`/`peer`); `configure.sh generate-quadlets` selects services per profile |
| 9.2 | Add `nodes[]` array to `config.json` (workstation + macbook-m1 entries, addresses TBD) |
| 9.3 | `scripts/register-node.sh` — POST to controller LiteLLM `/model/new`; heartbeat; static fallback |
| 9.4 | macOS M1 setup: Podman Machine, Ollama container, TLS, run `register-node.sh` |
| 9.5 | `configure.sh detect-hardware` macOS branch (Apple Silicon detection via `sysctl hw.optional.arm64`) |
| 9.6 | `models[]` gains optional `host` field; `generate-litellm-config` resolves via `nodes[]` |
| 9.7 | `diagnose.sh` extended for remote node reachability and health |

**Decisions to record (per checklist):**
- D-018: Node profiles — `controller`, `inference-worker`, `peer`
- D-019: macOS nodes use Podman Machine
- D-020: Dynamic node registration with static fallback

---

## Key File Locations

| File | Purpose |
|---|---|
| [docs/decisions.md](../decisions.md) | ADRs D-001–D-015 (new path — was `docs/meta_local/decisions.md`) |
| [docs/ai_stack_blueprint/ai_stack_checklist.md](../ai_stack_blueprint/ai_stack_checklist.md) | Master task tracker |
| [services/knowledge-index/app.py](../../services/knowledge-index/app.py) | Knowledge Index Service (REST + MCP) |
| [docs/library/framework_components/knowledge-index/guidance.md](../library/framework_components/knowledge-index/guidance.md) | MCP endpoint reference + HOW-TO for new tools |
| [configs/config.json](../../configs/config.json) | Machine-readable SSOT |
| [configs/traefik/dynamic/services.yaml](../../configs/traefik/dynamic/services.yaml) | Traefik routers (now includes knowledge-index /mcp route) |
| [testing/layer3_model/test_mcp_tools.py](../../testing/layer3_model/test_mcp_tools.py) | MCP test suite (T-MCP-001..004) |
