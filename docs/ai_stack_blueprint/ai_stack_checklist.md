# AI Stack — Implementation Checklist
**Last Updated:** 2026-03-10 UTC

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

## Phase 8 — Local GPU Enablement and Model Routing

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
- `nvidia-smi` shows vLLM process using GPU
- `podman exec ollama env | grep CUDA` returns `CUDA_VISIBLE_DEVICES=`
- `curl -H "Authorization: Bearer $KEY" http://litellm.ai-stack:4000/v1/models` lists both models
- `diagnose.sh --profile full` passes with both models reported

---

## Phase 9 — Remote Inference Nodes

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

- [ ] **9c.1** Create `scripts/podman/setup-worker.sh`
  - Verify Podman installed; run `detect-hardware` for model autoselect
  - Call `configure.sh generate-quadlets inference-worker` → ollama + promtail quadlets
  - Pull Ollama quantized model; `systemctl --user start ollama.service`

- [ ] **9c.2** Fill Alienware `address` / `address_fallback` in `config.json` once known

- [ ] **9c.3** Run `setup-worker.sh` on Alienware; regenerate + restart LiteLLM on controller

- [ ] **9c.4** Verify and commit Phase 9c
  - Controller LiteLLM `/v1/models` lists Alienware-hosted model
  - Completion request routed to Alienware model succeeds

---

### Phase 9d — Remote Node Tests

- [ ] **9d.1** Create `testing/layer2_remote_nodes.bats`
  - T-090: TCP reachability to M1 Ollama port (11434) from controller
  - T-091: LiteLLM `/v1/models` lists M1-hosted model
  - T-092: Completion request to M1-hosted model name succeeds and returns content
  - T-093: TCP reachability to Alienware *(skip until 9c complete)*
  - T-094: Completion request to Alienware model *(skip until 9c complete)*

- [ ] **9d.2** Add `probe_node()` helper to `testing/helpers.bash`
  - Args: `<host> <port>` — returns 0 if TCP open, 1 otherwise; used in T-090/T-093

- [ ] **9d.3** Run full test suite; verify no regressions; commit Phase 9d

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

## Phase 10 — Full Peer Nodes and Shared Knowledge

**Goal:** Multiple nodes each run the complete stack independently. Nodes share inference capacity and knowledge libraries. Chat history and user state remain node-local for MVP; team-shared context is a future extension.

**Decisions:**
- D-022: Shared state scope — inference routing and knowledge library discovery are shared across peers; chat history, user accounts, and Flowise flows remain node-local. Team-shared chat/context is deferred to a future phase.
- D-023: Knowledge sharing via D-014 `local` discovery profile — peers discover each other's knowledge libraries via mDNS/DNS-SD on LAN, or static config for WAN

**Inputs:** Phase 9 complete, multiple nodes running the stack.

### Steps

10.1. **Implement `peer` profile in `configure.sh`**
   - Deploys all services (same as controller)
   - Additionally runs `register-node.sh` on startup to share inference with other peers
   - Exposes Knowledge Index API to the network (not just localhost)

10.2. **Implement `local` discovery profile for knowledge sharing (D-014)**
   - mDNS/DNS-SD service announcement: each node's Knowledge Index advertises via `_ai-library._tcp`
   - Peers discover each other's Knowledge Index endpoints automatically
   - Query routing: Knowledge Index forwards queries to peer indexes when local collection lacks coverage
   - Volume manifest sync: peers exchange `manifest.yaml` metadata; actual vectors remain on the originating node

