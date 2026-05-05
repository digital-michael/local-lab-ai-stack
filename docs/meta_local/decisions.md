# Design Decisions

Project-scoped conventions and deliberate choices that should be applied consistently across all future work.

---

## D-001 — Layer Ordering in Tables, Charts, and Diagrams

**Date:** 2026-03-25
**Status:** Active

**Decision:** When presenting the technology stack in any visual or tabular format, layers are ordered user-first (closest to the user at top, closest to infrastructure at bottom).

**Order:**

| # | Layer | Rationale |
|---|---|---|
| 1 | Application | What the user directly interacts with |
| 2 | Edge | The gateway the user passes through (routing + auth) |
| 3 | Inference | The AI engine the applications delegate to |
| 4 | Knowledge | The RAG pipeline feeding the inference layer |
| 5 | Storage | Persistence underpinning all layers above |
| 6 | Observability | Operator-facing; last because users never directly interact with it |

**Within each layer**, order components by the one most directly exposed to the caller first (e.g., LiteLLM before Ollama/vLLM in Inference; Grafana before Prometheus/Loki/Promtail in Observability).

**Rationale:** Consistent user-centric ordering lets readers locate information quickly without re-orienting between documents. It also matches the mental model of "what calls what" when reasoning about the system.

---

## D-002 — Future: mTLS for Node Authentication

**Date:** 2026-04-04
**Status:** Deferred

**Decision:** Do not implement mTLS for node-to-controller authentication at this time. Use per-node API keys issued on join (see current implementation). Revisit mTLS when moving toward a full internal service mesh.

**Deferred because:**
- Requires a signing CA on the controller — new key material to protect and back up
- Traefik would need `clientAuth` reconfigured or TLS termination moved into FastAPI
- Every `curl` call in `heartbeat.sh`, `node.sh`, `bootstrap.sh` would need `--cert/--key/--cacert` flags and Darwin-vs-Linux cert path branches
- Cert lifecycle / renewal workflow adds ongoing operational overhead
- API keys are sufficient for this threat model (intranet, nodes behind firewall)

**When to revisit:** If the stack adopts an internal mTLS service mesh (e.g., Traefik internal routing with mutual TLS between all services), node authentication should be migrated to client certificates at that time to stay consistent with the mesh model.

---

## D-003 — Refactor Layer 2 Inference Tests to pytest (Tech Debt)

**Date:** 2026-04-04
**Status:** Deferred — P2

**Decision:** Replace `testing/layer2_remote_nodes.bats` (T-090–T-094) with a pytest file `testing/layer2_inference/` that parametrizes over all `inference`-capable nodes from `configs/nodes/*.json`.

**Problem with current state:**
- `layer2_remote_nodes.bats` discovers nodes by hardcoded `name` fields (`macbook-m1`, `alienware`). Any deployment with different node names silently skips all tests rather than failing.
- Test count is fixed at 2 workers (5 tests). A third node gets no coverage; a single-node deployment has 3 permanent skips.
- Controller-local inference (SERVICES GPU/CPU) has no layer-2 coverage at all.
- BATS has no parametrize equivalent — generating per-node test cases dynamically is not idiomatic.

**Target state:**
- New `testing/layer2_inference/` pytest suite mirroring layer5's conftest pattern.
- Parametrize over `configs/nodes/*.json` filtered to `capabilities` containing `"inference"`.
- Controller nodes (profile=controller) included, probing `localhost:11434`.
- Test IDs derived from `node_id` field (stable, portable).
- BATS file removed or reduced to a TCP-only reachability ping (no model/completion logic).

**Why deferred:**
- Current tests pass on this deployment; core inference functionality verified manually.
- Refactor is low-urgency until a third node or new deployment forces the issue.

**When to promote:** Adding a third inference node, onboarding a new deployment, or any failing skip-storm on a peer system.

---

## D-004 — Headscale as Authoritative Presence and Identity Layer

**Date:** 2026-05-04
**Status:** Active — supersedes LAN-IP assumption in D-002

**Decision:** Headscale is the authoritative source for node presence, identity (hostname, tailnet IP, tags), and network-layer authentication. WireGuard mutual auth replaces the mTLS discussion in D-002 at the network layer. The admin API's per-node API-key join mechanism is deprecated as the primary auth path once all nodes are enrolled.

**Consequences:**
- `node.sh list` reads headscale REST API as primary source; `configs/nodes/*.json` worker files are deprecated (see D-005).
- Node join = `tailscale up` enrollment. Node unjoin = `headscale nodes delete`. Node rename = `headscale nodes rename`.
- `scripts/heartbeat.sh` and its systemd timer are deprecated — headscale `online`/`lastSeen` replaces the network-presence function.

**SPOF mitigation (three-tier fallback — all must remain available):**
1. **Short-term / local outage:** LAN SSH to each node's LAN IP. Every node must have an operator SSH key in `authorized_keys` independent of tailscale. This is break-glass tier 1.
2. **Prolonged / VPS outage:** Migrate headscale to run locally on CENTAURI (or a local VM). Target: before any production use. Eliminates VPS dependency for intranet traffic.
3. **Production fallback:** LAN SSH as documented operational fallback documented in operator runbook. Photondatum.space headscale remains as off-site coordination for roaming nodes.

