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

**Decisions already made (recorded in [decisions.md](../meta_local/decisions.md)):**
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

1.1. **Record D-011 in [decisions.md](../meta_local/decisions.md)**
   - Decision: Traefik as the reverse proxy / TLS termination layer
   - Rationale: Label-based discovery fits Podman containers; native forward-auth with Authentik; dynamic configuration without restarts
   - Alternatives considered: Caddy (simpler but less dynamic), nginx (manual config)

1.2. **Record D-012 in [decisions.md](../meta_local/decisions.md)**
   - Decision: Knowledge Index Service is a standalone Python/FastAPI microservice
   - API: REST, versioned (`/v1/`), OpenAPI spec
   - Design: lightweight, internal, with short-lived query→volume routing cache
   - Rationale: routing is a distinct concern from vector search; stands alone on the critical query path; standard API enables future transport swap (gRPC) or reimplementation
   - Alternatives considered: Qdrant metadata layer, Flowise workflow, LiteLLM plugin

1.3. **Record D-013 in [decisions.md](../meta_local/decisions.md)**
   - Decision: `.ai-library` volume manifest specification
   - Structure: `manifest.yaml`, `metadata.json`, `topics.json`, `documents/`, `vectors/`, `checksums.txt`, `signature.asc`
   - `manifest.yaml` — volume identity, version, author, license, profile compatibility
   - `metadata.json` — machine-readable topic tags, embedding model, document count, vector dimensions
   - `topics.json` — human/LLM-readable topic taxonomy
   - `checksums.txt` — integrity verification (all profiles)
   - `signature.asc` — provenance verification (WAN mandatory, local optional, localhost skip)

1.4. **Record D-014 in [decisions.md](../meta_local/decisions.md)**
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
- 4 decision entries in meta_local/decisions.md
- Architecture doc reflects 14 → 16 components (Traefik + Knowledge Index)
- Implementation doc has quadlet list, dependency order, API spec, and discovery spec

### Verification
- `grep -c "traefik\|Traefik" ai_stack_architecture.md` returns ≥ 5
- §3 Component Responsibilities has 15 rows (13 original + Traefik + Knowledge Index already listed)
- D-011 through D-014 exist in meta_local/decisions.md
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

4.6. **Update deploy-stack.sh**
   - Add calls to `configure.sh validate` and `configure.sh generate-quadlets` before deployment
   - Ensure Traefik config directory is created during deployment

### Outputs
- All `"tag": "TBD"` resolved in config.json
- All env vars confirmed against upstream
- All volume paths verified
- Complete dependency graph in config.json
- Updated secrets inventory
- deploy-stack.sh calls validation pipeline

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
6.5. **Record any meta observations** in [meta_local/dynamics.md](../meta_local/dynamics.md) and [meta_local/decisions.md](../meta_local/decisions.md)
6.6. **Append row to [meta_local/review_log.md](../meta_local/review_log.md)** Review Log

### Outputs
- Checklist accurate to current state
- Considerations #23 and #24 closed
- Meta files updated

### Verification
- No open consideration blocks a Phase 5 deployment
- Checklist task states match reality

---

## Execution Notes

- **Phases 1–3 are documentation and configuration.** They can be executed in a single session with no external dependencies.
- **Phase 4 requires research** (upstream image tags, env var verification). This is the most time-consuming phase.
- **Phase 5 requires a running system** with Podman installed. Can be preceded by `scripts/install.sh` and `scripts/validate-system.sh`.
- **Phase 6 is bookkeeping** and should be done immediately after Phase 5.
- **Knowledge Index Service is custom software** — building it is a separate project tracked under Future Features / Deferrable. The spec (Phase 1) enables the rest of the stack to deploy with a placeholder; the service can be added later without re-architecting.

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
- [x] **Update `deploy-stack.sh`** — call `configure.sh validate` and `configure.sh generate-quadlets` before deployment
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

---

# 4 Future Features (architecture roadmap)

- [ ] Service registry and discovery
- [ ] Distributed vector shards (multi-node Qdrant)
- [ ] GPU scheduling and multi-tenant inference
- [ ] Automated knowledge library generation
- [ ] Multi-model A/B testing through LiteLLM
- [ ] Federated RAG across remote library nodes
- [ ] Multi-environment config support (dev/staging/prod) via configure.sh

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
