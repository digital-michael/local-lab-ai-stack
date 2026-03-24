# Project Decisions — llm-agent-local-2
**Last Updated:** 2026-03-24 UTC (D-034 added)
**Target Audience:** LLM Agents

---

## Purpose

This file records architecture decisions made during work on this project. Each entry follows the ADR (Architecture Decision Record) format: Decision, Context, Options Considered, Rationale, Driver, Trigger, Commit.

---

## Decision Log

### D-001 — Three-Document Split

| Field | Value |
|---|---|
| **Decision** | Split the monolithic architecture document into three: architecture (design), implementation (procedures), configuration (tunable values) |
| **Context** | The original document tried to serve three audiences — someone understanding the system, someone deploying it, and someone tuning it. Sections were fighting each other, and updates to one concern risked breaking another. |
| **Options Considered** | (1) Keep one doc with clear section boundaries. (2) Split into two (design vs. operations). (3) Split into three by concern. |
| **Rationale** | Three-way split maps cleanly to single-source-of-truth: each fact lives in exactly one file. Deployment procedures don't interleave with port numbers. Schema rationale doesn't crowd out architecture diagrams. |
| **Driver** | Joint |
| **Trigger** | Pattern recognition — the agent saw repeated cross-concern conflicts while editing; the human validated the separation principle. |
| **Commit** | `1de9dd4` |

---

### D-002 — JSON Config as Machine-Readable Single Source of Truth

| Field | Value |
|---|---|
| **Decision** | Use `configs/config.json` as the machine-readable SSOT for all service definitions, with `configure.sh` as the CRUD interface. |
| **Context** | Configuration values were scattered across markdown docs and scripts. No single place to read or write a port number, image tag, or secret name. |
| **Options Considered** | (1) YAML config files. (2) Environment `.env` files per service. (3) A single JSON file with a shell-based CRUD tool. |
| **Rationale** | JSON is natively parseable by `jq` (already a project dependency), avoids the quoting pitfalls of `.env` files, and a single file keeps the SSOT principle intact. The shell wrapper (`configure.sh`) provides validation and generation, keeping the JSON clean. |
| **Driver** | Joint |
| **Trigger** | Blocker — couldn't generate quadlets or provision secrets without a single authoritative source for service definitions. |
| **Commit** | `75caab2`, `c4c8bfd` |

---

### D-003 — Component Library: Three Files Per Component

| Field | Value |
|---|---|
| **Decision** | Every component gets a directory under `docs/library/framework_components/` with exactly three files: `best_practices.md`, `security.md`, `guidance.md`. |
| **Context** | Needed a place for component-specific knowledge that was normative (the agent must follow it) but separate from the system-level architecture docs. |
| **Options Considered** | (1) A single `components.md` file with sections. (2) One file per component. (3) Three files per component, split by concern. |
| **Rationale** | The three-file split separates industry knowledge (best_practices) from project opinions (guidance) from hardening rules (security). This lets us update vendor recommendations without touching project decisions, and vice versa. It also makes compliance checkable — an agent can read just `security.md` for a focused review. |
| **Driver** | Joint |
| **Trigger** | Scaling problem — component knowledge didn't fit in the architecture doc and had no home. |
| **Commit** | `c94029d` |

---

### D-004 — README-agent.md as Directory-Scoped Agent Governance

| Field | Value |
|---|---|
| **Decision** | Files named `README-agent.md` are directive documents for LLM agents, scoped to their directory and all descendants. Most-specific wins; parent rules apply where child doesn't override. |
| **Context** | We had created `README-agent.md` files at two levels (repo root, framework_components) but never formalized what the convention *means*. The human asked: "should we mention this as a default adherence/guidance mechanism?" |
| **Options Considered** | (1) Informal convention, no rules. (2) A single top-level agent config file. (3) Directory-scoped inheritance with explicit rules. |
| **Rationale** | Directory-scoped inheritance mirrors how `.gitignore`, `.editorconfig`, and similar tools work — familiar pattern, scales naturally as the repo grows, and allows governance to be layered without a monolithic rule file. |
| **Driver** | Human-initiated, jointly refined |
| **Trigger** | The human recognized an implicit pattern and asked whether it should be explicit. A meta-observation about our own tooling. |
| **Commit** | `a9b8040` |

---

### D-005 — Audience Separation (Human vs. Agent Docs)

| Field | Value |
|---|---|
| **Decision** | `README.md` targets humans. `README-agent.md` targets LLM agents. Never mix audiences. |
| **Context** | Early on, architecture docs included both human-readable narrative and agent-specific directives in the same files, creating ambiguity about tone and audience. |
| **Rationale** | Agents need precision, cross-references, and compliance rules. Humans need narrative, context, and onboarding. Mixing audiences dilutes both. Separation lets each document optimize for its reader. |
| **Driver** | Joint |
| **Trigger** | Observation — the architecture doc header says "LLM-Agent Focused" but the README.md is clearly for humans. The split crystallized when we created the first `README-agent.md`. |
| **Commit** | `52f612f`, `3b07fef` |

---

### D-006 — Shell Script Standards (--help, main(), set -euo pipefail)

| Field | Value |
|---|---|
| **Decision** | All scripts must support `--help`/`-h`, use the `main()` function pattern, and start with `set -euo pipefail`. Codified in shell-scripting guidance. |
| **Context** | Scripts were being created ad hoc. Needed a baseline for consistency, safety, and discoverability. |
| **Rationale** | `--help` makes scripts self-documenting. `main()` prevents global-scope side effects. `set -euo pipefail` catches errors early instead of silently continuing. These are cheap conventions with outsized reliability payoff. |
| **Driver** | Agent-proposed, human-approved |
| **Trigger** | The agent noticed inconsistency across scripts while adding `--help` support. Proposed codifying it as guidance. |
| **Commit** | `bd4be38`, `0685c46` |

---

### D-007 — Checklist as Central Task Tracker

| Field | Value |
|---|---|
| **Decision** | Use `ai_stack_checklist.md` as the master task tracker, organized by blockers, deferrables, and future features. |
| **Context** | Implementation tasks were embedded in the architecture doc's "Implementation Tracking" section. As the list grew, it cluttered the design document. |
| **Rationale** | A dedicated checklist file keeps task state separate from design rationale. It can be updated frequently without touching the architecture doc. The blocker/deferrable/future split provides clear prioritization. |
| **Driver** | Joint |
| **Trigger** | The architecture doc was getting unwieldy with inline task tracking. |
| **Commit** | `75caab2` |

---

### D-008 — meta.md as Collaboration & Decision Record

| Field | Value |
|---|---|
| **Decision** | Create `docs/meta.md` as a collaboration and decision record, targeting LLM agents, with auto-identification directives. |
| **Context** | Decisions were being made through conversation but only recorded indirectly in commit messages. No record of *why* we decided things, who drove them, or what patterns our collaboration produces. |
| **Rationale** | Commit messages capture *what* changed but not the decision process. A meta document lets the agent learn from past collaboration patterns and apply them forward. It also creates a feedback loop — by recording how we work, we can improve how we work. |
| **Driver** | Human-initiated |
| **Trigger** | The human recognized that our process itself is worth documenting and optimizing. A lateral leap from "let's document decisions" to "let's document how we decide." |
| **Commit** | `edc14d9` |

---

### D-009 — Meta File Separation of Concerns