**TODO (must do before production):** Move headscale to local host (option 2). Document LAN SSH break-glass procedure in CENTAURI-playbook.md.

---

## D-005 — Distributed Node Configuration (Pull Model)

**Date:** 2026-05-04
**Status:** Active — supersedes static `configs/nodes/*.json` for worker nodes

**Decision:** Each node is its own authoritative source of configuration. Nodes publish their config locally at `~/.config/ai-stack/node-config.json` (written by `node.sh configure` at bootstrap). The controller pulls config on demand via `tailscale ssh <node> cat ~/.config/ai-stack/node-config.json` and caches it at `~/.config/ai-stack/nodes/<hostname>.json`.

**Data flow:**
```
node enrolls → tailscale up
             → node.sh configure  (writes ~/.config/ai-stack/node-config.json)
controller   → node.sh list --refresh
             → per online node: ssh pull node-config.json
             → merge: headscale presence + node config → local cache
```

**Cache semantics:** Cache serves fast reads. Invalidated by: `node.sh list --refresh`, node join/unjoin/model-pull lifecycle events. Stale tolerance: operator-configurable, default 10 minutes.

**`configs/nodes/*.json` fate:**
- Worker files (`inference-worker-*.json`, `knowledge-worker-*.json`) → deprecated; removed once all nodes are migrated to distributed config.
- `controller-1.json` → retained; controller describes itself, not a remote node.
- D-034's `/admin/v1/nodes` API surface is preserved but its data source changes from static files to the controller cache. No API change visible to consumers.

**TODO (must do before deprecating static files):** Implement `node.sh configure` (writes node-config.json) and `node.sh list --refresh` (pulls and caches). Update `testing/layer2_remote_nodes.bats` to read from cache not static files (see D-003).

---

## D-006 — Pull-Based Metrics via node-exporter-ai

**Date:** 2026-05-04
**Status:** Active — supersedes heartbeat telemetry POST

**Decision:** Application-layer metrics (CPU, memory, GPU VRAM, Ollama models loaded) are exposed by a lightweight Python process (`node-exporter-ai`) on each worker node. Prometheus on the controller scrapes each node's metrics endpoint over the tailnet. Workers are passive — they need no knowledge of the controller address.

**Exporter shape:**
- Binds to tailnet IP only (`100.64.x.x:9200`) — never `0.0.0.0`.
- Exposes Prometheus text format at `/metrics`.
- Sources: `/proc/meminfo`, `nvidia-smi`, `ollama /api/metrics`, local `node-config.json` for label injection (profile, alias, namespace).
- Runs as a systemd user service on Linux nodes.

**Prometheus scrape targets:** Dynamic — generated from `node.sh list --json` output filtered to online nodes. Controller-side script updates `configs/prometheus/prometheus.yml` scrape targets on `--refresh`.

**TC25 exception:** App Store sandbox may block listener port binding. TC25 uses Prometheus Pushgateway as fallback if `:9200` bind fails. Isolated exception; does not affect architecture.

**TODO (must do):** Implement `services/node-exporter-ai/`; add scrape target generation to `node.sh list --refresh`; update `configs/prometheus/prometheus.yml` template.

---

## D-007 — Tailscale SSH as Command-and-Control Transport (Transitional)

**Date:** 2026-05-04
**Status:** Active — transitional; see TODO for target state

**Decision:** Operator command delivery to worker nodes uses `tailscale ssh <node> <command>` invoked from the controller via a new `node.sh remote <node> <cmd>` wrapper. This replaces the heartbeat response channel (suggestions, rename_to) and the `_curl_admin` POST pattern for write operations.

**Headplane role:** Network-layer visibility only — node enrollment, tag management, pre-auth key lifecycle, ACL policy editing. Headplane does NOT execute commands on application nodes.

**ACL hardening (must do in rapid succession):**
- Tighten headscale ACL from full-mesh SSH to directional: `tag:controller` → `tag:inference|tag:knowledge` only.
- Workers cannot SSH to each other or back to the controller.
- Apply before `node.sh remote` is in production use.

**Target state (must not remain SSH-based long-term):** Replace `tailscale ssh` CNC with an isolated, purpose-built control channel — likely a lightweight authenticated HTTPS endpoint per node (not reusing SSH). SSH across the tailnet should be disabled once the replacement is in place.

**TODO (must do before production — HIGH PRIORITY):**
1. Tighten ACL to directional controller→worker immediately.
2. Design and implement non-SSH CNC transport (BL-new, P1).
3. Disable `tailscale ssh` on all nodes once CNC transport is live.

---

## D-008 — LAN→Tailnet IP Migration Strategy

**Date:** 2026-05-04
**Status:** Active

**Decision:** Migrate each node's `controller_url` (and all inter-node references) from LAN IPs to headscale tailnet IPs (`100.64.x.x`) one node at a time, controller-first. Verify each node's tailnet connectivity and stack health before proceeding to the next.