10.3. **WAN peer connectivity**
   - Static peer entries in `nodes[]` for WAN-connected nodes (no mDNS across WAN)
   - Mandatory TLS + mutual API key auth for inter-node calls over public internet
   - Traefik on each peer exposes Knowledge Index and inference endpoints on HTTPS
   - DNS naming strategy TBD (see Consideration #29)

10.4. **Cross-peer inference load balancing**
   - LiteLLM on each peer knows about all models across all nodes
   - Routing strategy: prefer local → then LAN peers → then WAN peers
   - Fallback: if all instances of a model are down, return clear error (not silent timeout)

10.5. **Update diagnose.sh for peer topology**
   - Full profile: show all known peers, their profiles, reachable models, knowledge indexes
   - Detect split-brain: two controllers claiming the same network

### Outputs
- Multiple nodes running full stack independently
- Knowledge library queries federated across peers
- Inference load-balanced across all available nodes
- Each node works standalone; together they share capacity

### Verification
- Ingest a document on Node A → query returns results on Node B
- Add a model on Node B → Node A's `/v1/models` lists it
- Disconnect Node B → Node A continues working with reduced model/knowledge set
- `diagnose.sh --profile full` on any peer shows complete topology

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
- **Phase 10 (Peer Nodes)** builds on Phase 9 and D-014. Most complex phase — involves distributed state, discovery protocols, and cross-node query routing.

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
- [ ] **Define library manifest YAML schema** — JSON Schema for .ai-library packages (Implementation §6)
- [x] **Create Prometheus alerting rules** — `configs/prometheus/rules/ai_stack_alerts.yml` created; 11 rules across 5 groups; prometheus.yml updated with rule_files stanza
- [x] **Document backup and restore procedures** — `scripts/backup.sh` created; full restore procedure in Implementation §8; daily systemd timer included
- [x] **Build troubleshooting guide** — Implementation §9 expanded with diagnostic commands, 13 common issues, reset and health-check oneliners
- [x] **TLS certificate setup** — `scripts/generate-tls.sh` created; generates local CA + server cert; install trust instructions included; traefik dynamic/tls.yaml updated to reference correct filenames
- [x] **Add config subdirectories to install.sh** — `configs/tls`, `configs/grafana`, `configs/prometheus`, `configs/promtail` all present in install.sh
- [x] **Define log retention/rotation policy** — Loki configured with `retention_period: 168h` (7 days) and compactor enabled in `configs/loki/local-config.yaml`
- [x] **Decide Flowise database backend** — **Decision: SQLite (local `DATABASE_PATH`)** for MVP. Rationale: Flowise stores flow definitions and API keys only — low-volume metadata unsuitable for shared PostgreSQL without added complexity. Migrate to PostgreSQL if multi-instance Flowise or shared workflow DB becomes a requirement. (Resolves Consideration #25)
- [x] **Build Knowledge Index Service** — `services/knowledge-index/` Python/FastAPI microservice; embeddings via ollama llama3.1:8b; Qdrant storage; T-062–T-065, T-067–T-068 passing (commit `fb08f2c`, 2026-03-10)
- [ ] **Implement localhost discovery profile** — filesystem scan of volumes directory, manifest parsing (see D-013)
- [ ] **Specify local and WAN discovery profiles** — mDNS/DNS-SD for local, registry/federation for WAN (see D-013)
- [ ] **Build volume ingestion pipeline** — process raw documents into `.ai-library` manifest structure; handle embedding, vector storage, and checksum generation (see D-013)
- [ ] **Integrate MCP server into Knowledge Index Service** — expose `search_knowledge` and `ingest_document` as MCP tools over HTTP/SSE transport; Anthropic `mcp[server]` Python SDK; mount at `/mcp/sse` alongside REST API; add Traefik routing and pytest coverage (see Phase 7)
- [ ] **Enable local GPU for vLLM** — CDI setup, pin Ollama to CPU, select quantized model for 8 GB VRAM, add `models[]` config section, auto-generate LiteLLM model_list (see Phase 8)
- [ ] **Add `configure.sh detect-hardware`** — detect GPU/VRAM/RAM, suggest node profile and viable models (see Phase 8)
- [ ] **Add node profile support** — `controller`, `inference-worker`, `peer` profiles; `configure.sh` selects services per profile (see Phase 9)
- [ ] **Implement dynamic node registration** — workers register with controller LiteLLM on startup; heartbeat; static fallback (see Phase 9)
- [ ] **Set up macOS M1 inference worker** — Podman Machine, Ollama container, `register-node.sh` (see Phase 9)
- [ ] **Implement `local` discovery profile for knowledge sharing** — mDNS/DNS-SD, cross-peer knowledge query routing (see Phase 10)

---

# 4 Future Features (architecture roadmap)

- [ ] Service registry and discovery
- [ ] Distributed vector shards (multi-node Qdrant)
- [ ] GPU scheduling and multi-tenant inference
- [ ] Automated knowledge library generation
- [ ] Multi-model A/B testing through LiteLLM
- [ ] Federated RAG across remote library nodes
- [ ] Multi-environment config support (dev/staging/prod) via configure.sh
- [ ] Team-shared chat/context state — shared Postgres or sync protocol so chat history, user accounts, and conversation context are available across peer nodes (extends Phase 10 D-022)
- [ ] Knowledge library governance — content classification, safety, and ethics review controls for managed knowledge bases:
  - Data classification: PII/confidential detection — agent may query metadata/schema but not raw content
  - Content advisory: grounding and alignment checks (factual accuracy before ingestion)
  - Content safety: CSAM and harmful content evaluation (safe content filter on all ingestion paths)
  - Ethics alignment: positive/neutral/negative behavior classification with operator-defined context
  - Private/restricted content: opt-in isolated collection storage; excluded from default discovery
  - Prohibited topics list: operator-defined deny-list enforced at query and ingestion boundaries

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
  - Admin registered: admin@ai-stack.local / FlowAdmin2026!
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
