# AI Stack — Implementation Checklist
**Last Updated:** 2026-03-24 UTC

## Purpose
Master task tracker for the AI Multivolume RAG Platform. Covers blockers, deferrable work, future features, and open considerations. Updated as items are resolved.

Cross-references: [architecture](ai_stack_architecture.md) · [implementation](ai_stack_implementation.md) · [configuration](ai_stack_configuration.md)

---

## Table of Contents

0. [Execution Plan](#0-execution-plan)
1. [Configuration System](#1-configuration-system)
2. [Blockers](#2-blockers-required-before-first-deployment)
3. [Deferrable](#3-deferrable-address-incrementally-post-deployment)
4. [Future Features](#4-future-features-architecture-roadmap)
5. [Open Considerations](#5-open-considerations)

---

# 0 Execution Plan

This section defines the reproducible, sequenced implementation plan across all unresolved work. Each phase has explicit inputs, steps, outputs, and verification criteria. Phases are executed in order; steps within a phase may be parallelized where noted.

**Goal:** Any agent or human executing this plan should arrive at the same result.

**Decisions already made (recorded in [decisions.md](../decisions.md)):**
- **D-010 (recorded):** Meta framework extraction (resolved this session)
- **D-011 (recorded):** Traefik as reverse proxy (resolves Consideration #23)
- **D-012 (recorded):** Knowledge Index Service as standalone Python/FastAPI microservice (resolves Consideration #24)
- **D-013 (recorded):** Volume manifest specification (`.ai-library` package format)
- **D-014 (recorded):** Discovery profiles: localhost, local, WAN

---

## Phase 1 — Record Decisions and Update Architecture ✅ COMPLETE (commit `4561edf`)

**Goal:** Formalize the four pending decisions and update the architecture doc to reflect two new components and the discovery profile concept.

**Inputs:** Decisions from conversation (D-011 through D-014), current architecture doc.

### Steps

1.1. **Record D-011 in [decisions.md](../decisions.md)**
   - Decision: Traefik as the reverse proxy / TLS termination layer
   - Rationale: Label-based discovery fits Podman containers; native forward-auth with Authentik; dynamic configuration without restarts
   - Alternatives considered: Caddy (simpler but less dynamic), nginx (manual config)

1.2. **Record D-012 in [decisions.md](../decisions.md)**
   - Decision: Knowledge Index Service is a standalone Python/FastAPI microservice
   - API: REST, versioned (`/v1/`), OpenAPI spec
   - Design: lightweight, internal, with short-lived query→volume routing cache
   - Rationale: routing is a distinct concern from vector search; stands alone on the critical query path; standard API enables future transport swap (gRPC) or reimplementation
   - Alternatives considered: Qdrant metadata layer, Flowise workflow, LiteLLM plugin

1.3. **Record D-013 in [decisions.md](../decisions.md)**
   - Decision: `.ai-library` volume manifest specification
   - Structure: `manifest.yaml`, `metadata.json`, `topics.json`, `documents/`, `vectors/`, `checksums.txt`, `signature.asc`
   - `manifest.yaml` — volume identity, version, author, license, profile compatibility
   - `metadata.json` — machine-readable topic tags, embedding model, document count, vector dimensions
   - `topics.json` — human/LLM-readable topic taxonomy
   - `checksums.txt` — integrity verification (all profiles)
   - `signature.asc` — provenance verification (WAN mandatory, local optional, localhost skip)

1.4. **Record D-014 in [decisions.md](../decisions.md)**
   - Decision: Three discovery profiles — localhost, local, WAN
   - Profiles are a property of both the deployment instance (which mechanisms are active) and the volume (where it advertises)
   - localhost: filesystem scan, implicit trust
   - local: mDNS/DNS-SD, trust by network membership + optional signature
   - WAN: registry/federation protocol, mandatory signature verification
   - MVP: localhost profile implemented; local and WAN specified but deferred

1.5. **Update [ai_stack_architecture.md](ai_stack_architecture.md)**
   - Add Traefik to §1 System Overview component list
   - Add Traefik to §3 Component Responsibilities table
   - Update §2 Core Architecture mermaid: add Traefik between User and WebUI; add Traefik as TLS termination point
   - Add §9 Networking: Traefik routing and TLS termination description
   - Update §4 Knowledge Library System: add discovery profile concept, update package structure to match D-013
   - Update §7 Distributed Node Architecture: Traefik on controller node
   - Add Knowledge Index Service API overview to §4 or new subsection

1.6. **Update [ai_stack_implementation.md](ai_stack_implementation.md)**
   - §2: Add `traefik.container` and `knowledge-index.container` to quadlet file list
   - §3: Insert Traefik after network (position 2); Knowledge Index stays at position 7; insert Traefik's dependencies
   - §6: Update library manifest schema to match D-013 specification
   - Add new §10: Knowledge Index Service API Specification (OpenAPI contract, endpoints, caching behavior)
   - Add new §11: Discovery Profile Specification (three profiles, discovery mechanisms, trust models, verification rules)

### Outputs
- 4 decision entries in decisions.md
- Architecture doc reflects 14 → 16 components (Traefik + Knowledge Index)
- Implementation doc has quadlet list, dependency order, API spec, and discovery spec

### Verification
- `grep -c "traefik\|Traefik" ai_stack_architecture.md` returns ≥ 5
- §3 Component Responsibilities has 15 rows (13 original + Traefik + Knowledge Index already listed)
- D-011 through D-014 exist in decisions.md
- Implementation §10 and §11 exist

---

## Phase 2 — Create Component Library Entries ✅ COMPLETE

**Goal:** Add the two new components to the reference library with the standard three-file structure.

**Inputs:** Phase 1 outputs, existing component library pattern.

### Steps

2.1. **Create `docs/library/framework_components/traefik/`**
   - `best_practices.md` — Traefik best practices: labels-based routing, automatic TLS with Let's Encrypt or static certs, middleware chains, rate limiting, access logs, health dashboard
   - `security.md` — TLS hardening (minimum TLS 1.2, cipher suites), forward-auth middleware with Authentik, dashboard access control, header security (HSTS, CSP, X-Frame-Options), rate limiting as DDoS mitigation
   - `guidance.md` — Project-specific: static file configuration (not Docker provider since we use Podman quadlets), Podman labels or file-based dynamic config, entrypoints for HTTP (redirect to HTTPS) and HTTPS, forward-auth integration pattern with Authentik, certificate storage path

2.2. **Create `docs/library/framework_components/knowledge-index/`**
   - `best_practices.md` — API design: OpenAPI spec, versioned routes, health endpoints, structured error responses, idempotent registration; caching: TTL-based routing cache, cache invalidation on volume registration; metadata: topic taxonomy design, embedding model versioning
   - `security.md` — Internal-only network exposure (no host port by default), API key authentication between services, input validation on volume registration, checksums verified on volume load, signature verification scoped by discovery profile
   - `guidance.md` — Project-specific: Python/FastAPI runtime, PostgreSQL for metadata storage, REST `/v1/` API, volume manifest spec (reference D-012), discovery profiles (reference D-013), caching strategy (short TTL, per-conversation), localhost discovery as MVP

2.3. **Update [framework_components/README-agent.md](../library/framework_components/README-agent.md)**
   - Add `knowledge-index/` row: "Knowledge volume routing and discovery"
   - Add `traefik/` row: "Reverse proxy and TLS termination"
   - Update component count if mentioned (14 → 16)

### Outputs
- 6 new files (3 per component)
- Updated component table (16 components)

### Verification
- `ls docs/library/framework_components/traefik/` returns 3 files
- `ls docs/library/framework_components/knowledge-index/` returns 3 files
- Component table in README-agent.md has 16 rows

---

## Phase 3 — Update Configuration System ✅ COMPLETE

**Goal:** Add both new services to config.json and the configuration reference doc. All values needed for deployment are defined (or explicitly TBD for image tags).

**Inputs:** Phase 1 decisions, Phase 2 guidance files, existing config.json structure.

### Steps

3.1. **Add `traefik` service to `configs/config.json`**
   ```json
   {
     "image": "docker.io/library/traefik",
     "tag": "TBD",
     "container_name": "traefik",
     "dns_alias": "traefik.ai-stack",
     "depends_on": [],
     "ports": [
       { "host": 443, "container": 443 },
       { "host": 80, "container": 80 }
     ],
     "volumes": [
       { "host": "$AI_STACK_DIR/configs/traefik", "container": "/etc/traefik", "mode": "ro" },
       { "host": "$AI_STACK_DIR/configs/tls", "container": "/etc/traefik/certs", "mode": "ro" }
     ],
     "environment": {},
     "secrets": [],
     "health_check": {
       "command": "traefik healthcheck --ping",
       "interval": "30s",
       "retries": 3,
       "timeout": "5s"
     },
     "resources": {
       "cpus": 1,
       "memory": "512m",
       "gpu": null
     }
   }
   ```

3.2. **Add `knowledge-index` service to `configs/config.json`**
   ```json
   {
     "image": "TBD",
     "tag": "TBD",
     "container_name": "knowledge-index",
     "dns_alias": "knowledge-index.ai-stack",
     "depends_on": ["postgres", "qdrant"],
     "ports": [
       { "host": 8100, "container": 8100 }
     ],
     "volumes": [
       { "host": "$AI_STACK_DIR/libraries", "container": "/libraries", "mode": "rw" }
     ],
     "environment": {
       "DATABASE_URL": "postgresql://aistack:@postgres.ai-stack:5432/aistack",
       "QDRANT_URL": "http://qdrant.ai-stack:6333",
       "CACHE_TTL_SECONDS": "300",
       "DISCOVERY_PROFILE": "localhost"
     },
     "secrets": [
       { "name": "postgres_password", "target": "POSTGRES_PASSWORD" },
       { "name": "qdrant_api_key", "target": "QDRANT_API_KEY" },
       { "name": "knowledge_index_api_key", "target": "API_KEY" }
     ],
     "health_check": {
       "command": "curl -sf http://localhost:8100/v1/health",
       "interval": "30s",
       "retries": 3,
       "timeout": "5s"
     },
     "resources": {
       "cpus": 1,
       "memory": "1g",
       "gpu": null
     }
   }
   ```

3.3. **Update [ai_stack_configuration.md](ai_stack_configuration.md)**
   - §1 Container Images: add Traefik and Knowledge Index rows
   - §2 Environment Variables: add Traefik and Knowledge Index env blocks
   - §3 Resource Limits: add rows for both services
   - §4 Port Mappings: add 80, 443 (Traefik), 8100 (Knowledge Index); update 9443 → removed (replaced by Traefik 443)
   - §5 Network / DNS aliases: add `traefik.ai-stack`, `knowledge-index.ai-stack`
   - §6 Volume Paths: add Traefik config path, Knowledge Index libraries path
   - §8 Secrets Inventory: add `knowledge_index_api_key`
   - §9 TLS Configuration: update to reference Traefik as the termination point; certificate mount path
   - §10 Health Checks: add rows for Traefik and Knowledge Index

### Outputs
- config.json has 14 services (12 existing + 2 new)
- Configuration doc covers all 14 services consistently

### Verification
- `jq '.services | keys | length' configs/config.json` returns 14
- `jq '.services.traefik.ports' configs/config.json` returns port mappings
- `jq '.services["knowledge-index"].depends_on' configs/config.json` returns `["postgres", "qdrant"]`
- Configuration doc §1 table has 14 rows

---

## Phase 4 — Resolve Remaining Blockers ✅ COMPLETE

**Goal:** Complete all blocker items so the stack is deployable. This phase is mostly research and mechanical execution.

**Inputs:** Phase 3 outputs (complete config.json structure), upstream documentation for each service.

### Steps

4.1. **Pin all container image tags/digests** *(research required)*
   - For each of the 14 services, determine the latest stable image tag as of execution date
   - Use explicit version tags (e.g., `v3.1.2`), not `latest`
   - Update `"tag"` field in config.json for each service
   - Update §1 table in ai_stack_configuration.md
   - Knowledge Index Service image is custom-built; set to `localhost/knowledge-index:0.1.0` as placeholder

4.2. **Finalize environment variables per service**
   - Review each service's upstream documentation to confirm env var names and defaults
   - Verify all values in config.json `environment` blocks match upstream expectations
   - Ensure all `<secret>` references use Podman secrets (not inline values)
   - Add any missing env vars discovered during review

4.3. **Confirm volume mount paths per container**
   - Verify each service's expected container-side path against upstream documentation
   - Confirm host-side paths use `$AI_STACK_DIR` prefix consistently
   - Add `:Z` SELinux note where applicable
   - Add Traefik config directory to `install.sh` directory creation list

4.4. **Finalize service dependency order in config.json**
   - Review and complete all `depends_on` arrays:
     - Traefik: `[]` (starts first after network)
     - PostgreSQL: `[]`
     - Qdrant: `[]`
     - Authentik: `["postgres"]`
     - LiteLLM: `["postgres"]`
     - vLLM: `["litellm"]`
     - ollama: `["litellm"]`
     - Knowledge Index: `["postgres", "qdrant"]`
     - Flowise: `["litellm", "qdrant", "knowledge-index"]`
     - OpenWebUI: `["litellm"]`
     - Prometheus: `[]`
     - Grafana: `["prometheus"]`
     - Loki: `[]`
     - Promtail: `["loki"]`
   - Update implementation doc §3 startup order to match

4.5. **Update secrets inventory**
   - Add `knowledge_index_api_key` to configuration §8 and implementation §1
   - Confirm all secret names are consistent between config.json, configuration doc, and implementation doc

4.6. **Update deploy.sh**
   - Add calls to `configure.sh validate` and `configure.sh generate-quadlets` before deployment
   - Ensure Traefik config directory is created during deployment

### Outputs
- All `"tag": "TBD"` resolved in config.json
- All env vars confirmed against upstream
- All volume paths verified
- Complete dependency graph in config.json
- Updated secrets inventory
- deploy.sh calls validation pipeline

### Verification
- `jq '[.services[].tag] | map(select(. == "TBD")) | length' configs/config.json` returns 0 (except Knowledge Index custom image)
- `scripts/configure.sh validate` passes
- Implementation §3 startup order matches config.json dependency graph
- All secrets in config.json exist in configuration §8

---

## Phase 5 — Generate Deployment Artifacts ✅ COMPLETE

**Goal:** Produce all files needed for first deployment.

**Inputs:** Phase 4 outputs (fully resolved config.json).

### Steps

5.1. **Generate quadlet unit files**
   - Run `scripts/configure.sh generate-quadlets`
   - Output: 15 files in `~/.config/containers/systemd/`:
     - `ai-stack.network`
     - `traefik.container`
     - `postgres.container`
     - `qdrant.container`
     - `authentik.container`
     - `litellm.container`
     - `vllm.container`
     - `ollama.container`
     - `knowledge-index.container`
     - `flowise.container`
     - `openwebui.container`
     - `prometheus.container`
     - `grafana.container`
     - `loki.container`
     - `promtail.container`

5.2. **Create Traefik static configuration**
   - Create `$AI_STACK_DIR/configs/traefik/traefik.yaml`:
     - Entrypoints: web (80, redirect to websecure), websecure (443, TLS)
     - Providers: file (dynamic config directory)
     - Ping endpoint enabled (for health check)
     - Log level: info
   - Create `$AI_STACK_DIR/configs/traefik/dynamic/` for per-service route configs

5.3. **Provision Podman secrets**
   - Run `scripts/configure.sh generate-secrets`
   - Prompts for values for: `postgres_password`, `litellm_master_key`, `qdrant_api_key`, `openwebui_api_key`, `flowise_password`, `knowledge_index_api_key`

### Outputs
- 15 quadlet files generated
- Traefik static configuration in place
- All secrets provisioned in Podman secret store

### Verification
- `ls ~/.config/containers/systemd/*.container | wc -l` returns 14
- `ls ~/.config/containers/systemd/*.network | wc -l` returns 1
- `podman secret ls | wc -l` returns ≥ 6
- `cat ~/.config/containers/systemd/traefik.container` contains correct image and ports

---

## Phase 6 — Update Checklist and Close Considerations ✅ COMPLETE (2026-03-10)

**Goal:** Mark resolved items, close considerations, and ensure the checklist reflects actual state.

### Steps

6.1. **Resolve Consideration #23** — mark "Resolved: Traefik (D-010)"
6.2. **Resolve Consideration #24** — mark "Resolved: Standalone Knowledge Index Service (D-011)"
6.3. **Update blocker list** — mark completed blockers, add any new blockers discovered
6.4. **Add Knowledge Index Service tasks to deferrable or future:**
   - Build Knowledge Index Service container image (Python/FastAPI)
   - Implement localhost discovery profile
   - Specify local and WAN discovery profiles
   - Build volume ingestion pipeline
6.5. **Record any architecture decisions** in [decisions.md](../decisions.md)
6.6. **Append row to [meta_local/review_log.md](../meta_local/review_log.md)** Review Log

### Outputs
- Checklist accurate to current state
- Considerations #23 and #24 closed
- Meta files updated

### Verification
- No open consideration blocks a Phase 5 deployment
- Checklist task states match reality

---

---

## Phase 7 — MCP Integration (Knowledge Index Service) ✅ COMPLETE

**Goal:** Extend the Knowledge Index Service to expose its RAG capabilities as MCP tools, enabling agent clients (Claude Desktop, Cursor, VS Code Copilot, etc.) to call document ingest and vector search directly over the Model Context Protocol.

**Decision:** Use Anthropic's `mcp` Python SDK initially (fastest path to working); HTTP/SSE transport to fit the containerized Traefik-fronted architecture. REST API remains intact alongside MCP — additive, not replacing.

**Inputs:** Deployed Knowledge Index Service (`services/knowledge-index/app.py`), Traefik dynamic config, existing `knowledge_index_api_key` secret.

### Steps

7.1. **Record MCP transport decision** — add D-015 to `decisions.md`
   - Decision: HTTP/SSE transport (not stdio) — fits containerized deployment behind Traefik
   - Initial implementation: Anthropic `mcp[server]` Python SDK
   - Rationale: stdio requires subprocess on agent side (poor fit for container); SSE over HTTPS is Traefik-compatible and works with all MCP-supporting clients

7.2. **Add `mcp` dependency to Knowledge Index Service**
   - Add `mcp[server]` to `services/knowledge-index/requirements.txt`
   - Rebuild and test image locally

7.3. **Implement MCP tool layer in `app.py`**
   - Mount MCP SSE endpoint at `/mcp/sse` alongside existing FastAPI routes
   - Expose tools:
     - `search_knowledge` — wraps `POST /query`; args: `query: str`, `collection: str`, `top_k: int`
     - `ingest_document` — wraps `POST /documents`; args: `id: str`, `content: str`, `metadata: dict`
   - Reuse existing `_embed()` / `_query()` internals — no new backend logic
   - Auth: validate `API_KEY` env var on every MCP tool call (same secret as REST)

7.4. **Update Traefik dynamic config**
   - Add `/mcp` path prefix rule in `configs/traefik/dynamic/services.yaml`
   - Route to `http://knowledge-index.ai-stack:8100` (same backend, new path)
   - Apply existing auth middleware

7.5. **Update `configs/config.json`**
   - Note MCP SSE endpoint in knowledge-index service metadata (informational)

7.6. **Add MCP tool tests to test suite**
   - New test module `testing/layer3_model/test_mcp_tools.py`
   - Test: connect MCP client to `http://localhost:8100/mcp/sse`, call `search_knowledge`, assert results
   - Mirror structure of `test_rag_pipeline.py`

7.7. **Update component library**
   - `docs/library/framework_components/knowledge-index/best_practices.md` — add MCP tool section
   - `docs/library/framework_components/knowledge-index/guidance.md` — update with SSE endpoint and client config examples

### Outputs
- MCP SSE endpoint live at `/mcp/sse` on knowledge-index container
- Two tools registered: `search_knowledge`, `ingest_document`
- MCP tests passing in pytest suite
- Traefik routing `/mcp` path
- Component library updated

### Verification
- `curl http://localhost:8100/mcp/sse` returns SSE stream headers
- `pytest testing/layer3_model/test_mcp_tools.py` passes
- Agent client (e.g., Claude Desktop) can discover and call `search_knowledge` tool

---

## Phase 8 — Local GPU Enablement and Model Routing ✅ COMPLETE (commit `63764f1`)

**Goal:** Enable vLLM on the local GPU (RTX 3070 Ti, 8 GB VRAM), pin Ollama to CPU, and introduce a `models[]` config section so LiteLLM routes each model to the correct backend and device.

**Decisions:**
- D-016: Ollama = CPU-only (`CUDA_VISIBLE_DEVICES=""`); vLLM = GPU-only via CDI
- D-017: `config.json` gains a top-level `models[]` array; each entry has `name`, `backend` (ollama|vllm), `device` (cpu|gpu), and optional `quantization`; `configure.sh` generates the LiteLLM `model_list` from it

**Inputs:** Deployed stack, `nvidia-smi` confirms GPU, existing LiteLLM config.

### Steps

8.1. **CDI setup for rootless Podman GPU passthrough** ✅
   - Run `nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` (requires sudo once)
   - Verify: `podman run --rm --device nvidia.com/gpu=all ubuntu nvidia-smi`
   - Document in `docs/library/framework_components/vllm/guidance.md`

8.2. **Pin Ollama to CPU** ✅
   - Add `CUDA_VISIBLE_DEVICES=""` to `config.json` → `services.ollama.environment`
   - Regenerate quadlet and restart Ollama

8.3. **Select GPU-appropriate model for vLLM** ✅
   - Constraint: ≤5 GB VRAM after desktop overhead on 8 GB card
   - Selected: `Qwen/Qwen2.5-1.5B-Instruct` (FP16, 2.89 GB) — fits comfortably
   - Download chosen model to `$AI_STACK_DIR/models/qwen2.5-1.5b/`
   - Update `config.json`: `command` with `--model /models/qwen2.5-1.5b --served-model-name qwen2.5-1.5b --gpu-memory-utilization 0.55 --max-model-len 2048 --enforce-eager`

8.4. **Add `models[]` section to `config.json`** ✅
   ```json
   "models": [
     { "name": "llama3.1:8b",   "backend": "ollama", "device": "cpu" },
     { "name": "qwen2.5-1.5b",  "backend": "vllm",   "device": "gpu",
       "repo": "Qwen/Qwen2.5-1.5B-Instruct", "quantization": null }
   ]
   ```

8.5. **Extend `configure.sh` to generate LiteLLM `model_list`** ✅
   - New subcommand: `configure.sh generate-litellm-config`
   - Reads `models[]` + `services` → produces `configs/models.json`
   - CPU models → `ollama_chat/<model>` at `http://ollama.ai-stack:11434`
   - GPU models → `openai/<model>` at `http://vllm.ai-stack:8000/v1` (note: /v1 required)

8.6. **Add `configure.sh detect-hardware`** ✅
   - Detect GPU (nvidia-smi), VRAM, system RAM
   - Suggest node profile and viable models based on available resources
   - Output human-readable summary; optionally write to `config.json`

8.7. **Start vLLM, verify end-to-end** ✅
   - `systemctl --user start vllm.service`
   - Verify via LiteLLM: `curl /v1/models` lists both CPU and GPU models
   - GPU confirmed via `nvidia-smi --query-compute-apps` (4528 MiB, VLLM::EngineCore)
   - Chat completions via LiteLLM → vLLM confirmed working

8.8. **Update diagnose.sh** ✅
   - `_check_models()`: report which models are GPU-backed vs CPU-backed
   - Full profile: verify CDI is configured when vLLM is in service list

### Outputs
- vLLM running on GPU, Ollama running on CPU, both visible via LiteLLM
- `models[]` in config.json as source of truth for model→backend→device mapping
- `configure.sh detect-hardware` available for new node setup
- LiteLLM config auto-generated from `models[]`

### Verification
- [x] `nvidia-smi` shows vLLM process using GPU
- [x] `podman exec ollama env | grep CUDA` returns `CUDA_VISIBLE_DEVICES=`
- [x] `curl -H "Authorization: Bearer $KEY" http://litellm.ai-stack:4000/v1/models` lists both models
- [x] `diagnose.sh --profile full` passes with both models reported

---

## Phase 9 — Remote Inference Nodes ✅ COMPLETE (commit `f62fd44`)

**Goal:** Enable remote machines to contribute inference capacity to the controller's LiteLLM. Phase 9 is subdivided into four tracked sub-phases: 9a (controller-side config, no hardware access required), 9b (M1 bare-metal setup), 9c (Alienware Podman worker), 9d (tests). Each sub-phase is committed separately once all steps within it are completed, compiled, tested, and verified.

**Three-Node Architecture:**
- **Controller** — workstation (Linux, RTX 3070 Ti 8 GB VRAM) — full stack, all services
- **M1** — TC25 (macOS ARM64, 16 GB unified RAM) — bare-metal Ollama with Metal GPU acceleration
- **Alienware** — `SOL.mynetworksettings.com` / `10.19.208.113` (Linux, GTX ~3 GB VRAM) — Podman inference-worker profile

**Decisions (to be formally recorded in `docs/decisions.md` as step 9a.1):**
- D-016/D-017: Phase 8 decisions (Ollama CPU-only; `models[]` in config.json) — write formally
- D-018: Node profiles — `controller` (full stack), `inference-worker` (Ollama + promtail only), `peer` (full stack + remote provider); stored as `node_profile` in `config.json`
- D-019 (revised): M1 uses **bare-metal Ollama** for Metal GPU access; Podman Machine deferred as TODO
- D-020 (revised): **Static `nodes[]` config** for Phase 9; dynamic registration/heartbeat deferred as TODO
- D-0xx: **Quantized models preferred (Q4_K_M)**; `detect-hardware` autoselects by VRAM/RAM headroom

**Inputs:** Phase 8 complete. M1 reachable at `TC25.mynetworksettings.com` / `10.19.208.118`. Alienware at `SOL.mynetworksettings.com` / `10.19.208.113`.

---

### Phase 9a — Controller-Side Configuration *(no hardware access needed)*

- [x] **9a.1** Record decisions D-016 through D-0xx in `docs/decisions.md`
  - D-016 (Phase 8): Ollama = CPU-only (`CUDA_VISIBLE_DEVICES=""`)
  - D-017 (Phase 8): `config.json` gains `models[]` array; `configure.sh generate-litellm-config` derives LiteLLM model list
  - D-018: Node profiles (`controller`, `inference-worker`, `peer`)
  - D-019 (revised): M1 = bare-metal Ollama; Podman Machine deferred (see TODOs)
  - D-020 (revised): Static `nodes[]` config; dynamic registration/heartbeat deferred (see TODOs)
  - D-021: Quantized models preferred; `detect-hardware` autoselects Q4_K_M tier

- [x] **9a.2** Add `nodes[]` to `config.json`
  - Schema per node: `name`, `profile`, `address` (DNS preferred), `address_fallback` (IPv4/IPv6), `os`, `deployment` (`bare_metal` | `podman`), `models[]`
  - Controller entry, M1 entry (`TC25.mynetworksettings.com` / `10.19.208.118`, `bare_metal`, `darwin`), Alienware entry (`SOL.mynetworksettings.com` / `10.19.208.113`, `podman`, `linux`)
  - Add remote model entries to top-level `models[]` with `host` field referencing node name

- [x] **9a.3** Extend `configure.sh generate-litellm-config`
  - Resolve `host` → `nodes[].address` (DNS); fall back to `nodes[].address_fallback` if DNS unresolvable
  - Set `api_base` to `http://<resolved>:11434` for remote Ollama nodes
  - Regenerate `configs/models.json`

- [x] **9a.4** Extend `configure.sh generate-quadlets`
  - Filter service list by `node_profile`:
    - `controller` → all services (current behavior, unchanged)
    - `inference-worker` → ollama + promtail only
    - `peer` → all services

- [x] **9a.5** Extend `configure.sh detect-hardware`
  - Add macOS/Apple Silicon branch: `uname -s` = Darwin; detect via `sysctl hw.optional.arm64` and `hw.memsize`
  - Quantized model autoselect tiers (all platforms):
    - `≥ 8 GB VRAM / ≥ 20 GB RAM` → 8B Q4_K_M (e.g., `llama3.1:8b-instruct-q4_K_M`)
    - `4–8 GB VRAM / 12–20 GB RAM` → 7B Q4_K_M
    - `3–4 GB VRAM / 8–12 GB RAM` → 3B Q4_K_M (e.g., `llama3.2:3b-q4_K_M`)
    - `< 3 GB VRAM  / < 8 GB RAM`  → 1.5B Q8_0 (e.g., `qwen2.5:1.5b-q8_0`)
  - macOS path: use ~40% of unified RAM as soft model-fit target (Ollama manages paging)

- [x] **9a.6** Verify and commit Phase 9a
  - `configure.sh validate` passes with `nodes[]` present ✅
  - `configure.sh generate-litellm-config` produces remote `api_base` entries ✅
  - `configure.sh generate-quadlets` (inference-worker) produces ollama + promtail only ✅
  - `configure.sh detect-hardware` correct on Linux (regression) ✅; macOS branch verified by code review ✅

---

### Phase 9b — M1 Bare-Metal Setup *(requires SSH to TC25.mynetworksettings.com)*

- [x] **9b.1** Create `scripts/bare_metal/setup-macos.sh`
  - Check Homebrew; install/upgrade Ollama if not present
  - Run embedded hardware detection (reuse `detect-hardware` logic); print recommended quantized model
  - Pull recommended model
  - Configure Ollama to listen on `0.0.0.0:11434` via `OLLAMA_HOST` in LaunchAgent plist
  - Write `~/Library/LaunchAgents/com.ollama.server.plist` for autostart on login

- [x] **9b.2** Create `scripts/register-node.sh`
  - TCP probe: controller address reachable on LiteLLM port
  - Local probe: `curl localhost:11434/api/tags` returns expected model
  - Print static config block for operator to paste into controller's `config.json` `nodes[]`
  - No automatic write to controller (static config model — dynamic deferred)

- [x] **9b.3** Run on TC25 *(SSH session)*
  - Copy and execute `scripts/bare_metal/setup-macos.sh`
  - Confirm model pulled; run `scripts/register-node.sh` and verify output

- [x] **9b.4** Update controller and restart LiteLLM
  - Fill verified M1 details into `config.json` if needed
  - `configure.sh generate-litellm-config`; restart LiteLLM service

- [x] **9b.5** Verify and commit Phase 9b
  - `curl http://TC25.mynetworksettings.com:11434/api/tags` lists model (from controller)
  - Controller LiteLLM `/v1/models` lists M1-hosted model
  - Completion request routed to M1 model succeeds — **confirmed: `TC25 OK`**

---

### Phase 9c — Alienware Podman Worker *(requires access + address)*

- [x] **9c.1** Create `scripts/podman/setup-worker.sh`
  - Verify Podman installed; run `detect-hardware` for model autoselect
  - Call `configure.sh generate-quadlets inference-worker` → ollama + promtail quadlets
  - Pull Ollama quantized model; `systemctl --user start ollama.service`

- [x] **9c.2** Fill Alienware `address` / `address_fallback` in `config.json` once known

- [x] **9c.3** Run `setup-worker.sh` on Alienware; regenerate + restart LiteLLM on controller

- [x] **9c.4** Verify and commit Phase 9c
  - Controller LiteLLM `/v1/models` lists Alienware-hosted model
  - Completion request routed to Alienware model succeeds

---

### Phase 9d — Remote Node Tests

- [x] **9d.1** Create `testing/layer2_remote_nodes.bats`
  - T-090: TCP reachability to M1 Ollama port (11434) from controller
  - T-091: LiteLLM `/v1/models` lists M1-hosted model
  - T-092: Completion request to M1-hosted model name succeeds and returns content
  - T-093: TCP reachability to Alienware
  - T-094: Completion request to Alienware model

- [x] **9d.2** Add `probe_node()` helper to `testing/helpers.bash`
  - Args: `<host> <port>` — returns 0 if TCP open, 1 otherwise; used in T-090/T-093

- [x] **9d.3** Run full test suite; verify no regressions; commit Phase 9d

---

### Phase 9 TODOs *(deferred, not this phase)*

- **Dynamic node registration** — workers auto-POST to LiteLLM `POST /model/new` on startup; controller heartbeat removes stale entries on missed checks
- **Podman Machine on macOS** — containerized macOS workers (no Metal GPU; consistent with Linux Podman pattern)
- **Hosted API providers** — OpenAI / Anthropic / Groq as LiteLLM `models[]` entries (mostly free config additions)
- **Internet-facing self-hosted workers** — public IP/DNS workers; Tailscale or WireGuard mesh; TLS mutual auth between nodes

### Outputs
- M1 and Alienware contributing inference via controller LiteLLM (static routing)
- `nodes[]` schema in `config.json` with `address`/`address_fallback` DNS+IP fallback
- `detect-hardware` quantized model autoselect on Linux and macOS
- `scripts/bare_metal/setup-macos.sh`, `scripts/podman/setup-worker.sh`, `scripts/register-node.sh`
- `testing/layer2_remote_nodes.bats` with T-090 through T-094

### Verification
- `curl /v1/models` on controller lists models from all three nodes
- `testing/layer2_remote_nodes.bats` T-090 through T-092 pass (M1 online); T-093/094 skip
- `configure.sh detect-hardware` correct output on Darwin and Linux

---

## Phase 10 — Knowledge-Worker Nodes and Library Custody

**Goal:** TC25 and SOL upgrade from `inference-worker` to `knowledge-worker` — adding local Knowledge Index (SQLite) and Qdrant. Workers create knowledge library domains and push custody copies to the controller. All synced libraries are accessible from the controller regardless of worker availability.

**Decisions:**
- D-018 (revised): Four node profiles — `knowledge-worker` added; `peer` reserved for future disconnected deployments
- D-022 (revised): Controller is custodian of all synced libraries; inference routing shared via LiteLLM; chat/accounts node-local
- D-023 (revised): Workers push `.ai-library` packages to controller via HTTPS; controller ingests, records provenance, serves independently
- D-024: `knowledge-worker` profile — Ollama + Promtail + KI (SQLite) + local Qdrant; hardware floor: 10 GB RAM / 4 cores / 50 GB disk
- D-025: Library custody model — controller as custodian + provenance registry; `.ai-library` signature anchors authorship

**Inputs:** Phase 9 complete. TC25 and SOL running as `inference-worker`. Controller fully operational.

### Steps

10.1. **Add SQLite support to Knowledge Index Service**
   - Replace in-memory `_doc_collection` dict with SQLite persistence (`sqlite3` or SQLAlchemy)
   - Schema: `documents` table (id, collection, metadata, created_at); `libraries` table (name, version, path, synced_at, visibility)
   - `DATABASE_URL` env var: `sqlite:///...` on workers; existing `postgresql://...` unchanged on controller
   - No migration required — app.py currently has zero database code (in-memory only)

10.2. **Implement `knowledge-worker` profile in `configure.sh generate-quadlets`**
   - Service set: Ollama + Promtail + Knowledge Index + local Qdrant
   - Knowledge Index quadlet: `DATABASE_URL=sqlite:///{{ ai_stack_dir }}/knowledge-index/ki.db`
   - `node_profile=knowledge-worker` enforcement at generation time

10.3. **Add `/v1/libraries` and `/v1/catalog` endpoints to Knowledge Index Service**
   - `POST /v1/libraries` — receive `.ai-library` package (controller only); verify checksum; ingest into Qdrant; record provenance in PostgreSQL
   - `GET /v1/catalog` — list all libraries: name, version, author, origin node, custody status, visibility
   - Auth: existing `API_KEY` guard on all new endpoints

10.4. **Implement `configure.sh sync-libraries` subcommand**
   - Reads `nodes[]` in config.json to find controller address and API key
   - Packages each `.ai-library` directory under `$AI_STACK_DIR/libraries/` and verifies checksums before push
   - POSTs to controller `/v1/libraries` authenticated via `API_KEY`
   - Reports per-library status: new / updated / unchanged / failed

10.5. **Cross-node query routing on controller KI**
   - Primary: query controller's own Qdrant (covers all custody libraries — no worker involvement)
   - Fallback: proxy to origin worker for unsynced/draft libraries not yet pushed to custody
   - Workers: answer local queries only; no cross-peer routing needed

10.6. **Update `configure.sh recommend` for knowledge-worker upgrade path**
   - If current profile is `inference-worker` AND disk ≥ 50 GB → suggest upgrade to `knowledge-worker`
   - Add `sync-libraries` to next-steps output when `knowledge-worker` is recommended

10.7. **Deploy `knowledge-worker` profile to TC25 and SOL**
   - Update `node_profile` in config.json on each node via `configure.sh recommend` or direct edit
   - Run `generate-quadlets` on each node; start Qdrant and Knowledge Index services
   - Push any existing libraries: `bash scripts/configure.sh sync-libraries`

10.8. **Update `diagnose.sh --profile full` for Phase 10 topology**
   - Show library custody status: synced / draft / unsynced per known node
   - Show `/v1/catalog` summary from controller (library count, authors, any missing custody copies)
   - Alert if a worker library has no custody copy on the controller

### Outputs
- TC25 and SOL running `knowledge-worker` profile (Ollama + Promtail + KI (SQLite) + local Qdrant)
- Controller's Qdrant contains all custody copies of synced worker libraries
- `configure.sh sync-libraries` pushes `.ai-library` packages to controller
- Controller `/v1/catalog` lists all libraries with author, origin node, version, and custody status
- All synced libraries accessible from controller regardless of worker availability

### Verification
- [ ] Ingest document on SOL → `sync-libraries` → `GET /query` on controller returns result
- [ ] SOL offline → controller still serves SOL's synced libraries from custody Qdrant
- [ ] `GET /v1/catalog` on controller lists all libraries with origin node and author
- [ ] `configure.sh recommend` on inference-worker node (≥ 50 GB disk) suggests `knowledge-worker` upgrade
- [ ] `diagnose.sh --profile full` shows library custody summary across all nodes

> **⚠️ Phase 10 superseded by D-029 (2026-03-24):** The `knowledge-worker` profile was redesigned as `enhanced-worker` after architecture analysis showed the original profile lacked both a content creation path and a local RAG path. Phase 10 steps 10.1–10.7 are **not implemented** and are replaced by Phase 12. The `/v1/libraries`, `/v1/catalog`, and SQLite persistence work remains valid and is incorporated into Phase 12.

---

## Phase 11 — Node Registry Phase A: Per-Node Files + LiteLLM Aliases + L5 Tests ✅ COMPLETE (commit `e3ed2cd`)

**Goal:** Extract `nodes[]` from config.json into per-node files under `configs/nodes/`. Update all scripts to glob node files. Register per-node LiteLLM model aliases. Implement Layer 5 distributed smoke tests (L1 + L2).

**Decisions:** D-026 (per-node files, status + alias fields), D-028 (L5 distributed tests)

**Inputs:** Phase 9 complete. SERVICES, TC25, SOL all operational as inference-workers.

### Steps

11.1. **Create `configs/nodes/` directory and write per-node files**
   - `configs/nodes/controller-1.json` — SERVICES, profile: controller, status: active, capabilities: []
   - `configs/nodes/inference-worker-1.json` — TC25 (macbook-m1), profile: inference-worker, status: active, os: darwin, deployment: bare_metal, capabilities: []
   - `configs/nodes/inference-worker-2.json` — SOL (alienware), profile: inference-worker, status: active, os: linux, deployment: podman, capabilities: []
   - Schema per D-026 + D-029: `schema_version`, `alias`, `name`, `address`, `address_fallback`, `status`, `profile`, `os`, `deployment`, `registered_at`, `models`, `capabilities`

11.2. **Remove `nodes[]` from config.json; bump schema_version to 1.1**
   - Remove the entire `"nodes": [...]` array from `configs/config.json`
   - Change `"schema_version": "1.0"` to `"schema_version": "1.1"`

11.3. **Update all scripts that read `.nodes[]` to glob `configs/nodes/*.json`**
   - `scripts/configure.sh` — `generate-litellm-config`, `generate-quadlets`, `detect-hardware` all read `.nodes[]`; replace with node file glob
   - `scripts/deploy.sh`, `scripts/status.sh`, `scripts/pull-models.sh` — any node-aware logic

11.4. **Update `pull-models.sh` to register per-node LiteLLM model aliases**
   - For each active node file with `models[]`, register `ollama/<model>@<alias>` with `api_base: http://<node.address>:11434`
   - Example: `ollama/llama3.2:3b-instruct-q4_K_M@inference-worker-2` → `api_base: http://SOL.mynetworksettings.com:11434`

11.5. **Create `testing/layer5_distributed/` test suite**
   - `conftest.py` — enumerate `configs/nodes/*.json`, filter `status == active`; `metrics_recorder` fixture writes `testing/layer5_distributed/results/<timestamp>.json` at session teardown
   - `test_l1_liveness.py` — direct `GET http://<address>:11434/api/tags` per active node; binary pass/fail
   - `test_l2_routing.py` — LiteLLM per-node model-ID targeting; `x-litellm-backend` header assertion; streaming for `ttft`; ~4 cases per node (echo, arithmetic, instruction following, single-turn context)

### Outputs
- `configs/nodes/` with 3 files; `config.json` at schema_version 1.1 with `nodes[]` removed
- All scripts glob node files; no remaining `.nodes[]` references
- `pull-models.sh` registers per-node alias routes in LiteLLM
- L5 test suite passes: L1 all nodes reachable, L2 routing confirmed

### Verification
- [x] `jq '.nodes' configs/config.json` returns `null`
- [x] `ls configs/nodes/` shows 3 `.json` files
- [x] `bash scripts/configure.sh generate-litellm-config` succeeds
- [x] `pytest testing/layer5_distributed/ -v` — L1 all pass; L2 all pass with `results/<timestamp>.json` written

---

## Phase 12 — Enhanced Worker Foundation Phase A (Controller-Side) ✅ COMPLETE (commits `3b0feeb`–`27efd06`)

**Goal:** Implement the Phase A controller-side foundation: MCP auth fix, MinIO file repository, capabilities[] in node schema, LiteLLM RAG hook, web research pipeline (controller fallback), app.py `/v1/search` + SQLite persistence + `/v1/libraries` + `/v1/catalog`.

**Decisions:** D-029 (profile redesign), D-030 (LiteLLM RAG hook), D-031 (web research pipeline), D-032 (MinIO), D-033 (MCP scope + auth fix)

**Inputs:** Phase 11 complete. All scripts reading from `configs/nodes/*.json`.

### Steps

12.1. **Fix MCP auth: set `API_KEY` secret; update Traefik `/mcp/*` route**
   - Add `{ "name": "knowledge_index_api_key", "target": "API_KEY" }` to knowledge-index `secrets[]` in config.json
   - Add `api-key-auth` middleware to `configs/traefik/dynamic/middlewares.yaml` (Bearer token against a known key)
   - Update `configs/traefik/dynamic/services.yaml`: `/mcp/*` router uses `api-key-auth`; `/v1/*` router retains Authentik forward-auth

12.2. **Add MinIO to config.json; deploy; create buckets**
   - Add `minio` service entry: `docker.io/minio/minio`, port 9000 (S3 API, `0.0.0.0`), port 9001 (console, `127.0.0.1` bind), dns_alias `minio.ai-stack`, secrets `minio_root_user` + `minio_root_password`
   - Bump `schema_version` to `1.2`
   - `generate-quadlets` produces `minio.container`
   - On first start: create buckets `documents`, `outputs` via MinIO client; create service account for Flowise + LiteLLM hook

12.3. **Add `capabilities[]` to all node files**
   - Add `"capabilities": []` to all three existing node files from Phase 11
   - Update D-026 schema reference in node files to note `capabilities[]` field

12.4. **Implement LiteLLM `async_pre_call_hook` for RAG injection**
   - `configs/litellm/hooks.py`: `AsyncRAGHook` class implementing `async_pre_call_hook`
   - Extract last user message → `POST /query` to controller KI (`KI_BASE_URL` env var) → prepend top-k results into system message
   - If result metadata contains `source_url`, fetch MinIO pre-signed file content and append (truncated to context window)
   - No-op when `KI_BASE_URL` unset or KI returns empty results
   - Mount into LiteLLM container; configure `LITELLM_CUSTOM_CALLBACK`

12.5. **Add `POST /v1/search` to `services/knowledge-index/app.py`**
   - Accepts `{ "query": str, "collection": str, "max_results": int = 5 }`
   - Returns HTTP 501 if `TAVILY_API_KEY` unset (capability flag — correct behaviour for inference-workers)
   - When set: Tavily search → `_ingest_chunks()` to local Qdrant → trigger custody push to controller
   - Add `tavily-python` to `requirements.txt`

12.6. **Add SQLite persistence + `/v1/libraries` + `/v1/catalog` to `app.py`** *(from Phase 10)*
   - Replace in-memory `_doc_collection` dict with SQLAlchemy `documents` + `libraries` tables; `DATABASE_URL` selects sqlite vs postgresql
   - `POST /v1/libraries` — receive `.ai-library` package, verify checksum, ingest to Qdrant, record provenance in DB
   - `GET /v1/catalog` — list all libraries with name, version, author, origin node, custody status, visibility

12.7. **Flowise Supervisor flow: web research controller-fallback path**
   - Flowise Supervisor: submit research topic → check node files for `web_search` in `capabilities[]` → if none, run controller-local Tavily → summarize via LiteLLM → `POST /documents` on controller KI
   - Export flow JSON to `configs/flowise/research-pipeline.json`

12.8. **Update `configure.sh` for enhanced-worker profile and schema_version 1.2**
   - Add `enhanced-worker` profile to `generate-quadlets` (service set: Ollama + Promtail + KI + Qdrant)
   - `validate` subcommand accepts schema_version 1.2

### Outputs
- MCP endpoint requires API key; Traefik routes correct for both developer tools and REST clients
- MinIO running with `documents` and `outputs` buckets
- Node files declare `capabilities[]`
- LiteLLM RAG hook active on controller
- `POST /v1/search` returns 501 on all current nodes (correct — no Tavily key set)
- `/v1/libraries`, `/v1/catalog`, and SQLite persistence live in `app.py`
- Flowise controller-fallback web research flow operational

### Verification
- [x] `curl -H "Authorization: Bearer <key>" https://<host>/mcp/sse` → 200
- [x] `curl https://<host>/mcp/sse` (no auth) → 401
- [x] MinIO console accessible at `http://127.0.0.1:9001`; buckets exist
- [x] `jq '.capabilities' configs/nodes/inference-worker-1.json` returns `[]`
- [x] Inference request via OpenWebUI → LiteLLM logs show RAG hook executed
- [x] `POST /v1/search` on controller KI → 501 (correct — no TAVILY_API_KEY yet)
- [x] Flowise research flow: `configs/flowise/research-pipeline.json` importable; submit topic → GET /v1/catalog shows new library entry
- [x] `pytest testing/layer5_distributed/ -v` still passes (12 tests collected)
- [x] `diagnose.sh --full` reports `_check_ki_capabilities` pass; /v1/catalog auth working

---

## Phase 13 — Deployment Verification + Layer 5 Test Execution ✅ COMPLETE (commit `7486066`)

**Goal:** Deploy all Phase 12 changes to the running controller stack, run the full test suite end-to-end, and verify the live system matches the implementation contracts. First real execution of L5 distributed tests against live nodes.

**Decisions referenced:** D-029, D-030, D-031, D-032, D-033 (all Phase 12 outputs)

**Inputs:** Phase 12 complete. All 4 commits pushed. Stack on SERVICES currently at pre-Phase-12 state (requires `git pull` + redeploy).

### Steps

13.1. **Pull and redeploy the controller stack (SERVICES)**
   - `git pull` on SERVICES
   - `bash scripts/configure.sh validate` — confirm schema 1.2 accepted
   - `bash scripts/configure.sh generate-quadlets` — regenerate quadlets (litellm, knowledge-index, minio added)
   - `systemctl --user daemon-reload`
   - `bash scripts/start.sh` (or per-service restarts for changed services: litellm, knowledge-index, minio)
   - Verify all services active: `bash scripts/status.sh`

13.2. **Provision new secrets**
   - `bash scripts/configure.sh generate-secrets` — creates `knowledge_index_api_key`, `minio_root_user`, `minio_root_password`
   - Confirm secrets exist: `podman secret ls | grep -E 'knowledge_index|minio'`

13.3. **MinIO bucket creation**
   - Access MinIO console at `http://127.0.0.1:9001`
   - Create buckets: `documents`, `outputs`
   - Create service account for Flowise + LiteLLM hook (read `documents`, read/write `outputs`)

13.4. **Import Flowise research pipeline**
   - Flowise UI → Chatflows → Add → Import → select `configs/flowise/research-pipeline.json`
   - Pre-create `litellm_openai_key` credential in Flowise (OpenAI API type, base URL `http://litellm.ai-stack:4000`, value = LiteLLM master key)
   - Run a test query: "What is the current state of open-source LLM reasoning benchmarks?"
   - Confirm LiteLLM logs show RAG hook executing; confirm `/v1/catalog` updated

13.5. **Run Layer 0–4 BATS tests**
   - `make test-preflight` — confirm new secrets and quadlets present
   - `make test-smoke` — all services return healthy status
   - `make test-litellm` — LiteLLM auth + model list includes per-node aliases
   - `make test-lifecycle` — restart behaviour intact

13.6. **Run Layer 5 distributed tests**
   - SSH access to TC25 and SOL required; both must be running Ollama
   - `pytest testing/layer5_distributed/ -v --tb=short` from SERVICES
   - Confirm: T-500 (Ollama /api/tags), T-501 (declared models present), T-510 (routing coherence × 2 workers)
   - Inspect `testing/layer5_distributed/results/<timestamp>.json` for ttft/latency baselines

13.7. **Run diagnose.sh --full and pytest security suite**
   - `bash scripts/diagnose.sh --profile full`
   - Confirm `_check_ki_capabilities` and `_check_library_custody` pass
   - `make test-security` — auth enforcement, port binding, secret leakage

13.8. **Record baseline metrics**
   - Capture L5 results JSON as the Phase 13 performance baseline
   - Note any failing L5 tests for follow-up (expected: T-510 may fail if workers unreachable)
   - Update review_log.md

### Outputs
- Running stack with all Phase 12 components active
- MinIO with `documents` + `outputs` buckets and service account
- Flowise research pipeline live and tested
- L5 test results JSON with ttft/latency baselines per node
- diagnose.sh --full clean run

### Verification
- [x] `bash scripts/configure.sh validate` exits 0
- [x] `bash scripts/status.sh` shows all expected services active (ollama stopped — expected on controller)
- [x] `curl -s http://127.0.0.1:8100/health` → `{"status": "ok"}`
- [x] `curl -H "Authorization: Bearer <key>" http://127.0.0.1:8100/v1/catalog` → `{"count":0,"libraries":[]}`
- [x] `curl -X POST ... http://127.0.0.1:8100/v1/search` → TAVILY_API_KEY not configured error (expected)
- [x] MinIO console reachable at :9101; all 4 buckets exist (`documents`, `outputs`, `research`, `libraries`)
- [x] `pytest testing/layer5_distributed/ -v` — L1 + L2 pass for reachable nodes (12/12, commit `fd6da76`)
- [x] `pytest testing/security/ -v` — all pass (7/7, commit `fd6da76`)
- [x] `bash scripts/diagnose.sh --profile full` — 0 failures (commit `fd6da76`)

---

## Phase 14 — Config-Driven Test Infrastructure + MinIO Smoke Test ✅ COMPLETE (commit `77cb8f6`)

**Goal:** Eliminate all hardcoded port literals from the BATS test suite. All host ports are read from `configs/config.json` at suite load time via a single Python call in `testing/helpers.bash`, exported as named variables, and referenced by all test files. Also adds the missing MinIO smoke test (T-021), closing two Phase 13 deferrable TODOs.

**Motivation:** Phase 13 deployment found a MinIO port conflict (9000→9100/9101) that would have broken any existing MinIO smoke test. No mechanism existed to propagate port changes from config.json to tests. Identified as a systemic gap.

**Inputs:** Phase 13 complete. All services active. `configs/config.json` is the authoritative source of all host port bindings.

### Steps

14.1. **Add `_port_exports` block to `testing/helpers.bash`**
   - Single `python3` call reads all service `ports[].host` values from `$CONFIG_FILE`
   - Outputs `export VAR=VALUE` lines; result is `eval`'d at helpers.bash load time
   - Variables exported: `TRAEFIK_HTTP_PORT`, `TRAEFIK_HTTPS_PORT`, `TRAEFIK_API_PORT`, `POSTGRES_PORT`, `QDRANT_PORT`, `KNOWLEDGE_INDEX_PORT`, `LITELLM_PORT`, `FLOWISE_PORT`, `OPENWEBUI_PORT`, `PROMETHEUS_PORT`, `GRAFANA_PORT`, `LOKI_PORT`, `MINIO_PORT`, `MINIO_CONSOLE_PORT`

14.2. **Migrate `testing/layer1_smoke.bats` to port variables**
   - Replace all 10 hardcoded `localhost:PORT` literals with `localhost:${VAR_NAME}`
   - T-020 (postgres): `localhost:5432` → `localhost:${POSTGRES_PORT}`

14.3. **Add T-021a MinIO smoke test to `testing/layer1_smoke.bats`**
   - `assert_http_status "200" "http://localhost:${MINIO_PORT}/minio/health/live"`
   - Numbered `T-021a` (not T-021) because T-021–T-024 are reserved for `layer2_traefik.bats`

14.4. **Migrate all `testing/layer2_*.bats` files**
   - `layer2_grafana.bats`: `GRAFANA_URL` var
   - `layer2_prometheus.bats`: `PROM_URL` var
   - `layer2_loki.bats` + `layer2_promtail.bats`: `LOKI_URL` var
   - `layer2_flowise.bats`: `FLOWISE_URL` var
   - `layer2_litellm.bats`: two inline `localhost:9000` literals
   - `layer2_qdrant.bats`: three inline `localhost:6333` literals
   - `layer2_traefik.bats`: Traefik API port + HTTPS port

14.5. **Run full BATS suite; verify 0 regressions**

### Outputs
- `testing/helpers.bash` exports 14 port variables from `config.json`
- All BATS files reference `${VAR_NAME}` — zero hardcoded port literals remain
- T-021 MinIO smoke test added; suite count: 13 (was 12 in layer1)
- Two Phase 13 deferrable TODOs closed

### Verification
- [x] `make test-preflight` 8/8
- [x] `make test-smoke` 13/13 (includes T-021a MinIO)
- [x] `make test-litellm && make test-lifecycle` pass
- [x] `grep -rn "localhost:[0-9]" testing/*.bats` — zero port literals remain
- [x] Manual port remap sanity: change a port in `config.json` → helpers.bash re-derives variable, test URL updates automatically

---

## Phase 15 — Localhost Discovery Profile + Library Manifest Schema ✅ COMPLETE (commit `171054a`)

**Goal:** Enable the controller (and knowledge-workers) to auto-discover `.ai-library` packages placed directly on the filesystem and register+ingest them into the knowledge index — without requiring the custody-push workflow. Define the formal `manifest.yaml` JSON Schema.

**Decisions referenced:** D-013 (manifest spec), D-014 (localhost profile: filesystem scan, implicit trust, checksums only)

**Inputs:** Phase 14 complete. `app.py` implements `/v1/libraries` (custody push) and `/v1/catalog`. `libraries` DB table exists with `path` column that was defined but never populated.

**Not in scope:** local/WAN profiles (mDNS, registry), volume ingestion pipeline (building `.ai-library` FROM raw docs — separate item), library custody sync.

### Steps

15.1. **Define `manifest.yaml` JSON Schema (`configs/library-manifest-schema.json`)**
   - Required fields: `name` (slug string), `version` (semver string)
   - Optional fields: `author`, `license` (SPDX), `description`, `profiles` (list, default `["localhost"]`), `language`, `created_at`
   - Document format of `checksums.txt` (sha256sum-compatible: `<hex>  <rel-path>` per line)
   - Document package directory layout

15.2. **Add `LIBRARIES_DIR` env var to knowledge-index service**
   - Env var: `LIBRARIES_DIR` (default `""` — disabled)
   - Add `PyYAML>=6.0` to `services/knowledge-index/requirements.txt`

15.3. **Implement `POST /v1/scan` endpoint in `app.py`**
   - Scans `LIBRARIES_DIR` (or `path` override in request body) for subdirectories containing `manifest.yaml`
   - For each package: parse `manifest.yaml`, verify `checksums.txt` (warn-only for localhost — absent is non-fatal), read `documents/`, ingest into Qdrant, register in `libraries` table with `path` set and `origin_node="localhost"`
   - `force: bool = false` — skip libraries already in catalog unless forced
   - Returns: `{path, scanned, ingested, skipped, errors[], results[]}`
   - Reuses existing `_ingest_chunks`, `_delete_doc_points`, `_db_set_doc` helpers

15.4. **Add pytest coverage**
   - `test_rag_pipeline.py` or new test file: create a minimal `.ai-library` in `tmp_path`, call `POST /v1/scan`, assert catalog entry returned by `GET /v1/catalog`

### Outputs
- `configs/library-manifest-schema.json` — formal JSON Schema for the manifest format
- `services/knowledge-index/app.py` — `LIBRARIES_DIR` config, `_parse_manifest()`, `_verify_checksums()`, `_scan_library_package()`, `POST /v1/scan` endpoint
- `services/knowledge-index/requirements.txt` — adds `PyYAML>=6.0`
- Two deferrable §3 items closed: "Define library manifest YAML schema" and "Implement localhost discovery profile"

### Verification
- [x] `POST /v1/scan` with a minimal test package returns `{"ingested": 1, "errors": []}`
- [x] `GET /v1/catalog` shows the scanned library with `origin_node = "localhost"` and `path` set
- [x] `POST /v1/scan` on same package (no `force`) returns `{"skipped": 1, "ingested": 0}`
- [x] `POST /v1/scan` with non-existent path returns HTTP 400
- [x] `make test-rag` passes

---

## Phase 16 — Volume Ingestion Pipeline ✅ COMPLETE (commit `2eaeb8d`)

**Goal:** Convert a directory of raw documents into a valid `.ai-library` package that `POST /v1/scan` and `configure.sh sync-libraries` can consume. The pipeline is implemented as `configure.sh build-library` — a standalone shell command, no running services required.

**Decisions:** D-013 (package format and file layout)

**NOT in scope:** Pre-computing `vectors/` (requires embedding model), generating `topics.json` (requires LLM), signing `signature.asc` (requires GPG key). These are Phase 17+ additions.

### Tasks
- [x] 16.1 Close stale `[ ]` deferrable item: "Implement library custody sync" (already built)
- [x] 16.2 Define Phase 16 in checklist
- [x] 16.3 Implement `configure.sh build-library` subcommand
  - Flags: `--source <dir>` (required), `--name <slug>`, `--version <semver>`, `--author`, `--license`, `--description`, `--output <dir>`
  - Produces: `manifest.yaml`, `documents/` (copies supported files), `metadata.json` (auto), `checksums.txt` (sha256)
  - Output default: `$AI_STACK_DIR/libraries/<name>/`
- [x] 16.4 Add bats test coverage (T-075–T-077)

### Outputs
- Updated `scripts/configure.sh` (new `build-library` subcommand)
- New `testing/layer0_preflight.bats`-style test in `testing/layer0_preflight.bats` or new bats file

### Verification
- [x] `configure.sh build-library --source <dir> --name test-library --version 1.0.0` exits 0
- [x] Output directory contains `manifest.yaml`, `documents/`, `metadata.json`, `checksums.txt`
- [x] `manifest.yaml` has correct `name`, `version`, `profiles: [localhost]`
- [x] `checksums.txt` verifies clean with `sha256sum -c`
- [x] `POST /v1/scan` on the output directory returns `{"ingested": 1, "errors": []}`
- [x] T-075–T-077 pass

---

## Phase 17 — Local/WAN Discovery Profile Specification + Foundation ✅ COMPLETE (commit `f60d531`)

**Goal:** Formalize the local (mDNS/DNS-SD) and WAN (registry federation) discovery protocols from D-014 into concrete specifications, populate node configs with capability metadata, and add stub endpoints that compile and test but require peers/registry to function.

**Decisions:** D-014a (local profile: mDNS/DNS-SD), D-014b (WAN profile: registry federation)

**NOT in scope:** Actual mDNS broadcast/listen implementation (requires zeroconf and real peers), WAN registry server software, GPG signature tooling, automatic peer registration.

### Tasks
- [x] 17.1 Expand D-014 in decisions.md with D-014a and D-014b sub-specifications
  - D-014a: service type `_ai-library._tcp`, TXT record fields, discovery flow, trust model, prerequisites
  - D-014b: registry API shape `POST /v1/registry/publish` + `GET /v1/registry/search`, publish payload, trust model, prerequisites
- [x] 17.2 Populate `capabilities[]` on all node configs
  - controller-1: `["knowledge-index", "qdrant", "postgres"]`, `ki_port: 8100`, schema_version 1.2
  - inference-worker-1: `["inference"]`
  - inference-worker-2: `["inference"]`
- [x] 17.3 Add stub endpoints to app.py
  - `DISCOVERY_PROFILE` and `REGISTRY_URL` env vars
  - `GET /v1/catalog/peers` — reads node configs, filters by `knowledge-index` capability, queries peer `/v1/catalog` endpoints, merges results. Returns 501 when `local` not in profile.
  - `GET /v1/catalog/registry` — returns 501 when `REGISTRY_URL` unset or `WAN` not in profile. When set, proxies `GET {REGISTRY_URL}/v1/registry/search`.
- [x] 17.4 Close stale deferrable items in checklist §3
- [x] 17.5 Add pytest coverage for stub endpoints
- [x] 17.6 Update features.md

### Outputs
- Updated `docs/decisions.md` (D-014a, D-014b sub-specifications)
- Updated `configs/nodes/*.json` (capabilities[], ki_port, schema 1.2)
- Updated `services/knowledge-index/app.py` (2 new env vars, 2 stub endpoints)
- New/updated test file for discovery stubs
- Updated `docs/features.md`

### Verification
- [x] `python3 -c "import ast; ast.parse(...)"` on app.py passes
- [x] `GET /v1/catalog/peers` returns 501 when `DISCOVERY_PROFILE=localhost`
- [x] `GET /v1/catalog/registry` returns 501 when `REGISTRY_URL` is empty
- [x] All 3 node config files parse as valid JSON
- [x] Pytest tests for stubs pass

---

## Phase 18 — Library Visibility and Status Enforcement ✅ COMPLETE (commit `5cb3679`)

**Goal:** Implement D-035 two-field access model for library records: `visibility` (public|shared|private|licensed) and `status` (active|unvetted|prohibited). Enforce at ingestion, sync, and catalog endpoints.

**Decision:** D-035 (library visibility and status taxonomy)

### Tasks
- [x] 18.1 Update `configs/library-manifest-schema.json` with `visibility` and `status` fields
- [x] 18.2 Add `status` column to `libraries` DDL with CHECK constraint + `ALTER TABLE` migration
- [x] 18.3 Add `visibility` CHECK constraint to existing column
- [x] 18.4 Update `POST /v1/scan` to read `visibility` from manifest.yaml (default `private`), set `status = 'active'`
- [x] 18.5 Update `POST /v1/libraries` to validate `visibility` and `status` enums (422 on invalid), default `private`/`unvetted`
- [x] 18.6 Update `GET /v1/catalog` to exclude `prohibited`, exclude `unvetted` for non-admin, include `status` in response; gate admin access on `KI_ADMIN_KEY`
- [x] 18.7 Add `--visibility` flag to `configure.sh build-library`; update `sync-libraries` default from `public` → `private`
- [x] 18.8 Add T-103–T-112 pytest coverage (layer3_model/test_visibility_status.py)

### Outputs
- Updated `configs/library-manifest-schema.json`
- Updated `services/knowledge-index/app.py`
- Updated `scripts/configure.sh` (build-library, sync-libraries)
- New `testing/layer3_model/test_visibility_status.py`

---

## Phase 19 — Security Audit Tool ✅ COMPLETE (commit `cb477c6`)

**Goal:** Add `configure.sh security-audit` subcommand that performs an automated security posture scan of the controller node and registered inference-worker nodes. No external service dependencies required at tool-build time.

**Scope:** CLI tool only. Dashboard surface deferred (tracked separately in §4 Future Features).

### Tasks
- [x] 19.1 Implement `cmd_security_audit()` in `scripts/configure.sh`
  - Check A: Port exposure — read `config.json` `.services[].ports[].bind`; flag sensitive services (postgres, qdrant, litellm, flowise, etc.) on 0.0.0.0 as CRITICAL; other wide-bind as WARNING
  - Check B: Auth probing — probe LiteLLM `/models`, Qdrant `/collections`, KI `/v1/catalog`, Ollama `/api/tags` without credentials; 200 → CRITICAL or WARNING; 401/403 → OK; unreachable → INFO
  - Check C: TLS check — `openssl s_client` cert expiry on traefik HTTPS; <7d → WARNING; expired → CRITICAL
  - Check D: Secret hygiene — scan `config.json` string values; paths matching `password|api_key|master_key|secret|token|private_key|passphrase` with non-empty value >6 chars → CRITICAL
  - Check E: Worker hardening — read `configs/nodes/*.json` inference-worker nodes; probe `GET http://<address>:11434/api/tags`; 200 → CRITICAL; unreachable → OK
  - Flags: `--json` (JSON array output), `--skip-network` (offline mode for port + secret checks only)
  - Exit codes: 0 (clean), 1 (warnings), 2 (critical)
- [x] 19.2 Add usage entry and dispatch case to `configure.sh`
- [x] 19.3 Add T-113–T-116 bats tests (`testing/layer0_security_audit.bats`)

### Outputs
- Updated `scripts/configure.sh` (new `cmd_security_audit`, usage, dispatch)
- New `testing/layer0_security_audit.bats`

### Verification
- [x] `configure.sh security-audit --help` exits 0
- [x] `--json` emits valid JSON array
- [x] Config with plaintext `admin_api_key` value triggers CRITICAL + exit 2
- [x] Clean config (all 127.0.0.1 ports, no secrets) exits 0

---

## Phase 20a — D-034 Resolution + Stale Close-Outs ✅ COMPLETE (commit `79e208f`)

**Goal:** Resolve the last pending architectural decision (D-034 — API-Level and Terminal Access) and close stale §3 checklist items that were implemented in earlier phases but never checked off.

**Decision:** D-034 resolved. Operator access is two layers: **(A) Infrastructure CLI** (`scripts/` over SSH) for mutations requiring host access (deploy, start/stop, secrets, security-audit). **(B) Application Admin API** (`/admin/v1/*` routes in Knowledge Index, `KI_ADMIN_KEY`-gated) for read-only observability (health rollup, node status, model catalog, audit results). No new service. Traefik gains an admin router with admin-key-only auth. Terminal access: SSH key-based, no shared credentials, `podman exec` for break-glass only.

### Tasks
- [x] 20a.1 Resolve D-034 in `docs/decisions.md` — replace PENDING entry with full resolution
- [x] 20a.2 Close stale §3 items: `detect-hardware` (Phase 8/9), `node profile support` (Phase 9/11), `macOS M1 inference worker` (Phase 9b)
- [x] 20a.3 Update §4 Operator Dashboard entry to reference D-034 as enabling decision
- [x] 20a.4 Add Phase 20a definition to checklist

### Outputs
- Updated `docs/decisions.md` (D-034 resolved)
- Updated `docs/ai_stack_blueprint/ai_stack_checklist.md` (3 stale items closed, §4 updated, Phase 20a defined)

---

## Phase 21 — Getting Started Guide + Operator FAQ ✅ COMPLETE (commit `96f5c6d`)

**Goal:** Produce user-facing documentation for standing up and operating the stack day-to-day. No code or config changes — documentation only.

**Inputs:** All scripts finalized through Phase 20a. `configure.sh` subcommand set stable.

### Outputs
- `docs/getting-started.md` — 12-step installation and first-deploy walkthrough; quick-reference command table; links to FAQ and architecture
- `docs/operator-faq.md` — 8 how-to recipes (add model, add hosted provider, register node, enable GPU, ingest documents, sync library, backup, security audit); 9 FAQ entries covering the most common failure modes with exact remediation commands

### Verification
- [x] `docs/getting-started.md` exists and covers install → verify path
- [x] `docs/operator-faq.md` exists with how-to guides and FAQ entries
- [x] §4 Getting Started checklist item marked complete
- [x] Phase 19 and Phase 20a commit hashes corrected (were TBD)

---

## Execution Notes

- **Phases 1–3 are documentation and configuration.** They can be executed in a single session with no external dependencies.
- **Phase 4 requires research** (upstream image tags, env var verification). This is the most time-consuming phase.
- **Phase 5 requires a running system** with Podman installed. Can be preceded by `scripts/install.sh` and `scripts/validate-system.sh`.
- **Phase 6 is bookkeeping** and should be done immediately after Phase 5.
- **Knowledge Index Service is custom software** — building it is a separate project tracked under Future Features / Deferrable. The spec (Phase 1) enables the rest of the stack to deploy with a placeholder; the service can be added later without re-architecting.
- **Phase 7 (MCP)** is additive — the REST API is preserved. Phase 7 can be executed independently once the Knowledge Index Service is deployed and healthy.
- **Phase 8 (GPU)** requires NVIDIA GPU with CDI configured. Can be skipped on CPU-only nodes. Purely local — no network dependencies.
- **Phase 9 (Remote Nodes)** requires at least two machines with network connectivity. Can proceed with any OS (Linux or macOS with Podman Machine).
- **Phase 10 (Knowledge-Worker Nodes)** ⚠️ SUPERSEDED by D-029. Do not execute Phase 10 steps. See Phase 12.
- **Phase 11 (Node Registry Phase A)** builds on Phase 9. Extracts `nodes[]` into per-node files, adds `capabilities[]` field, updates all scripts, registers per-node LiteLLM aliases, and adds L5 distributed smoke tests. Prerequisite for Phase 12.
- **Phase 12 (Enhanced Worker Foundation Phase A)** is entirely controller-side. TC25 and SOL remain `inference-worker` throughout Phase A. Key new components: MinIO (file repo), LiteLLM RAG hook, app.py `/v1/search` + SQLite + library custody endpoints, Flowise research flow, MCP auth fix. Phase B (Task Receiver on worker nodes, reassigning SOL to `enhanced-worker`) is deferred.
- **Phase 13 (Deployment Verification)** is the live-system validation phase for all Phase 12 changes. Requires SSH access to TC25 and SOL for L5 distributed tests. Can be done incrementally: controller-only steps first (13.1–13.4), then distributed tests (13.5–13.8) when workers are reachable.

---

# 1 Configuration System

The `configure.sh` script and its JSON config file are the primary mechanism for standing up and maintaining the stack. The JSON file is the machine-readable single source of truth for all service configuration. The markdown configuration doc describes the schema and rationale.

### Tasks

- [x] **Design JSON config schema** — define structure for services, images, env vars, ports, volumes, secrets, dependencies, resource limits, health checks
- [x] **Create `scripts/configure.sh`** — CRUD operations against the JSON config file
  - [x] `configure.sh init` — generate default config.json with all services
  - [x] `configure.sh set <path> <value>` — update a config value
  - [x] `configure.sh get <path>` — read a config value
  - [x] `configure.sh validate` — check config completeness (all TBDs resolved, required fields present)
  - [x] `configure.sh generate-quadlets` — produce systemd quadlet files from config
  - [x] `configure.sh generate-secrets` — prompt for and provision Podman secrets from config inventory
- [x] **Create default `configs/config.json`** — populated with current documented defaults
- [ ] **Support multi-environment configs** — `configs/dev.json`, `configs/prod.json`
- [x] **Update `deploy.sh`** — call `configure.sh validate` and `configure.sh generate-quadlets` before deployment
- [ ] **Update `ai_stack_configuration.md`** — reframe as schema documentation; values live in config.json

---

# 2 Blockers (required before first deployment)

These collapse into the configuration system above. Tracked individually for visibility.

- [x] **Pin all container image tags/digests** — resolve all TBD entries (Configuration §1)
- [x] **Finalize environment variables per service** — confirm defaults, secret references (Configuration §2)
- [x] **Confirm volume mount paths per container** — verify host/container path mappings (Configuration §6)
- [x] **Provision Podman secrets** — create secrets from inventory; integrate with configure.sh (Implementation §1)
- [x] **Generate quadlet unit files** — from config.json via configure.sh (Implementation §2)
- [x] **Define service dependency/startup order** — encode as `depends_on` in config.json (Implementation §3)
- [x] **Resolve reverse proxy service** — no proxy container defined; port 9443 TLS has no backing service (see Consideration #23)
- [x] **Resolve Knowledge Index Service** — listed as component but no image/repo/spec exists (see Consideration #24)

---

# 3 Deferrable (address incrementally post-deployment)

- [ ] **Tune resource limits** — CPU/memory/GPU per container after observing baseline (Configuration §3)
- [x] **Add health checks and readiness probes** — all deployed services now have HealthCmd in config.json; ollama, flowise, prometheus, promtail, authentik health checks confirmed 2026-03-09
- [x] **Configure GPU passthrough / CDI** — procedure documented in Implementation §4; `nvidia-ctk cdi generate` + `AddDevice=` quadlet directive
- [x] **Authentik OIDC integration** — forward-auth already deployed (middlewares.yaml); per-service OIDC config (Grafana, OpenWebUI) documented in Implementation §5
- [x] **Define library manifest YAML schema** — `configs/library-manifest-schema.json` JSON Schema 2020-12; required: name (kebab-case), version (semver); optional: author, license, description, profiles, language, created_at (Phase 15, commit TBD)
- [x] **Create Prometheus alerting rules** — `configs/prometheus/rules/ai_stack_alerts.yml` created; 11 rules across 5 groups; prometheus.yml updated with rule_files stanza
- [x] **Document backup and restore procedures** — `scripts/backup.sh` created; full restore procedure in Implementation §8; daily systemd timer included
- [x] **Build troubleshooting guide** — Implementation §9 expanded with diagnostic commands, 13 common issues, reset and health-check oneliners
- [x] **TLS certificate setup** — `scripts/generate-tls.sh` created; generates local CA + server cert; install trust instructions included; traefik dynamic/tls.yaml updated to reference correct filenames
- [x] **Add config subdirectories to install.sh** — `configs/tls`, `configs/grafana`, `configs/prometheus`, `configs/promtail` all present in install.sh
- [x] **Define log retention/rotation policy** — Loki configured with `retention_period: 168h` (7 days) and compactor enabled in `configs/loki/local-config.yaml`
- [x] **Decide Flowise database backend** — **Decision: SQLite (local `DATABASE_PATH`)** for MVP. Rationale: Flowise stores flow definitions and API keys only — low-volume metadata unsuitable for shared PostgreSQL without added complexity. Migrate to PostgreSQL if multi-instance Flowise or shared workflow DB becomes a requirement. (Resolves Consideration #25)
- [x] **Build Knowledge Index Service** — `services/knowledge-index/` Python/FastAPI microservice; embeddings via ollama llama3.1:8b; Qdrant storage; T-062–T-065, T-067–T-068 passing (commit `fb08f2c`, 2026-03-10)
- [x] **Implement localhost discovery profile** — `POST /v1/scan` endpoint in knowledge-index; scans LIBRARIES_DIR for .ai-library packages; parses manifest.yaml (PyYAML), verifies checksums.txt (warn-only), ingests documents/ into Qdrant, registers with origin_node=localhost; ScanRequest {path, force}; T-070–T-074 (Phase 15, commit TBD)
- [x] **Specify local and WAN discovery profiles** — D-014a (local: mDNS/DNS-SD `_ai-library._tcp`, TXT records, zeroconf) and D-014b (WAN: `POST /v1/registry/publish`, `GET /v1/registry/search`, mandatory GPG signature). Stub endpoints `GET /v1/catalog/peers` and `GET /v1/catalog/registry` added (Phase 17).
- [x] **Build volume ingestion pipeline** — `configure.sh build-library` subcommand: `--source`, `--name`, `--version`, `--author`, `--license`, `--description`, `--output`; produces `manifest.yaml`, `documents/`, `metadata.json`, `checksums.txt`; T-095–T-097b (Phase 16, commit `2eaeb8d`).
- [x] **Integrate MCP server into Knowledge Index Service** — implemented in Phase 7 (`app.py` lines 607+): `search_knowledge` and `ingest_document` MCP tools over HTTP/SSE transport at `/mcp/sse`; auth guard on `API_KEY`; cross-node routing in `search_knowledge` mirrors REST `/query` behaviour. Deferrable entry was a stale duplicate of Phase 7 (already ✅ COMPLETE).
- [ ] **Enable local GPU for vLLM** — CDI setup, pin Ollama to CPU, select quantized model for 8 GB VRAM, add `models[]` config section, auto-generate LiteLLM model_list (see Phase 8)
- [x] **Add `configure.sh detect-hardware`** — `detect-hardware` and `recommend` subcommands implemented (Phase 8/9); detects GPU/VRAM/RAM, suggests node profile and model tier per D-021. Stale `[ ]` closed Phase 20a.
- [x] **Add node profile support** — `controller`, `inference-worker`, `peer` profiles implemented; `configure.sh` generates profile-specific quadlets; `status.sh` reads `node_profile`; per-node files in `configs/nodes/` carry profile and capabilities (Phase 9/11). Stale `[ ]` closed Phase 20a.
- [ ] **Implement dynamic node registration** — workers register with controller LiteLLM on startup; heartbeat; static fallback (see Phase 9, D-027 Phase B)
- [x] **Set up macOS M1 inference worker** — TC25 (macbook-m1) running Ollama natively, registered in `configs/nodes/inference-worker-1.json`, reachable from controller, LiteLLM alias configured (Phase 9b). Stale `[ ]` closed Phase 20a.
- [x] **Implement library custody sync** — `POST /v1/libraries` fully implemented in `app.py` (custody ingest with checksum verification, Qdrant ingestion, PostgreSQL provenance); `configure.sh sync-libraries` subcommand fully implemented (reads `libraries/`, POSTs to controller `/v1/libraries` with auth, reports per-library status). Both were built alongside Phase 12 infrastructure and pre-existed Phase 15. Stale `[ ]` entry.
- [x] **Drive smoke tests from `config.json`** — `testing/helpers.bash` `_port_exports` block reads all host ports from `config.json` via Python at suite load time; exports 14 named variables; all `testing/*.bats` files reference `${VAR_NAME}` — zero hardcoded port literals remain. Closed Phase 14 (`77cb8f6`).
- [x] **Add MinIO smoke test (T-021a)** — `testing/layer1_smoke.bats` T-021a: `assert_http_status "200" "http://localhost:${MINIO_PORT}/minio/health/live"`. Closed Phase 14 (`77cb8f6`).
- [x] **License inventory** — `docs/licenses/THIRD_PARTY.md` created with SPDX-style entries for all 15 container images, 8 knowledge-index Python packages, 42 dev/test venv packages (via `pip-licenses`), 4 LLM model weights, and 4 hosted API providers. Key notices: AGPLv3 applies to Grafana/Loki/Promtail/MinIO (internal deployment unaffected); Meta Llama 3.x Community License (commercial OK below 700M MAU); Qwen 2.5 Apache-2.0. `make license-check` target added to refresh the venv snapshot.
- [x] **Harden library visibility and status (D-035)** — two-field access model fully enforced (Phase 18):
  - `configs/library-manifest-schema.json`: `visibility` (public|shared|private|licensed, default private) and `status` (active|unvetted|prohibited) fields added
  - `libraries` DDL: `status TEXT NOT NULL DEFAULT 'unvetted' CHECK (...)` column added; `visibility` CHECK constraint added; `ALTER TABLE` migration for existing DBs
  - `POST /v1/scan`: reads `visibility` from `manifest.yaml` (clamped to valid values, default `private`); sets `status = 'active'`; fixes latent `manifest["author"]` KeyError
  - `POST /v1/libraries`: validates `visibility` and `status` against enum (422 on invalid); defaults `visibility = private`, `status = unvetted`
  - `GET /v1/catalog`: always excludes `prohibited`; excludes `unvetted` for non-admin; includes `status` in response; admin identified by `KI_ADMIN_KEY` bearer token
  - `configure.sh build-library`: `--visibility` flag added (default `private`); written to `manifest.yaml`; `sync-libraries` default updated from `public` → `private`
  - T-103–T-112 pytest coverage: 10 tests across validation, filtering, and admin gating
- [x] **Harden security posture via security audit tool (Phase 19)** — `configure.sh security-audit` subcommand:
  - Port exposure: reads `config.json` port bindings; flags sensitive services (postgres, qdrant, litellm, flowise, etc.) bound to 0.0.0.0 as CRITICAL; non-sensitive wide-bind as WARNING
  - Auth probing: probes LiteLLM `/models`, Qdrant `/collections`, Knowledge-Index `/v1/catalog`, and Ollama `/api/tags` without credentials; 200 → CRITICAL; 401/403 → OK; unreachable → INFO
  - TLS check: `openssl s_client` cert expiry on traefik HTTPS endpoint; >7d OK; <7d WARNING; expired CRITICAL
  - Secret hygiene: scans all string values in `config.json` for paths containing `password|api_key|master_key|secret|token|private_key|passphrase`; flags non-empty values >6 chars as CRITICAL
  - Worker node hardening: reads `configs/nodes/*.json` for `inference-worker` nodes; attempts `GET http://<address>:11434/api/tags`; unauthenticated 200 → CRITICAL; unreachable → OK
  - Flags: `--json` (machine-readable JSON array), `--skip-network` (offline mode)
  - Exit codes: 0 = clean, 1 = warnings, 2 = critical findings
  - T-113–T-116 bats coverage (layer0_security_audit.bats): --help, --json validity, plaintext secret detection, clean-config no-critical

---

# 4 Future Features (architecture roadmap)

- [ ] **Operator dashboard** — web UI with tab-based navigation across User, Team, System, and Admin contexts. **Prerequisite:** D-034 (resolved Phase 20a) defines the Layer B `/admin/v1/*` endpoints that the dashboard consumes. Security audit results surface via `/admin/v1/audit` (Phase 19 CLI → Layer B wrapper):
  - **User tab**
    - Personal contexts (private, user-scoped)
    - Common/publicly-shared contexts (readable by all authenticated users)
  - **Team tab**
    - Team-only shared contexts (role-scoped)
  - **Admin tab**
    - Special admin contexts (definition TBD)
    - Register / suspend / unregister inference nodes
    - Restart, stop, backup, diagnose, and status operations per node
    - Full library entries (private, sensitive — admin-only view)
    - Podman secrets inventory — list secret names, types, and creation/update timestamps (no values exposed); indicate which config-defined secrets are missing from the store
  - **Nodes tab**
    - Node list: node ID, display name, profile (`inference-worker` / `knowledge-worker` / `peer`), online/offline health indicator, last-seen timestamp
    - Per-node detail view:
      - Health: CPU / RAM / VRAM utilization, disk free, uptime
      - Solution activity: recent LLM calls (model, prompt tokens, latency), active inference requests, error rate
      - Loaded models: all models present in Ollama model store on that node
      - Active models: models currently loaded into VRAM / serving requests
      - Local libraries: `.ai-library` packages indexed by the node (name, version, author, visibility, sync status with controller)
  - **System tab**
    - Per-component health panel with links to: direct web interface, log stream, configuration, and metrics (performance, memory, API call counts)
    - Library entries visible to users/teams (public, non-sensitive — auto-filtered for common auth view)
  - Additional elements to be discovered as the stack matures

- [ ] Service registry and discovery
- [ ] Distributed vector shards (multi-node Qdrant)
- [ ] GPU scheduling and multi-tenant inference
- [ ] Automated knowledge library generation
- [ ] Multi-model A/B testing through LiteLLM
- [ ] Federated RAG across remote library nodes
- [ ] Multi-environment config support (dev/staging/prod) via configure.sh
- [ ] Team-shared chat/context state — shared Postgres or sync protocol so chat history, user accounts, and conversation context are available across nodes (future, extends D-022)
- [ ] **Federated MCP tool registry** — MCP tools defined on any node are discoverable and callable by agents on any other node without code duplication; single registry synced across the mesh; covers built-in tools (knowledge search, document ingest) and operator-defined custom tools

- [ ] **Library access gating** — per-library access controls for content type, registered interest, and payment; applied at query and catalog endpoints:
  - Content type gating: mark individual libraries as `public`, `restricted` (authenticated users only), or `private` (author + admin only); enforced at `/v1/query` and `/v1/catalog`
  - Topic interest registration: users declare topics of interest; catalog filters and surfaces libraries matching their profile; enables opt-in discovery without exposing full catalog
  - Payment gateway integration: libraries marked `licensed` require a valid entitlement before query access; entitlement issuance pluggable (API key grant, webhook from external payment processor, future on-platform billing); details TBD
  - Author controls: library author can set or change visibility and licensing tier; history of tier changes recorded in PostgreSQL KI schema
  - All gating logic lives in the controller KI service — worker nodes are unaware of visibility rules; they push packages and serve local fallback only

- [ ] Knowledge library governance — content classification, safety, and ethics review controls for managed knowledge bases:
  - Data classification: PII/confidential detection — agent may query metadata/schema but not raw content
  - Content advisory: grounding and alignment checks (factual accuracy before ingestion)
  - Content safety: CSAM and harmful content evaluation (safe content filter on all ingestion paths)
  - Ethics alignment: positive/neutral/negative behavior classification with operator-defined context
  - Private/restricted content: opt-in isolated collection storage; excluded from default discovery
  - Prohibited topics list: operator-defined deny-list enforced at query and ingestion boundaries
- [x] **Getting Started guide and operator FAQ** — `docs/getting-started.md` and `docs/operator-faq.md` (Phase 21, commit TBD):
  - Getting Started: 12-step install-through-verify walkthrough, quick-reference command table
  - How-to: add Ollama model, add hosted API provider (OpenAI/Anthropic/etc.), register remote inference node, enable GPU (vLLM), ingest documents, push library from worker, back up, run security audit
  - FAQ: 9 common failure modes with root-cause explanations and exact fix commands (service failed, WebUI no models, LiteLLM 404/401, TLS errors, Authentik 502, duplicate model entries, remote node not showing, KI 401)
---

# 5 Open Considerations

Items requiring a decision before or during implementation.

| # | Consideration | Status | Resolution |
|---|--------------|--------|------------|
| 23 | **Reverse proxy service** — port 9443 TLS termination referenced but no proxy container (Traefik/Caddy/nginx) defined in component list or config | Resolved | Traefik selected as reverse proxy and TLS termination layer (D-011) |
| 24 | **Knowledge Index Service** — listed as core component but no image, repository, or specification exists; needs to be built or an existing tool identified | Resolved | Standalone Python/FastAPI microservice; spec in Implementation §10 (D-012) |
| 25 | **Flowise database backend** — config shows local `DATABASE_PATH=/data/flowise` (SQLite); should it share the PostgreSQL instance? | Resolved | SQLite for MVP. Migrate to PostgreSQL if multi-instance Flowise becomes a requirement. |
| 26 | **Log retention policy** — Loki storage will grow unbounded without a retention/compaction config | Resolved | `retention_period: 168h` (7 days) + compactor enabled in `configs/loki/local-config.yaml` |
| 27 | **Multi-environment support** — only one set of config values exists; no dev/staging/prod separation | Open | Addressed by configure.sh multi-env support |
| 28 | **Flowise 3.x API auth** — FLOWISE_USERNAME/PASSWORD env vars are set but API returns 401; user table is empty (Flowise 3.x requires registration flow, not just env vars). Chatflow creation via API blocked. | Open | Manual UI registration required to initialize admin account; then API key can be provisioned |
| 29 | **Inter-node DNS naming** — LAN and WAN nodes need stable DNS names (not raw IP addresses) for TLS certificate validation, LiteLLM routing, and Knowledge Index discovery. Options: mDNS (.local), split-horizon DNS, Tailscale MagicDNS, manual /etc/hosts. | Open | TBD — deferred until Phase 9 implementation |
| 30 | **macOS Podman Machine performance** — Podman on macOS runs inside a Linux VM; Apple Silicon GPU (Metal) is not exposed to the VM. Ollama native binary would bypass this but breaks the containerized deployment pattern. May need to revisit D-019 after benchmarking. | Open | Start with Podman Machine (D-019); benchmark and revisit if performance is insufficient |
| 31 | **Model storage on multi-node** — `$AI_STACK_DIR/models/` is local to each node. Models must be pulled/downloaded independently on each node, or a shared storage mechanism (NFS, rsync, object store) is needed. | Open | Manual per-node download for MVP; shared storage deferred |

---

## Session Notes — 2026-03-10

- T-072 (tool-calling): fixed llama3.1:8b Modelfile template (commit `e3fb86b`)
- T-086 (forward-auth): bootstrapped Authentik, fixed Traefik routes (openwebui hostname, prometheus router), fixed test to hit HTTPS (commit `0e96403`)
- Phase 8d: knowledge-index service built and deployed; T-062–T-065, T-067–T-068 passing (commits `fb08f2c`, `08874e6`)
- pytest: **23 passed, 2 skipped, 0 failed** (up from 16 passed, 9 skipped)
- Remaining skips: T-071 (vLLM hardware-gated), T-066 (Flowise chatflow requires manual UI setup)

## Session Notes — 2026-03-12

- T-066 (Flowise RAG): unblocked via Flowise 3.x API (commit `e3d9a16`)
  - Root causes: password policy violation (no uppercase), wrong login endpoint, missing permissions, placeholder auth in test
  - Admin registered: admin@ai-stack.local / <password from flowise_password secret>
  - API key created with chatflows:view/create/update/delete + prediction:create
  - Qdrant credential `qdrant-local` (qdrantApi) stored in Flowise DB
  - RAG chatflow `RAG Knowledge Pipeline`: conversationalRetrievalQAChain + chatOllama + qdrant + ollamaEmbedding
    (Note: retrievalQAChain is BaseLLM-only; conversationalRetrievalQAChain required for ChatOllama/BaseChatModel)
  - flowData nodes require full inputParams/inputAnchors arrays from node API definitions
- pytest: **24 passed, 1 skipped, 0 failed**
- Remaining skip: T-071 (vLLM hardware-gated only)

## Session Notes — 2026-03-19

- Fixed 6 unhealthy services: bash /dev/tcp health check pattern; distroless loki gets no HealthCmd; systemd strips double-quotes (use single-quotes) — lessons I-7 in dynamics.md
- Added HEALTH column to `scripts/status.sh`
- Built `scripts/diagnose.sh` — quick and full profiles; `--fix` auto-restart; topological service walk
- OpenWebUI connectivity resolved (3 stacked root causes):
  - (1) `openwebui_api_key` ≠ `litellm_master_key` → 401 on all model calls
  - (2) `OLLAMA_BASE_URL=/ollama` Docker Compose image default; set to `http://ollama.ai-stack:11434`
  - (3) `webui.db` first-boot persists Docker default `host.docker.internal:11434`; DB overrides env vars; patched directly
  - `_check_integrations()` added to diagnose.sh full profile; detects and auto-fixes all three
- Lessons recorded: I-8 in dynamics.md; Section 6 added to `openwebui/best_practices.md` (commits `3b78b60`)
- MCP integration scoped and added to implementation plan as Phase 7 (Knowledge Index SSE/HTTP transport, Anthropic mcp SDK)
- Deployment hardening: `configure.sh generate-secrets` auto-derives openwebui_api_key from litellm_master_key; `start.sh` recommends diagnose.sh; `undeploy.sh` backup guard
- GPU discovered: NVIDIA GeForce RTX 3070 Ti, 8 GB VRAM, CUDA 13.0
- Added Phases 8–10 to implementation plan:
  - Phase 8: Local GPU enablement — CDI, Ollama CPU pinning, models[] config, LiteLLM auto-generation, detect-hardware
  - Phase 9: Remote inference nodes — node profiles (controller/inference-worker/peer), dynamic registration, M1 Mac via Podman Machine
  - Phase 10: Full peer nodes — shared knowledge via mDNS/DNS-SD, cross-peer inference routing, node-local chat
- Decisions (informal, formalized in Phase 9a): D-016 (Ollama=CPU, vLLM=GPU), D-017 (models[] config), D-018 (node profiles), D-019 revised (bare-metal Ollama on M1), D-020 revised (static nodes[]), D-021 (Q4_K_M autoselect)
- Phase 10 decisions renumbered: D-022 (shared state scope), D-023 (knowledge sharing via D-014 local profile)
- New considerations: #29 (inter-node DNS naming), #30 (macOS Podman Machine performance), #31 (model storage on multi-node)
- 6 new deferrable items added for Phases 8–10; 1 future feature (team-shared chat/context)

## Session Notes — Phase 9b–9d

- **Phase 9b (TC25 M1)** complete — `llama3.1:8b-instruct-q4_K_M` routing verified: TC25 OK
- **Phase 9c (SOL Alienware)** complete — 9 bugs found and fixed in setup-worker.sh / configure.sh / config.json (ports, CDI, CUDA env, deps, model tag, timeout, mkdir, enable→start, env propagation); ollama 0.18.2 running with GTX 970M GPU; `llama3.2:3b-instruct-q4_K_M` verified: SOL OK
- **Phase 9d (remote node tests)** complete — `testing/layer2_remote_nodes.bats` T-090–T-094 all pass; `probe_node()` added to helpers.bash; 27/27 tests, 0 failures
- Lessons recorded: podman §5–6 (ports/stale quadlet), litellm §1–2 (secrets/daemon-reload)

## Session Notes — Phase 9a

- Alienware address confirmed: `SOL.mynetworksettings.com` / `10.19.208.113`
- **Phase 9a complete** — all 5 controller-side changes implemented and verified
- D-016 through D-021 formally written to `docs/decisions.md`
- `nodes[]` added to `configs/config.json`: workstation, macbook-m1 (TC25), alienware (SOL)
- Remote models added to `models[]`: `llama3.1:8b-instruct-q4_K_M` (macbook-m1), `llama3.2:3b-q4_K_M` (alienware)
- `configure.sh generate-litellm-config`: host models excluded from local jq block; Python heredoc appends remote entries with DNS/IP fallback resolution
- `configure.sh generate-quadlets`: `inference-worker` profile generates ollama + promtail only; controller/peer generate all services
- `configure.sh detect-hardware`: macOS/Darwin branch (sysctl hw.memsize, hw.optional.arm64); Q4_K_M model naming on all platforms
- Knowledge library governance items added to `# 4 Future Features`
- Verification: validate ✅, generate-litellm-config (remote api_base entries) ✅, generate-quadlets inference-worker ✅, detect-hardware Linux regression ✅