**Migration order:**
1. Controller (CENTAURI) — update its own state files; verify `node.sh list` and `status.sh` show correct tailnet data.
2. Each worker in turn — use `node.sh remote <node>` to update `controller_url` atomically; verify heartbeat (until deprecated) and node-config pull succeed.
3. TC25 last — highest risk (App Store SSH constraints); use direct tailnet IP SSH if `tailscale ssh` fails.

**Risk:** Workers mid-operation during controller migration will see transient `_curl_admin` failures (exit 0, silent). Acceptable given heartbeat is being deprecated. Any `node.sh` command on a worker during the window will fail; re-run after worker migration completes.

**Verification gate per node:** `bash scripts/status.sh -vv` on controller shows tailnet row `connected`, node appears `online` in `node.sh list`, and `node.sh remote <node> bash scripts/status.sh` returns exit 0.

**TODO:** Execute migration as part of BL-new headscale-migration backlog item. Update CENTAURI-playbook.md with LAN SSH break-glass procedure before starting.

---

## D-009 — Tailnet-Accessible Knowledge-Index Endpoint (BL-015)

**Date:** 2026-05-05
**Status:** Active — spec approved, implementation pending

**Decision:** Expose the knowledge-index to worker nodes over the tailnet via a dedicated Traefik entrypoint bound exclusively to the controller's tailnet IP. Workers use this endpoint as `controller_url` for all CNC and query traffic, replacing the LAN hostname dependency entirely.

### Architecture

```
[Worker: SOL / TC25]  ──tailnet──►  Traefik tailnet entrypoint (100.64.0.4:8443)
                                           │
                              PathPrefix /v1/*   → bearer token (tag:net-*)
                              PathPrefix /mcp/*  → bearer token (tag:net-*)
                              PathPrefix /v1/cnc/* → bearer token (tag:net-*)
                                           │
                                  knowledge-index (127.0.0.1:8100)
```

`/admin/*` is **excluded** from the tailnet route. It remains operator/localhost only (API-key gated, unchanged).

### Traefik entrypoint

- Name: `tailnet`
- Bind: `100.64.0.4:8443` (tailnet IP only — never `0.0.0.0`)
- Container publish: `PublishPort=100.64.0.4:8443:8443` in the Traefik quadlet
- TLS: enabled by default; toggle via `config.json → tailnet_tls: true`; rendered into `traefik.yaml` by `configure.sh`

### Authentication

- **Automated (worker/AI tasks):** Bearer token per `tag:net-*` domain. Token stored in `config.json → network_domains.<domain>.bearer_token` and propagated to `node-config.json → network.bearer_token` at configure time. Validated in KI application layer; Traefik is routing + TLS only.
- **Operator/on-demand CNC (deferred):** Second Traefik router on the tailnet entrypoint using Authentik forward-auth middleware, scoped to `/v1/cnc/operator/*`. No impact on worker routes.

### CNC namespace

New path group `/v1/cnc/*` in knowledge-index replaces LAN `/admin/v1/nodes/*` for worker-initiated operations:
- `POST /v1/cnc/register` — replaces `/admin/v1/nodes` (POST) for tailnet workers
- `POST /v1/cnc/heartbeat` — replaces `/admin/v1/nodes/{id}/heartbeat` for tailnet workers
- Future: `/v1/cnc/pull-model`, `/v1/cnc/reindex`, operator CNC commands

`/admin/*` retained, unchanged, for operator/localhost access only. Its data remains the system of record for node registration.

### Bootstrap and discovery

Two-layer model:
1. **Initial provisioning:** `node.sh configure --controller-url <url>` (or derived from `config.json`) writes `controller_url` into `node-config.json` at join time.
2. **Runtime discovery:** `GET /v1/config` (public within tailnet, no bearer token required) returns `{ "controller_url", "schema_version", "domain", "capabilities" }`. Workers call this at startup and on `node.sh configure --refresh-config`. Enables controller IP changes without re-joining every worker.

### MCP on tailnet

`/mcp/*` is exposed on the tailnet route (same bearer token as `/v1/*`). Workers do not implement MCP client capability as part of base bootstrap — that capability is deferred to the agentic executor feature (future BL). The route costs nothing and avoids a retroactive architecture change when agentic workers are introduced.

**TODO (agentic executor):** When workers need to call back to KI as an MCP tool server from within an agent loop, implement MCP client in `services/node-exporter-ai/` or a new `services/agent-executor/`. HTTP SSE transport assumed (works over tailnet unchanged). stdio transport deferred.

### LAN cleanup (after BL-015 migration verified)

- Remove `Host('SERVICES.mynetworksettings.com')` from `knowledge-index-admin` router in `services.yaml`
- Update `controller_url` on all workers to `https://100.64.0.4:8443` via `node.sh configure`
- Deprecate LAN hostname as routing target for worker traffic

**Rationale:** Eliminates the last LAN hostname dependency for worker→controller traffic. Tailnet IP is the single canonical address for all remote node communication, consistent with D-004 (headscale as authoritative presence). LAN IP retained only for colocated services where tailnet adds no value.