| Field | Value |
|---|---|
| **Decision** | Split meta.md into four files by concern: `meta.md` (active directives/workflow), `meta_decisions.md` (decision record), `meta_dynamics.md` (collaboration dynamics + lateral thinking), `meta_metrics.md` (review log + derived metrics). |
| **Context** | meta.md was ~270 lines and growing. It mixed always-read directives with append-only historical data. Different sections had different access patterns (read every session vs. reference on demand vs. append at triggers) and different growth rates. |
| **Options Considered** | (1) Keep one file, manage length. (2) Split into two (directives vs. data). (3) Split by concern into four files matching access pattern and growth rate. |
| **Rationale** | Applied separation of concerns: each file has a single reason to change, a clear access pattern, and a predictable growth trajectory. meta.md stays small as the always-read "operating system." Historical/accumulating content moves to files that are read when the workflow says to read them, not on every session. This is the same principle that drove D-001 (three-doc split) and D-003 (three files per component) — the human recognizes it as a reusable pattern. |
| **Driver** | Human-initiated, jointly refined |
| **Trigger** | The agent flagged meta.md's length as a scaling pressure point; the human proposed the split and named the underlying principle ("applied separation of concerns"). |
| **Commit** | `257fdcd` |

---

### D-010 — Meta Framework Extraction

| Field | Value |
|---|---|
| **Decision** | Extract the portable collaboration framework (meta.md, meta_decisions.md, meta_dynamics.md, meta_metrics.md) into a standalone git repo (`meta-framework`). Project-specific content (decision entries, eureka moments, lateral ideas, review log rows) stays local in `docs/meta_local/`. The framework is symlinked into consuming projects at `docs/meta/`. |
| **Context** | The meta files described how we work together, not what we work on. Three of four files were entirely relationship-scoped; the fourth (meta_decisions.md) mixed a portable framework with project-specific entries. Keeping them in the project repo would couple the collaboration protocol to a single project and prevent reuse. |
| **Options Considered** | (1) Keep meta in this repo, prefix project-coupled entries with "repo-". (2) Move everything to an external repo as a collaboration journal. (3) Extract as a framework repo with distilled portable patterns; project-specific instances stay local. |
| **Rationale** | Option 3 (framework + distillation) maintains a clean separation: the framework defines the protocol, each project instantiates it locally. Promotion from local to framework is the feedback mechanism — project-local insights earn a place in the framework when they prove reusable across contexts. The "repo-" prefix (option 1) flags noise rather than removing it. A full journal (option 2) carries project-specific entries that are meaningless in other contexts. |
| **Driver** | Human-initiated, jointly refined (Level 4 discussion) |
| **Trigger** | The human observed that meta files aren't tightly coupled to this repo but to the working relationship. Applied separation of concerns to the meta system itself — separating the protocol from its instances. |
| **Commit** | `eaeec5d` |

---

### D-011 — Traefik as Reverse Proxy and TLS Termination

| Field | Value |
|---|---|
| **Decision** | Use Traefik as the reverse proxy and TLS termination layer for all user-facing services. Traefik sits at the network edge, terminates TLS, and routes traffic to OpenWebUI, Grafana, Flowise, and Authentik. |
| **Context** | Consideration #23 — the architecture referenced a "TLS reverse proxy" on port 9443 but never specified which reverse proxy. Multiple candidates existed; a decision was needed before deployment. |
| **Options Considered** | (1) **Traefik** — label-based dynamic discovery, native forward-auth with Authentik, file-based dynamic config for Podman. (2) **Caddy** — simpler config, automatic HTTPS, but less dynamic routing and no native label discovery. (3) **nginx** — industry standard but manual configuration, no dynamic discovery, higher operational friction. |
| **Rationale** | Traefik's label-based discovery fits the Podman container model — new services are automatically routed without config file changes. Native forward-auth middleware integrates cleanly with Authentik for SSO. File-based dynamic configuration (since Podman lacks Docker's socket API) allows config reload without restarts. The operational cost is slightly higher than Caddy at initial setup but significantly lower at steady-state. |
| **Driver** | Human-selected, agent-evaluated |
| **Trigger** | Blocker — reverse proxy selection was required before deployment and TLS configuration could proceed. |
| **Commit** | `4561edf` |

---

### D-012 — Knowledge Index Service as Standalone Microservice

| Field | Value |
|---|---|
| **Decision** | The Knowledge Index Service is a standalone Python/FastAPI microservice with a REST API (versioned at `/v1/`), backed by PostgreSQL for metadata and Qdrant for vector search. It provides query→volume routing with a short-lived cache. |
| **Context** | Consideration #24 — the architecture described a "Knowledge Index Service" for library indexing and retrieval but gave no implementation spec. The service needed a clear identity: is routing logic embedded in another component or standalone? |
| **Options Considered** | (1) **Qdrant metadata layer** — use Qdrant's payload filtering for routing. Tight coupling to Qdrant; breaks if vector DB swaps. (2) **Flowise workflow** — implement routing as a Flowise flow. Mixes orchestration with routing; not independently testable. (3) **LiteLLM plugin** — extend LiteLLM with routing middleware. Couples routing to the model gateway; wrong separation of concerns. (4) **Standalone FastAPI microservice** — independent service with its own API, caching, and dependencies. |
| **Rationale** | Routing is a distinct concern from vector search, model inference, and workflow orchestration. A standalone service can be tested, deployed, cached, and replaced independently. The REST API (versioned, OpenAPI-documented) enables future transport swaps (gRPC) or reimplementation without affecting consumers. FastAPI is a pragmatic MVP choice — lightweight, well-documented, async-native. |
| **Driver** | Human-directed, agent-proposed alternatives |
| **Trigger** | Blocker — the Knowledge Index was referenced throughout the architecture but had no implementation specification. |
| **Commit** | `4561edf` |

---

### D-013 — Volume Manifest Specification (.ai-library)

| Field | Value |
|---|---|
| **Decision** | Define a `.ai-library` package format for knowledge library volumes with the following structure: `manifest.yaml` (identity/version/author/license/profile compatibility), `metadata.json` (machine-readable topic tags, embedding model, document count, vector dimensions), `topics.json` (human/LLM-readable topic taxonomy), `documents/` (source documents), `vectors/` (pre-computed embeddings), `checksums.txt` (integrity verification), `signature.asc` (provenance verification). |
| **Context** | The architecture described library packages but the format was underspecified. A concrete manifest was needed for the Knowledge Index Service to discover, validate, and ingest volumes. |
| **Options Considered** | (1) Ad hoc directory structure with no manifest. (2) Single `manifest.yaml` covering all metadata. (3) Split manifest: `manifest.yaml` for identity, `metadata.json` for machine-readable data, `topics.json` for human-readable taxonomy, separate integrity/provenance files. |
| **Rationale** | Option 3 applies separation of concerns: identity metadata (stable) is separate from topic taxonomy (changes with content) and machine-readable indexes (changes with re-embedding). `checksums.txt` and `signature.asc` serve orthogonal verification purposes — integrity (all profiles) vs. provenance (profile-dependent). Split files enable independent tooling: a CLI can validate checksums without parsing YAML, a registry can index metadata.json without downloading vectors. |
| **Driver** | Joint |
| **Trigger** | Design dependency — the Knowledge Index Service (D-012) and discovery profiles (D-014) both require a concrete manifest specification. |
| **Commit** | `4561edf` |

---

### D-014 — Discovery Profiles: localhost, local, WAN

