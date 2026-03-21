# Project Decisions — llm-agent-local-2
**Last Updated:** 2026-03-08 UTC
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
| **Commit** | *(this commit)* |

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
| **Commit** | *(this commit)* |

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
| **Commit** | *(this commit)* |

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
| **Commit** | *(this commit)* |

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
| **Commit** | *(this commit)* |

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
| **Commit** | Phase 8 |

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
| **Commit** | Phase 8 |

---

### D-018 — Node Profiles: `controller`, `inference-worker`, `peer`

| Field | Value |
|---|---|
| **Decision** | Define three node profiles stored as `node_profile` in `config.json`: `controller` (full stack, all services), `inference-worker` (Ollama + Promtail only), `peer` (full stack, acts as both controller and remote provider). |
| **Context** | Phase 9 requires multiple machines to contribute inference capacity. Each machine has different hardware and different roles. A single deployment model (full stack) wastes resources on lightweight worker nodes and doesn't fit the macOS bare-metal scenario. |
| **Options Considered** | (1) One profile (deploy everything everywhere). (2) Two profiles (full stack vs. minimal). (3) Three profiles separating the coordination role (controller) from full peer participation. |
| **Rationale** | Three profiles map to real deployment scenarios: a developer workstation (controller), a secondary Mac or GPU box running only Ollama (inference-worker), and a future fully-participatory node (peer). The `inference-worker` profile deploys only Ollama and Promtail — sufficient to contribute models and ship logs to the controller's Loki. `generate-quadlets` enforces the profile at quadlet-generation time, ensuring the right services are deployed. |
| **Driver** | Agent-proposed, Phase 9 design |
| **Trigger** | Architecture need — distributing inference across heterogeneous machines requires role-differentiated deployments. |
| **Commit** | Phase 9a |

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
| **Commit** | Phase 9a |

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
| **Commit** | Phase 9a |

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
| **Commit** | Phase 9a |