| Field | Value |
|---|---|
| **Decision** | Define three discovery profiles that govern how knowledge library volumes are found, trusted, and verified. Profiles are a property of both the deployment instance (which mechanisms it activates) and the volume (which profiles it supports). |
| **Context** | The architecture described a knowledge library system and distributed nodes but never specified how volumes are discovered across deployment contexts. A single trust model can't serve all scenarios: a developer's laptop has different security requirements than a WAN-federated node. |
| **Options Considered** | (1) Single discovery mechanism (filesystem scan only). (2) Two tiers (local vs. remote). (3) Three profiles mapped to network topology and trust boundaries. |
| **Rationale** | Three profiles map cleanly to real deployment contexts: **localhost** (filesystem scan, implicit trust — the operator placed the files there), **local** (mDNS/DNS-SD discovery, trust by network membership + optional signature), **WAN** (registry/federation protocol, mandatory signature verification). Each profile has escalating verification requirements that match escalating trust boundaries. MVP implements localhost only; local and WAN are specified but deferred. |
| **Driver** | Joint |
| **Trigger** | Design dependency — distributed node architecture (§7) and volume manifest (D-013) both reference discovery and trust without specifying the model. |
| **Commit** | `4561edf` |

---

### D-015 — MCP Transport: HTTP/SSE (not stdio)

| Field | Value |
|---|---|
| **Decision** | Use HTTP/SSE transport for MCP via the Anthropic `mcp[server]` Python SDK. MCP SSE endpoint mounted at `/mcp/sse` on the Knowledge Index Service; message channel at `/mcp/messages`. |
| **Context** | Phase 7 adds MCP capability to the Knowledge Index Service so agent clients (Claude Desktop, Cursor, VS Code Copilot) can call `search_knowledge` and `ingest_document` directly. Two transport options exist in the `mcp` SDK: stdio (subprocess) and HTTP/SSE. |
| **Options Considered** | (1) **stdio** — simplest setup, zero HTTP overhead, but requires an agent-side subprocess. Incompatible with containerized services behind a reverse proxy. (2) **HTTP/SSE** — client connects via HTTP GET to establish SSE stream; messages POSTed back. Traefik-compatible, network-accessible, works with any MCP client that supports SSE transport. |
| **Rationale** | stdio is fundamentally incompatible with the containerized deployment model — an agent cannot spawn the knowledge-index container as a subprocess. HTTP/SSE fits the existing Traefik-fronted architecture: a new `/mcp` PathPrefix rule routes MCP traffic to the same backend container at port 8100. All MCP-supporting clients (Claude Desktop, Cursor, VS Code Copilot) support SSE transport. REST API remains intact alongside MCP — additive, not replacing. |
| **Driver** | Agent-proposed, architecture-constrained |
| **Trigger** | Phase 7 implementation dependency — transport choice required before implementing the MCP layer. |
| **Commit** | `0b997bc` |

---

### D-016 — Ollama Runs CPU-Only; vLLM Holds GPU Exclusively

| Field | Value |
|---|---|
| **Decision** | Run Ollama with `CUDA_VISIBLE_DEVICES=""` so it uses CPU-only inference. Dedicate the NVIDIA GPU exclusively to vLLM for high-quality, quantized GPU inference. |
| **Context** | Phase 8 revealed that both Ollama and vLLM will claim the NVIDIA GPU if both are running. Ollama's CUDA path is opportunistic — it grabs whatever device is available. Running both on GPU causes VRAM contention and unpredictable failures. |
| **Options Considered** | (1) Let both share the GPU via CUDA MPS. (2) Run vLLM CPU-only and Ollama on GPU. (3) Ollama CPU-only, vLLM GPU-exclusive. |
| **Rationale** | Option 3 matches workload characteristics: Ollama serves lightweight CPU-bound models that don't require GPU acceleration; vLLM serves quantized models where GPU parallelism is essential. CPU isolation is enforced by environment variable, not resource limits — simpler and more reliable than CUDA MPS. |
| **Driver** | Agent-proposed, Phase 8 implementation |
| **Trigger** | VRAM contention observed when both services started simultaneously. |
| **Commit** | `795ac96` |

---

### D-017 — `models[]` in config.json Is the LiteLLM Model Source of Truth

| Field | Value |
|---|---|
| **Decision** | Define a top-level `models[]` array in `config.json` as the authoritative list of available inference models. `configure.sh generate-litellm-config` derives `configs/models.json` (the LiteLLM router config) entirely from this array. |
| **Context** | Before Phase 8, model routes were manually edited in `configs/models.json`. This broke the SSOT principle established in D-002 — the same fact (which models exist, with which backends) lived in two places. |
| **Options Considered** | (1) Keep models.json as a manually maintained file. (2) Generate models.json from an environment variable list. (3) Extend config.json with a `models[]` array and generate models.json from it. |
| **Rationale** | Option 3 extends the existing SSOT architecture (D-002) consistently. `models[]` co-locates model definitions with service definitions in one file, making the full stack reviewable in one place. The generator (`configure.sh generate-litellm-config`) is deterministic — the same config always produces the same models.json. |
| **Driver** | Agent-proposed, Phase 8 implementation |
| **Trigger** | Discovery that models.json was manually maintained and could diverge from config.json. |
| **Commit** | `795ac96` |

---

### D-018 — Node Profiles: `controller`, `inference-worker`, `knowledge-worker`, `peer`

| Field | Value |
|---|---|
| **Decision** | Define four node profiles stored as `node_profile` in `config.json`: `controller` (full stack, all services, observability hub), `inference-worker` (Ollama + Promtail only), `knowledge-worker` (inference-worker + Knowledge Index + local Qdrant — contributes inference and local knowledge domains), `peer` (full stack, self-contained, for disconnected/field deployments where no controller is reachable). |
| **Context** | Phase 9 introduced three profiles (`controller`, `inference-worker`, `peer`). Phase 10 adds `knowledge-worker` after hardware analysis showed TC25 (16 GB unified RAM) and SOL (31 GB RAM) lack the memory for a full peer stack (~24 GB overhead before inference) but can comfortably run inference + Knowledge Index + Qdrant (~10–12 GB total). The original `peer` profile was designed for full autonomy; `knowledge-worker` fills the practical gap between inference-only and full-peer. |
| **Options Considered** | (1) Three profiles (original): `inference-worker` cannot contribute knowledge. (2) Redefine `peer` as `knowledge-worker`: conflates two distinct roles — knowledge contribution on LAN vs. full autonomy for disconnected deployment. (3) Four profiles: adds `knowledge-worker` as a distinct role with its own service set and hardware floor. |
| **Rationale** | Four profiles map cleanly to real deployment scenarios: `controller` is the coordination hub (aggregates inference, holds custody library store, runs all UI); `inference-worker` is the lightest footprint (models only); `knowledge-worker` contributes both inference and local knowledge domains, syncing library packages to the controller; `peer` is reserved for future disconnected/field deployments where no controller is reachable. `generate-quadlets` enforces the profile at generation time. |
| **Driver** | Joint — Phase 10 topology analysis |
| **Trigger** | Hardware analysis of TC25 and SOL showed neither fits the full-peer memory floor; `knowledge-worker` fills the practical gap. |
| **Commit** | `ecbc5e3` (original Phase 9), Phase 10 revision |

---

### D-019 — M1 MacBook Uses Bare-Metal Ollama (Podman Machine Deferred)

| Field | Value |
|---|---|
| **Decision** | Deploy Ollama as a bare-metal macOS process on the M1 MacBook (TC25) using the native Ollama binary. Podman Machine on macOS is explicitly deferred. |
| **Context** | The M1's Metal GPU provides significant inference acceleration. Podman Machine on macOS runs Ollama inside a Linux VM, which cannot access Apple Silicon Metal. The original Phase 9 design assumed Podman Machine for consistency with the Linux containers pattern. |
| **Options Considered** | (1) Podman Machine on macOS (consistent containerization, no Metal GPU). (2) Bare-metal Ollama binary (native Metal GPU, breaks containerization consistency). (3) Docker Desktop with Metal passthrough (proprietary, licensing concerns). |
| **Rationale** | The M1's primary value as an inference worker is its Metal GPU, which delivers meaningful inference speedup on quantized models. Sacrificing Metal for container consistency defeats the purpose of using this hardware. Bare-metal Ollama is the officially supported path for Apple Silicon and is mature. Podman Machine benchmark deferred to a later phase when Metal passthrough support improves. |
| **Driver** | Hardware constraint — Metal GPU inaccessible inside Podman Machine VM |
| **Trigger** | Design review during Phase 9 planning — original D-019 assumed Podman Machine without evaluating GPU access. |
| **Commit** | `ecbc5e3` |

---

### D-020 — Static `nodes[]` Config for Phase 9 (Dynamic Registration Deferred)

| Field | Value |
|---|---|
| **Decision** | Add a static `nodes[]` array to `config.json` with one entry per remote node. Addresses are declared explicitly (`address` for DNS, `address_fallback` for IPv4/IPv6). Dynamic registration (workers auto-registering with the controller) is deferred as a Phase 9 TODO. |
| **Context** | Phase 9 introduces remote inference nodes. Two models for node discovery were considered: static config (operator declares each node manually) vs. dynamic registration (nodes announce themselves to the controller). |
| **Options Considered** | (1) Dynamic registration — nodes `POST /model/new` to LiteLLM on startup; controller removes stale entries on heartbeat failures. (2) Static config — `nodes[]` array in config.json; operator edits manually. (3) Hybrid — static fallback with optional dynamic override. |
| **Rationale** | Static config is appropriate for Phase 9: the node topology is small (3 nodes), known in advance, and stable. Dynamic registration adds complexity (heartbeat protocol, stale-entry cleanup, race conditions on startup ordering) that is not justified by a 3-node static topology. The `nodes[]` schema is designed so dynamic registration can be layered on later without breaking the static config format. |
| **Driver** | Agent-proposed, complexity vs. benefit tradeoff |
| **Trigger** | Phase 9 planning — dynamic registration was the original design; revised after reviewing the actual topology size. |
| **Commit** | `ecbc5e3` |

---

### D-021 — Quantized Models (Q4_K_M) Preferred; `detect-hardware` Autoselects Tier

| Field | Value |
|---|---|
| **Decision** | Prefer Q4_K_M quantized models on all inference worker nodes. `configure.sh detect-hardware` autoselects the appropriate model tier based on available VRAM (Linux/NVIDIA) or unified RAM soft-target (~40%, macOS Apple Silicon). |
| **Context** | Phase 8 used AWQ quantization labels from HuggingFace models run via vLLM. Phase 9 adds Ollama-based inference workers where the dominant Ollama model format uses GGUF with Q4_K_M quantization. The recommend model sizes needed updating and cross-platform consistency. |
| **Options Considered** | (1) FP16 models — highest quality, requires 14–16 GB VRAM for 7B models. (2) AWQ models — GPU-optimized, HuggingFace ecosystem. (3) Q4_K_M GGUF — Ollama native, works CPU and GPU, broad model availability. |
| **Rationale** | Q4_K_M offers a good quality/size tradeoff for both CPU and GPU inference and is the most widely available quantization format in the Ollama model library. GGUF/Q4_K_M runs on both Linux GPU workers (Ollama CPU path) and macOS Metal (Ollama native). This unifies the model recommendation logic across platforms. Tier thresholds: ≥8 GB VRAM/≥20 GB RAM → 8B Q4_K_M; 4–8 GB → 7B Q4_K_M; 3–4 GB → 3B Q4_K_M; <3 GB → 1.5B Q8_0. |
| **Driver** | Agent-proposed, Phase 9 cross-platform consistency |
| **Trigger** | Adding macOS inference workers exposed the gap between AWQ (HuggingFace/vLLM path) and GGUF/Q4_K_M (Ollama path). |
| **Commit** | `ecbc5e3` |

---

### D-022 — Shared State Scope: Controller as Custodian, Workers as Contributors

| Field | Value |
|---|---|
| **Decision** | The controller acts as the custodian and serving hub for all knowledge library domains. Knowledge-workers contribute local library packages; inference routing is shared via LiteLLM model registration. Chat history, user accounts, and Flowise flows remain node-local. Team-shared chat is deferred to a future extension phase. |
| **Context** | Phase 10 introduces `knowledge-worker` nodes that create and curate knowledge library domains. The previous model (original D-023) relied on manifest-only federation with live proxy calls to the origin node — meaning a worker had to be online for its knowledge to be served. This was unreliable and conflicted with the goal of libraries as durable, growing assets. |
| **Options Considered** | (1) Manifest-only federation: proxy all queries to origin worker. Origin must be online; no provenance tracking. (2) Full vector replication: all nodes hold all vectors. Storage cost O(n²); sync complexity. (3) Custody model: controller holds an ingested copy of all synced library packages; workers are authors, controller is the serving custodian. |
| **Rationale** | Option 3 (custody) matches the goal of libraries as durable assets. Once a worker pushes a library package to the controller, the controller ingests it into its own Qdrant collection and records provenance in PostgreSQL. The library is served by the controller independently of whether the origin worker is online. This makes libraries resilient, enables provenance tracking, and creates the foundation for versioning, access control, and future licensing. User sessions and chat history remain write-heavy and user-specific — not shared. |
| **Driver** | Joint — library-as-asset vision |
| **Trigger** | Phase 10 topology design and discussion of library provenance, safeguarding, and eventual-consistency distribution model. |
| **Commit** | *(Phase 10)* |

---

### D-023 — Library Custody Sync: Workers Push, Controller Ingests

| Field | Value |
|---|---|
| **Decision** | Knowledge-workers push `.ai-library` packages to the controller via HTTPS (`POST /v1/libraries`). The controller verifies the package checksum, re-embeds content into its own Qdrant collection, records authorship, version, and origin node in its PostgreSQL KI schema, and marks the library as "in custody." The controller serves the library from that point forward, independent of the origin worker's availability. Workers retain their local copy; version updates are pushed the same way. Unsynced or draft libraries remain accessible via proxy fallback to the origin worker. |
| **Context** | D-014 defined three discovery profiles (`localhost`, `local`, `WAN`) and deferred implementation. The original D-023 committed to the `local` profile using mDNS/DNS-SD with manifest-only federation and live query proxying. Phase 10 analysis revealed that live proxying forces origin workers to remain online to serve knowledge — undermining the durability and asset-value model. The custody model supersedes manifest federation for the Phase 10 MVP. |
| **Options Considered** | (1) mDNS/DNS-SD + live proxy (original): zero-config discovery, but origin must be online; no provenance tracking. (2) Full replication: all nodes hold all vectors; high storage cost and sync complexity. (3) Custody push: workers push complete packages to controller; controller ingests and serves independently; workers are authors, controller is custodian and distributor. |
| **Rationale** | Option 3 aligns with the library-as-asset vision (D-025). The `.ai-library` package format (D-013) already carries the required fields: `signature.asc` anchors authorship, `checksums.txt` enables integrity verification, `manifest.yaml` carries `version`/`author`/`license`. Custody push requires no multicast networking (WAN-friendly), is auditable, and enables provenance to be tracked independently of the contributing node's uptime. The `_ai-library._tcp` mDNS discovery is deferred — static `nodes[]` config is sufficient for the 3-node topology. |
| **Driver** | Architecture constraint and library-as-asset vision |
| **Trigger** | Phase 10 design: live proxying to origin workers was identified as a reliability gap and an obstacle to durable library assets. |
| **Commit** | *(Phase 10)* |

---

### D-024 — `knowledge-worker` Profile: Services, Database, and Hardware Floor

| Field | Value |
|---|---|
| **Decision** | The `knowledge-worker` profile deploys four services: Ollama (inference), Promtail (log shipper), Knowledge Index Service (SQLite metadata store), and local Qdrant (vector storage). `configure.sh generate-quadlets` enforces this service set when `node_profile` is `knowledge-worker`. The Knowledge Index on a knowledge-worker uses `DATABASE_URL=sqlite:///...` rather than PostgreSQL. Minimum hardware floor: 10 GB RAM, 4 CPU cores, 50 GB disk. Comfortable target: 16 GB RAM, 50–200 GB disk. |
| **Context** | Phase 10 hardware analysis: TC25 (16 GB unified RAM) and SOL (31 GB RAM, 3 GB VRAM) can contribute inference and local knowledge without bearing the ~18–24 GB overhead of the full controller stack. The current `app.py` has zero database code — it uses an in-memory `_doc_collection` dict despite `DATABASE_URL=postgresql://...` in config.json. The SQLite switch is a zero-cost spec change now, not a migration. |
| **Options Considered** | (1) PostgreSQL on workers: creates a network dependency or requires a second Postgres instance per worker (~1 GB overhead, admin complexity). (2) No database (in-memory only): state lost on restart; libraries must be re-ingested on every boot. (3) SQLite: single-file, zero-admin, single-writer, full transactional integrity. Backup is a file copy. |
| **Rationale** | SQLite matches the workload exactly: single-writer (one KI process per node), local metadata only, append-heavy. The custody model (D-023) means cross-node sharing happens via push to the controller — not via database sync — so there is no multi-writer scenario on the worker's SQLite. Controller KI continues to use the existing PostgreSQL instance (co-tenant with Authentik and LiteLLM); this is a co-tenancy benefit, not extra cost. |
| **Driver** | Joint — Phase 10 topology analysis |
| **Trigger** | Hardware floor analysis for TC25 and SOL; discovery that app.py has no database code yet makes the SQLite spec change zero-cost now vs. a migration later. |
| **Commit** | *(Phase 10)* |

---

### D-025 — Library Custody Model: Controller as Custodian, Workers as Authors

| Field | Value |
|---|---|
| **Decision** | The controller is the custody and serving hub for all knowledge library domains. It holds ingested copies of all synced libraries, records provenance in its PostgreSQL KI schema, and exposes a `/v1/catalog` API listing all libraries with author, origin node, version, and custody status. Knowledge-workers are authors and contributors: they create, curate, and push library packages. The `.ai-library` package format (D-013) is the exchange unit: `signature.asc` anchors authorship, `manifest.yaml` carries `version`/`author`/`license`, and `checksums.txt` provides integrity. The controller never holds the signing key — provenance is verifiable by anyone with the author's public key. |
| **Context** | Libraries represent accumulating intellectual value: curated knowledge, embeddings, topic taxonomies. The original D-023 model (live query proxy) treated libraries as transient distributed state. The custody model treats them as durable digital assets — created by contributors, safeguarded by the controller, eventually distributable or licensable. This framing was explicit in Phase 10 design: "a mechanism to unify, safeguard, and later monetize." |
| **Options Considered** | (1) Live proxy model: no custody; origin must be online; no provenance tracking. (2) Shared filesystem/NFS: easy replication but no provenance, no access control, no per-library permissions. (3) Custody push + provenance registry: controller is custodian and registry; workers are signed contributors; the signature is the ownership anchor even after custody transfer. |
| **Rationale** | Option 3 is the only model that supports the full lifecycle: author → curate → push → serve → version → access-control → license → monetize. The `.ai-library` format already contains all necessary fields — D-013 was designed with this intent. Monetization is a future phase, but the architecture must not foreclose it. Tracking author + version + signature from the first push ensures provenance is never reconstructed retroactively. The controller's PostgreSQL KI schema grows to include: `library_id`, `name`, `version`, `author`, `origin_node`, `signature_hash`, `checksum_hash`, `synced_at`, `visibility` (private/shared/licensed). |
| **Driver** | Human-initiated vision; joint design |
| **Trigger** | Phase 10 architecture discussion — framing libraries as digital artifacts with lifecycle value, not just distributed state. |
| **Commit** | *(Phase 10)* |

---

### D-026 — Node Registry: Phase A — Per-Node Config Files, Status, and Alias (Supersedes D-020)

| Field | Value |
|---|---|
| **Decision** | Extract `nodes[]` out of `config.json` into individual per-node JSON files under `configs/nodes/<alias>.json`. Add `status` and `alias` fields to each node record. Scripts discover nodes by globbing `configs/nodes/*.json` and filtering on `status`. `config.json` retains topology-level fields (network, services, models) but no longer contains the node list. |
| **Context** | D-020 committed to a flat `nodes[]` array inside `config.json` as a minimum-viable solution for Phase 9. The array now has three entries (workstation, macbook-m1, alienware) and already requires edits whenever a node's address, status, or models change. The monolithic file mixes two distinct concerns: stack topology (stable, operator-maintained) and node registry (dynamic, per-machine). They have different change rates and different owners. Additionally, the current schema exposes physical hostnames (`TC25`, `SOL`) in status output, log labels, and Grafana panels — making it brittle when hardware changes. |
| **Options Considered** | (1) Keep `nodes[]` in `config.json`; add status/alias fields inline. Easy but perpetuates the mixed-concern problem. (2) Extract to `configs/nodes/<alias>.json` per node. Atomic isolation, free per-node gitignore or encryption, path-stable identity (alias never changes even if hardware does). (3) Extract to a single `configs/nodes.json`. Separate file but same array problem at smaller scale. |
| **Rationale** | Option 2 gives true atomic isolation: adding a node never touches other node files. The alias becomes the stable identity used everywhere — status output, log labels, LiteLLM routing, Grafana panels. Hostnames (`TC25.mynetworksettings.com`) remain in the file as `address` but are never surfaced to users or tools. The file layout is also the correct Phase B foundation: a registration service can write a new `<alias>.json` on first contact using the same schema, and scripts require no changes. |
| **Status Fields** | `active` — fully participating (deploy, register, route); `inactive` — known but suspended (graceful shutdown, excluded from routing, deploy no-ops cleanly); `unhealthy` — registered but missing heartbeat or failing health checks (set automatically by monitoring, not by the node itself); `prohibited` — administratively blocked (deploy and registration rejected at the gate; record preserved for audit purposes); `pending` — self-registered but not yet approved by controller (Phase B only) |
| **Alias Design** | `alias` is the stable public identity — used in status display, log labels, Grafana, and LiteLLM routing. `name` remains as the hardware/DNS truth. `address` holds the DNS hostname. If hardware is replaced, the new machine gets the same alias — dashboards are unaffected. Reserved alias prefixes: `controller-`, `inference-worker-`, `knowledge-worker-`, `peer-` (matches existing node profiles). |
| **Phase A Node Schema** | `{ "schema_version": "1.1", "alias": "inference-worker-1", "name": "macbook-m1", "address": "TC25.mynetworksettings.com", "address_fallback": "10.19.208.118", "status": "active", "profile": "inference-worker", "os": "darwin", "deployment": "bare_metal", "registered_at": "2026-03-24T00:00:00Z", "models": ["llama3.1:8b-instruct-q4_K_M"] }` |
| **Migration** | (1) Create `configs/nodes/` directory. (2) Write one `<alias>.json` per existing node. (3) Remove `nodes[]` from `config.json` and bump `schema_version` to `1.1`. (4) Update all scripts that read `.nodes[]` to glob `configs/nodes/*.json` via `jq` or direct file reads. (5) Update `status.sh`, `deploy.sh`, `configure.sh` to read alias for display/labeling. |
| **Driver** | Human-initiated, joint design |
| **Trigger** | Observation that `config.json` mixes stack topology with node registry at a point where node topology is growing and dynamic registration is on the roadmap. |
| **Commit** | *(pending Phase A implementation)* |

---

### D-027 — Node Registry: Phase B — Dynamic Registration (Deferred)

| Field | Value |
|---|---|
| **Decision** | Defer dynamic node registration to a future phase. The Phase A file layout is designed as the on-disk representation Phase B will write to. When Phase B is implemented, a registration service hosted on the controller will accept node self-registration, write `configs/nodes/<alias>.json`, manage heartbeat-driven status transitions, and enforce admission control. |
| **Context** | Phase A establishes the schema contract and file layout. Phase B adds the network layer: nodes POST to the controller on startup/shutdown, the controller manages status transitions automatically, and scripts continue to read node files without modification (the registry service maintains the files). |
| **Registry Host** | The controller node (SERVICES) hosts the registration service, either as a new microservice or as an extension to the Knowledge Index Service. The controller is the authority for the node registry — workers and peers push to it, not to each other. Non-peer nodes (inference-workers without a full controller stack) interact with it via HTTPS only; they do not need the registry service installed locally. |
| **Lifecycle Transitions** | Node starts → `POST /registry/register` → status: `active`. Node shuts down cleanly → `POST /registry/deregister` → status: `inactive`. Heartbeat missing for TTL duration → controller sets status: `unhealthy`. Admin action → status: `prohibited` (not settable by nodes themselves). LiteLLM routing excludes all nodes where `status != active`. |
| **Trust Model** | Registration requires a pre-shared token (initially) — a secret provisioned during `deploy.sh` and stored as a Podman secret or environment variable. mTLS is the Phase B+ upgrade path (deferred until more than ~5 nodes). The `prohibited` status functions as the enforcement gate: a node without a valid token cannot register; an admin-prohibited node is rejected even with a valid token. |
| **Backward Compatibility** | Not a constraint — the project is pre-release. The Phase A file layout is the bridge; once Phase B is implemented, the manual file writes become registration API calls. Shell scripts remain valid during the transition. |
| **Script Language Note** | Shell scripts are acknowledged as a scaling limit for heavier registration logic. Phase B implementation may use a lightweight Python service (consistent with the Knowledge Index Service pattern) rather than bash, with scripts calling the service via `curl` for the few integration points needed. |
| **Deferred Items** | Heartbeat protocol and TTL configuration; `pending` status and admin approval workflow; certificate-based node identity (mTLS); multi-region or WAN node federation; load-balancing across `active` nodes of the same profile. |
| **Driver** | Human-initiated, joint design |
| **Trigger** | Phase A/B separation discussion; Phase A prioritized due to low risk and high immediate value; Phase B deferred pending controller service design. |
| **Commit** | *(deferred — Phase B)* |

---

### D-028 — Layer 5 Distributed Smoke Tests: L1 + L2 Phase A, L3 Phase B

| Field | Value |
|---|---|
| **Decision** | Add a `testing/layer5_distributed/` pytest suite to verify distributed LLM functionality across all active nodes. Phase A delivers L1 (node liveness) and L2 (LiteLLM routing + coherence + metrics). L3 (concurrent load, failover characterization) is deferred to Phase B. |
| **Context** | Existing Layer 3 tests (`testing/layer3_model/`) are single-node: they target `localhost:9000` (LiteLLM on SERVICES) and verify that *some* model responds. They do not prove which node served the request, do not collect latency/throughput metrics, and do not verify that routing to specific remote nodes functions correctly. As the cluster grows (SERVICES + SOL + TC25), a distributed smoke layer is needed to confirm that all nodes are reachable, routing is correct, and performance is within expected bounds — and to establish a repeatable baseline for comparing hardware and software configurations. |
| **Test Runner** | SERVICES (controller). It has direct network access to all worker nodes on `mynetworksettings.com` and hosts LiteLLM at `localhost:9000`. Tests run in the repo's `.venv` (isolated from system Python). No new test runner — pytest, consistent with all other layers. |
| **Node Identity** | Tests use `alias` from D-026 node files (`configs/nodes/<alias>.json`) — never physical hostnames. Node enumeration: glob `configs/nodes/*.json`, filter `status == active`. Test IDs, report labels, and metrics records all use `alias`. |
| **L1 — Liveness** | Scope: verify each active node's ollama process is reachable and responding. Method: direct HTTP probe to `http://<node.address>:11434/api/tags` — no LiteLLM involvement. Pass/fail: binary. Failure semantics: hard fail (node is down). Always-on: intended to run after every deploy. |
| **L2 — Routing + Coherence** | Scope: verify LiteLLM routes to the correct node by model-ID and that the model produces coherent output. Method: request via LiteLLM using a node-affinity model ID (e.g. `ollama/llama3.2:3b@inference-worker-2`); confirm routing via `x-litellm-backend` response header; assert coherent response. Tests per node: ~4 fixed cases (echo, arithmetic, instruction following, single-turn context). Failure semantics: soft fail with metrics recorded. Metrics per request: `ttft` (time to first token, via streaming), `total_latency`, `tokens_per_second` (`usage.completion_tokens` / latency), `model`, `node_alias`. Output: JSON results file written per run to `testing/layer5_distributed/results/<timestamp>.json`. |
| **Metrics Design** | L2 tests use the streaming endpoint (`stream: true`) to capture `ttft`. A shared `metrics_recorder` pytest fixture accumulates per-request records and writes the results file at session teardown. Results schema: `{ "run_id": <timestamp>, "suite": "L2", "results": [ { "test_id": ..., "node_alias": ..., "model": ..., "ttft_ms": ..., "total_ms": ..., "tokens_per_sec": ..., "passed": ... } ] }`. This schema is designed for cross-run comparison from day one. |
| **Prerequisites** | (1) D-026 Phase A: `configs/nodes/<alias>.json` files must exist with `status` and `alias` fields — the test suite enumerates nodes from these files. (2) Node-affinity model registration in LiteLLM: `pull-models.sh` must be updated to register per-node model aliases (`ollama/<model>@<alias>` with `api_base: http://<node.address>:11434`). This is a direct consequence of D-026 and must be scoped into Phase A work alongside the node file migration. |
| **Phase B deferred** | L3 concurrent/load characterization: asyncio-based fan-out (N parallel requests), routing distribution measurement (% served by each node), p50/p95/p99 latency per node, failover tests (stop one node, assert requests complete on remaining nodes), cross-run comparison tooling. L3 test count is intentionally a *range* (not fixed) to support characterizing both reasoning depth and concurrent throughput as separate dimensions. Prometheus/Loki scraping also deferred to Phase B. |
| **Layer Numbering** | Layer 5. Layers 0–4 are defined in `testing/README.md`. Layer 5 is above layer 4 (`layer4_localhost.bats`) and represents distributed/cross-node scope. |
| **Driver** | Human-initiated, joint design |
| **Trigger** | Distributed LLM cluster (Phase 9) now operational; need a way to verify distributed functionality and establish a performance baseline before evaluating alternative hardware/software configurations. |
| **Commit** | *(pending Phase A implementation — after D-026 Phase A)* |

---

### D-029 — Node Profile Refinement: inference-worker + enhanced-worker (Supersedes D-018 knowledge-worker, D-024)

| Field | Value |
|---|---|
| **Decision** | Replace the `knowledge-worker` profile with a single `enhanced-worker` profile. The previously proposed three-tier separation (inference-only, platform knowledge worker, full knowledge worker) collapses to two non-controller profiles: `inference-worker` (inference only) and `enhanced-worker` (inference + context + optional web). Capability differences between enhanced-worker tiers are policy-controlled by the controller at dispatch time via a `capabilities[]` field in the node schema — not enforced by deploying different service sets. |
| **Context** | D-018 defined four profiles including `knowledge-worker`. D-024 specified its service set and hardware floor. Architecture analysis showed that `knowledge-worker` is a half-design: it deploys KI + Qdrant on the node but provides neither a content creation path (no web search, no Flowise) nor a local RAG path (inference prompt does not pass through local KI). The service would sit idle. Separately, a design conversation established that a 3-tier worker split adds unnecessary operational complexity — the capability differences are controller-granted at dispatch time, not resident on the node. |
| **inference-worker services** | Ollama + Promtail. No KI, no Qdrant, no web search. Current TC25 and SOL deployment profile. |
| **enhanced-worker services** | Ollama + Promtail + Knowledge Index Service (SQLite) + local Qdrant. Web search capability activated by presence of `TAVILY_API_KEY` env var. |
| **capabilities[] field** | Added to D-026 node schema. Values: `web_search`, `file_checkout`, `ki_checkout`, `write_back`. The controller reads this field when assembling task packages and delegating work. An `inference-worker` will have an empty or absent `capabilities[]`; an `enhanced-worker` declares what it can do. |
| **Updated node schema** | `{ "schema_version": "1.1", "alias": "...", ..., "profile": "inference-worker\|enhanced-worker", "capabilities": ["web_search", "ki_checkout", "write_back"] }` |
| **Current node assignments** | TC25 → `inference-worker` (bare-metal, memory constrained). SOL → `inference-worker` (pending Phase B reassessment). SERVICES → `controller`. |
| **Phase B** | Reassign SOL to `enhanced-worker` once Task Receiver (D-032 Phase B) is implemented and `/v1/search` endpoint in `app.py` is deployed. |
| **Supersedes** | D-018 (knowledge-worker profile definition), D-024 (knowledge-worker service set and hardware floor) |
| **Driver** | Joint — architecture analysis |
| **Trigger** | Discovery that knowledge-worker profile has no content creation path and no local RAG path — it is a half-design that would deploy services that sit idle. |
| **Commit** | *(pending)* |

---

### D-030 — RAG Pipeline: LiteLLM pre_call_hook for Controller-Side Context Injection

| Field | Value |
|---|---|
| **Decision** | Implement RAG as a LiteLLM `async_pre_call_hook` on the controller. The hook queries the controller's Knowledge Index Service (`POST /query`) to retrieve relevant context for the incoming prompt, optionally fetches referenced file content from MinIO via pre-signed URL, and injects the assembled context into the system message before the request is routed to any inference node. Worker nodes remain pure inference endpoints — they receive a pre-stuffed prompt and have no knowledge that a RAG step occurred. |
| **Context** | RAG in the existing architecture runs via Flowise workflows, which requires explicit workflow authoring per use case. A hook-based approach makes RAG ambient — every inference request passing through LiteLLM gets context injection automatically (or opt-in by tag), with no per-workflow configuration. |
| **Hook behaviour** | `async_pre_call_hook(user_api_key_dict, cache, data, call_type)` — fires before routing. Hook extracts the user's last message as the search query, calls controller KI `/query`, takes the top-k results, and prepends them as a `system` message addition. The hook is a no-op if KI returns empty results. |
| **File content injection** | If KI results reference a MinIO file (via `source_url` metadata), the hook fetches the pre-signed URL and injects the file text alongside the vector results. File content is truncated to fit the model's context window. |
| **Tool-calling flag** | Only inject context for models where `tool_calling` or `rag_enabled` is set in the LiteLLM model config. Prevents wasted context on models that cannot use structured context. |
| **Phase A** | Hook implementation on controller only. Workers remain `inference-worker` — no local RAG path. |
| **Phase B** | Local RAG path on `enhanced-worker` nodes: Task Receiver service queries local Qdrant before forwarding to local Ollama. Deferred. |
| **Driver** | Architecture analysis — LiteLLM hooks are the right integration point for ambient RAG without per-workflow authoring |
| **Trigger** | D-029 profile redesign confirmed workers are pure inference endpoints; all context assembly belongs on the controller. |
| **Commit** | *(pending)* |

---

### D-031 — Web Research Pipeline: Controller-Orchestrated, Worker-Executed

| Field | Value |
|---|---|
| **Decision** | Web research is orchestrated by the controller's Flowise (deciding what to research and which node should execute) but executed at the worker node level (worker's own internet connection, worker's local KI). A new `POST /v1/search` endpoint in `app.py` accepts a `{ "query": "...", "collection": "..." }` request, performs a Tavily API search locally, ingests the results into the worker's local Qdrant, and triggers a custody push to the controller KI. The controller's Flowise Supervisor flow targets a specific enhanced-worker node by calling its KI `/v1/search` endpoint. |
| **Context** | All-controller-side web research (Flowise calling Tavily on SERVICES) centralizes all internet bandwidth through the controller, which is a bottleneck as the cluster scales. Distributing search execution to enhanced-worker nodes lets each node use its own internet connection for tasks delegated to it. |
| **Web search provider** | **Tavily** as the production provider for all deployments. LLM-optimized structured output minimizes downstream processing before ingestion. Free tier: 1,000 req/month. Paid: $20/month → 10,000 req. **DuckDuckGo** permitted for local development only — unofficial, no SLA, fragile. |
| **TAVILY_API_KEY** | Injected as a Podman secret on enhanced-worker nodes. Absence of this env var means `/v1/search` returns HTTP 501 Not Implemented. This is the capability flag that distinguishes enhanced-workers from inference-workers at the application level. |
| **Controller fallback** | If no enhanced-worker nodes have `web_search` in capabilities, the controller's Flowise calls Tavily directly and ingests to the controller KI. This maintains research capability even before any enhanced-workers are deployed. |
| **Ingest target** | Worker-executed search: results ingest to worker's local Qdrant first, then custody push to controller KI via `POST /v1/libraries`. Controller-fallback search: results ingest directly to controller KI. |
| **app.py changes** | New endpoint `POST /v1/search`. New dependency: `tavily-python`. New env var: `TAVILY_API_KEY`. Endpoint is a no-op (501) when `TAVILY_API_KEY` is unset. |
| **Phase A** | Controller fallback path only (Flowise + Tavily + controller KI). `/v1/search` endpoint added to `app.py` but not deployed on any worker until Phase B. |
| **Phase B** | Deploy enhanced-worker profile on SOL. Flowise delegates search to worker `/v1/search`. |
| **Driver** | Joint — internet traffic distribution concern |
| **Trigger** | Recognition that all-controller web search centralizes all internet bandwidth and does not scale; worker-executed search with custody push is the cleaner distributed model. |
| **Commit** | *(pending)* |

---

### D-032 — File Repository Service: MinIO on Controller

| Field | Value |
|---|---|
| **Decision** | Deploy MinIO as the internal file repository on the controller node. MinIO provides S3-compatible object storage with native pre-signed URL support, using URL TTL as the checkout/expiry mechanism. No separate checkout state service is required. File access is internal-only — MinIO is not exposed through Traefik to external networks. |
| **Context** | Profiles 2/3 (now `enhanced-worker`) require the ability to receive document context from the controller for RAG tasks. The controller needs a way to distribute files to nodes for task-scoped use without permanent replication. Pre-signed URLs with TTL are the simplest checkout model: the URL is the credential, and expiry enforces the checkout window. |
| **Buckets** | `documents` (operator-uploaded reference documents), `libraries` (`.ai-library` packages in transit), `research` (web research artifacts before custody push), `outputs` (write-back results from enhanced-workers). |
| **Checkout model** | Controller Flowise or LiteLLM hook generates a pre-signed GET URL (TTL = task duration estimate, default 1 hour). URL is passed to the node as part of the task context. Node fetches directly from MinIO using the URL. No separate checkout record. URL expiry = checkout expiry. |
| **Write-back model** | Controller generates a pre-signed PUT URL for the `outputs` bucket. Enhanced-worker POSTs its result file. Controller Flowise polls or webhooks on bucket event to ingest. |
| **Internal access** | MinIO container on `ai-stack-net` at `minio.ai-stack:9000` (S3 API) and `minio.ai-stack:9001` (console, admin only). No Traefik route. Remote nodes access MinIO via pre-signed URLs that embed the controller's public DNS. Pre-signed URL host must match the controller's externally reachable address. |
| **Auth** | MinIO root credentials via Podman secrets. LiteLLM hook and Flowise use a dedicated MinIO service account (least-privilege: read `documents`, read/write `research` and `outputs`, read `libraries`). |
| **config.json** | New `minio` service entry. `schema_version` bumped to `1.2`. |
| **Phase A** | Deploy MinIO. Wire Flowise to generate pre-signed URLs. Wire LiteLLM hook to fetch file content via pre-signed URLs. Buckets: `documents`, `outputs`. |
| **Phase B** | `research` and `libraries` buckets wired into custody push pipeline. Write-back from enhanced-workers. |
| **Driver** | Joint — file distribution mechanism for task-scoped context |
| **Trigger** | Enhanced-worker profile requires a file checkout mechanism; MinIO pre-signed URLs solve checkout lifecycle with no additional state management. |
| **Commit** | *(pending)* |

---

### D-033 — MCP Scope: External Developer Tools Only; In-Stack Uses LiteLLM + Flowise

| Field | Value |
|---|---|
| **Decision** | The MCP server in `knowledge-index/app.py` is scoped exclusively to external developer tools (Claude Desktop, Cursor, VS Code Copilot). In-stack RAG is handled by the LiteLLM `pre_call_hook` (D-030); in-stack web research and write-back are handled by Flowise REST calls (D-031). MCP is not an inter-service integration pattern within this stack. |
| **Context** | D-015 specified MCP with HTTP/SSE transport. The original intent was developer tool access to `search_knowledge` and `ingest_document`. A design question was raised about making MCP available to all users and nodes. Architecture analysis (D-029 through D-032) showed that in-stack workflows are better served by LiteLLM hooks (ambient RAG) and Flowise REST (research orchestration) — MCP adds no value for the in-stack case and introduces M2M auth complexity. |
| **API_KEY gap** | `API_KEY` must be set as a Podman secret in the knowledge-index container. Absence makes the MCP endpoint unauthenticated if port 8100 is reachable on the container network. Add `knowledge_index_api_key` to the `secrets[]` block in config.json knowledge-index service definition. |
| **Traefik auth for /mcp/** | Replace Authentik forward-auth middleware on `/mcp/*` Traefik route with an API key header middleware. Authentik forward-auth requires a browser SSO session — incompatible with developer MCP clients (Claude Desktop, Cursor) which send a Bearer token, not a session cookie. The `/v1/*` REST routes retain Authentik forward-auth for browser-based access. |
| **In-stack tool access** | OpenWebUI users access knowledge via LiteLLM RAG injection (transparent). LiteLLM hook calls KI REST internally using `KI_API_KEY`. Flowise calls KI REST internally. No MCP client wiring in any stack service. |
| **Phase A** | Set `API_KEY` secret. Update Traefik `/mcp/*` route to use API key middleware. Document MCP client configuration for external tools. |
| **Deferred** | MCP `tool_calling` integration via OpenWebUI (if OpenWebUI gains native MCP client support in a future version — evaluate at that point). |
| **Driver** | Architecture analysis — LiteLLM hooks + Flowise REST supersede MCP for in-stack use cases |
| **Trigger** | MCP availability question revealed that the in-stack use case is solved better by existing hook mechanisms; MCP scope narrows back to its original intent. |
| **Commit** | *(pending)* |

---

### D-034 — API-Level and Terminal Access to the Stack *(PENDING DISCUSSION)*
| Field | Value |
|---|---|
| **Status** | **Pending** — question raised, not yet resolved |
| **Question** | What programmatic and terminal access surfaces should the stack expose, to whom, and at what privilege level? The stack currently offers: (a) OpenWebUI browser interface for end users, (b) LiteLLM `/v1/*` for API callers (Authentik-protected), (c) MCP server for external developer tools (D-033), (d) Flowise REST for workflow automation. The gap: no defined access surface for operators, automation scripts, or remote management that doesn't require a browser session. |
| **Scope options** | **(1) Management REST API** — a dedicated admin endpoint (e.g., `POST /admin/v1/` in app.py or a separate service) for stack-level operations: node registration, model catalog queries, job status, health rollup. **(2) CLI wrapper** — a `stack-cli` script or extension of existing `scripts/` that can be invoked over SSH or in CI/CD pipelines against a running stack. **(3) Terminal access policy** — formalize which nodes allow SSH, which keys, and whether direct container exec is permitted for break-glass scenarios. **(4) API gateway entry point** — whether Traefik should expose a dedicated admin router with stricter auth (mTLS or IP allowlist) separate from user-facing routes. |
| **Interactions** | D-026 (node registry — management API is the natural write surface for node registration). D-028 (L5 tests — CI/CD needs a stable API to poll distributed health/results). D-033 (MCP is *not* this — MCP is for developer tools, not operator automation). Phase 12 (task dispatch, `/v1/search`, `/v1/catalog` — operator observability of pipelines implies a query surface). |
| **Deferred** | Full resolution deferred. Captured before Phase 11 implementation begins so scaffolding in Phases 11–12 doesn't foreclose a clean management API surface. |
| **Driver** | User-raised question before Phase 11 implementation |
| **Commit** | *(pending)* |
