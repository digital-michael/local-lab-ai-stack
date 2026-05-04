# AI Stack — Feature Status

**Last Updated:** 2026-04-21

A human-readable summary of what this stack provides, ordered from most to least foundational. Intended for communicating capabilities to a non-technical audience and tracking progress toward a complete platform.

---

## Overview

This is a **self-hosted, privacy-first AI platform** that runs on your own hardware — no subscriptions, no per-token usage fees, and no mandatory third-party cloud services.

At its core, the stack gives a team:

- **A chat interface** for conversational AI, backed by models running on local machines
- **A private knowledge base** that AI can draw from when answering questions about your own documents
- **A workflow builder** for automating multi-step tasks with AI without writing code
- **Distributed inference** so that multiple machines contribute GPU compute to the shared model pool

Everything is secured behind a single login, all traffic is encrypted, and the full state of the system can be backed up and restored with a single command.

**Internet access and data sharing:** By default, the stack operates entirely within your local network — no data leaves your machines. However, LiteLLM can optionally route requests to external cloud providers (OpenAI, Anthropic, Mistral, and others) when configured with API keys. When cloud backends are in use, prompts and responses travel to and from those providers under their respective privacy policies. Using only local backends (Ollama, vLLM) ensures no data leaves your network.

The stack is designed to grow: new inference nodes can be added to increase capacity, new models can be hot-swapped, and the architecture extends toward a fully peer-to-peer mesh where each node operates independently while contributing to the shared pool.

---

## Technology Stack

16 containerized services, organized by functional layer. All traffic enters through the Edge layer; every upstream is protected by authentication before a request reaches it.

| Layer | Component | Primary Responsibility |
|---|---|---|
| **Application** | OpenWebUI ([ref](https://docs.openwebui.com/)) | Browser-based chat interface; primary user-facing entry point |
| **Application** | Flowise ([ref](https://flowiseai.com/)) | Visual AI workflow builder; multi-step automation without code |
| **Edge** | Traefik ([ref](https://traefik.io/traefik/)) | Reverse proxy; TLS termination; routes all inbound traffic to upstream services |
| **Edge** | Authentik ([ref](https://goauthentik.io/)) | Identity provider; SSO; enforces authentication on every protected service |
| **Inference** | LiteLLM ([ref](https://docs.litellm.ai/)) | Unified model proxy; routes to local or cloud backends via a single OpenAI-compatible API |
| **Inference** | Ollama ([ref](https://ollama.com/)) | Local model runner; serves LLMs on CPU or GPU across one or more nodes |
| **Inference** | vLLM ([ref](https://docs.vllm.ai/)) | High-throughput GPU inference engine; optimized for production serving |
| **Knowledge** | knowledge-index | Document ingestion pipeline; chunks, embeds, and indexes content into Qdrant |
| **Storage** | PostgreSQL ([ref](https://www.postgresql.org/)) | Relational database; persistent state for Authentik, Flowise, and LiteLLM |
| **Storage** | Qdrant ([ref](https://qdrant.tech/)) | Vector database; stores and queries document embeddings for RAG |
| **Storage** | MinIO ([ref](https://min.io/)) | Object storage; model artifacts, log archives, and backup snapshots |
| **Observability** | Grafana ([ref](https://grafana.com/grafana/)) | Dashboards and alerting; visualizes metrics and health signals |
| **Observability** | Prometheus ([ref](https://prometheus.io/)) | Metrics scraping and time-series storage across all stack services |
| **Observability** | Loki ([ref](https://grafana.com/oss/loki/)) | Log aggregation backend; stores structured logs from all containers |
| **Observability** | Promtail ([ref](https://grafana.com/docs/loki/latest/send-data/promtail/)) | Log shipping agent; collects and forwards container logs to Loki |
| **Application** | Homepage ([ref](https://gethomepage.dev/)) | Operator dashboard; single-pane service health, status, and navigation |

---

## Table of Contents

**Core Features** *(fully available)*
- [AI Chat Interface](#x-ai-chat-interface)
- [Multi-Model Inference Routing](#x-multi-model-inference-routing)
- [Retrieval-Augmented Generation (RAG)](#x-retrieval-augmented-generation-rag)
- [AI Workflow Builder](#x-ai-workflow-builder)
- [Distributed GPU Inference](#x-distributed-gpu-inference)
- [Authentication and Access Control](#x-authentication-and-access-control)
- [Observability — Metrics and Dashboards](#x-observability--metrics-and-dashboards)
- [Centralized Log Aggregation](#x-centralized-log-aggregation)
- [Secure Reverse Proxy with TLS](#x-secure-reverse-proxy-with-tls)
- [Automated Backup](#x-automated-backup)
- [MCP Tool Integration](#x-mcp-tool-integration)
- [Localhost Library Discovery](#x-localhost-library-discovery)
- [Volume Ingestion Pipeline](#x-volume-ingestion-pipeline)
- [Security Audit Tool](#x-security-audit-tool)
- [Dynamic Node Registration](#x-dynamic-node-registration)
- [Worker Sleep Inhibitor](#x-worker-sleep-inhibitor)
- [Inference Node Hardening](#x-inference-node-hardening)
- [Tailscale SSH — Zero-Config Node Access](#--tailscale-ssh--zero-config-node-access)
- [Operator Dashboard](#x-operator-dashboard)
- [Port Lockdown — Traefik-Only Ingress](#x-port-lockdown--traefik-only-ingress)

**Partially Available**
- [M2M IAM Gateway (Localhost)](#--m2m-iam-gateway-localhost)
- [Local GPU Acceleration](#--local-gpu-acceleration-controller)
- [Inference Node Security](#--inference-node-security)
- [Local/WAN Discovery Profiles](#--localwan-discovery-profiles)

**Pending**
- [vLLM GPU Inference](#-vllm-gpu-inference)

**Deferred**
- [Peer Node Topology](#d-peer-node-topology)
- [Live Throughput Profiling Dashboard](#d-live-throughput-profiling-dashboard)
- [Recursive Language Model (RLM) Integration](#d-recursive-language-model-rlm-integration)
- [Federated Knowledge Search](#d-federated-knowledge-search)
- [Team-Shared Chat and Context](#d-team-shared-chat-and-context)
- [Knowledge Library Governance](#d-knowledge-library-governance)
- [Model A/B Testing](#d-model-ab-testing)
- [Federated MCP Tool Registry](#d-federated-mcp-tool-registry)
- [Knowledge Authority Tiers](#d-knowledge-authority-tiers)
- [Knowledge Federation and Monetization](#d-knowledge-federation-and-monetization)
- [Configurable Stack Domain](#d-configurable-stack-domain)

---

## Status Key

| Symbol | Meaning |
|--------|---------|
| `[X]` | Available — deployed, tested, and working |
| `[-]` | Partial — core function works; gaps or caveats noted |
| `[ ]` | Pending — planned and scoped, not yet built |
| `[D]` | Deferred — on the roadmap but not yet scheduled |

---

## Core Features

### `[X]` AI Chat Interface
Users can have conversations with any available AI model through a browser — no technical knowledge required.
- Web UI accessible at the stack's HTTPS address
- Supports multiple models selectable per conversation
- Conversation history preserved across sessions
- _Powered by: [OpenWebUI](library/framework_components/openwebui/best_practices.md)_

### `[-]` Multi-Model Inference Routing
The stack runs multiple AI models simultaneously and routes requests to the right one automatically. Models can run locally, on remote inference nodes, or on hosted cloud providers — all behind the same single endpoint.
- A single API endpoint handles all models — callers choose by model name
- Local models run on the controller or on any registered inference node
- Hosted cloud models (OpenAI, Anthropic, Mistral) can be added via API key — same routing interface, no code changes for callers
- Groq cloud routing (`llama3-70b-8192`): **pending** — `groq_api_key` secret not provisioned; model defined in `config.json` but will return 401
- Transparent routing; callers are unaware of which machine or provider handles the request
- _Powered by: [LiteLLM](library/framework_components/litellm/best_practices.md)_ · _Defined in: [configs/config.json](../configs/config.json) `models[]`_

### `[X]` Retrieval-Augmented Generation (RAG)
AI responses can be grounded in a private knowledge base rather than relying solely on the model's training data.
- Ingest documents into the knowledge library
- Questions automatically retrieve relevant context before answering
- Vector similarity search across all indexed content
- _Powered by: [Knowledge Index Service](../services/knowledge-index/app.py) + [Qdrant](library/framework_components/qdrant/best_practices.md)_

### `[X]` AI Workflow Builder
Non-developers can build multi-step AI pipelines visually — chain models, tools, and knowledge sources together without writing code.
- Drag-and-drop flow authoring
- Supports RAG pipelines, tool-calling chains, and agent workflows
- REST API for programmatic flow execution
- _Powered by: [Flowise](library/framework_components/flowise/best_practices.md)_

### `[X]` Distributed GPU Inference
AI inference workload is distributed across multiple machines, increasing throughput and enabling several models to run simultaneously on dedicated hardware.
- Each registered inference node runs a model matched to its hardware capabilities (GPU VRAM, CPU cores, or unified memory)
- The controller always retains at least one local model as a baseline
- Additional nodes joined via a single setup script; model assignment auto-detected from available resources
- _Defined in: [configs/config.json](../configs/config.json) `nodes[]`_ · _Setup: [scripts/podman/setup-worker.sh](../scripts/podman/setup-worker.sh)_ · _Phase: [9c/9d](ai_stack_blueprint/ai_stack_checklist.md#phase-9c--alienware-podman-worker)_

### `[X]` Authentication and Access Control
All services require login. External identity providers can be connected via SSO.
- Single sign-on across all web interfaces via Authentik forwardAuth middleware on every Traefik router
- OAuth2/OIDC support (Google Workspace, GitHub, LDAP, etc.)
- Forward-auth at the reverse proxy — no per-service login configuration
- Machine-to-machine endpoints (MCP, KI API) use API key auth where browser SSO is not applicable
- Security policy codified in [docs/security-policy.md](../docs/security-policy.md)
- _Powered by: [Authentik](library/framework_components/authentik/best_practices.md) + [Traefik](library/framework_components/traefik/best_practices.md)_

### `[-]` Observability — Metrics and Dashboards
Operators can see the health, performance, and resource usage of every service in real time.
- Per-service CPU, memory, and request rate metrics
- Alerting rules for degraded or failed services: **done**
- Pre-built provisioned dashboards: **pending** — Grafana provisioning directory is empty; no dashboards are loaded on first start
- _Powered by: [Prometheus](library/framework_components/prometheus/best_practices.md) + [Grafana](library/framework_components/grafana/best_practices.md)_

### `[-]` Centralized Log Aggregation
All service logs from all nodes are collected in one place, searchable by service, level, time range, and content.
- Loki running with 7-day retention: **done**
- Promtail process running and Loki connectivity verified: **done**
- Container log scraping configured: **pending** — `scrape_configs` is empty; no container logs reach Loki
- Structured log queries across the full fleet: **pending** (depends on scrape config)
- _Powered by: [Loki](library/framework_components/loki/best_practices.md) + [Promtail](library/framework_components/promtail/best_practices.md)_

### `[X]` Secure Reverse Proxy with TLS
All external traffic is encrypted. Services are not directly exposed; all requests pass through a single entry point.
- Automatic HTTPS with local CA certificate
- Path and hostname-based routing to all services
- Authentication middleware applied globally
- _Powered by: [Traefik](library/framework_components/traefik/best_practices.md)_ · _Config: [configs/traefik/](../configs/traefik/)_

### `[X]` Automated Backup
The full stack state — databases, vector store, model files, configs — can be backed up with a single command and restored from backup.
- Covers: PostgreSQL, Qdrant, Flowise, Grafana, Ollama model cache
- Timestamped archives
- Restore procedure documented
- _Script: [scripts/backup.sh](../scripts/backup.sh)_

### `[X]` MCP Tool Integration
AI agents can call external tools during a conversation by following the Model Context Protocol standard.
- REST API for knowledge search and document ingestion: **available**
- MCP SSE/HTTP transport for agent tool-calling over `/mcp/sse`: **available**
- `search_knowledge` and `ingest_document` MCP tools; auth guard on `API_KEY`
- Cross-node routing in `search_knowledge` mirrors REST `/query` behaviour
- _Powered by: [Knowledge Index Service](../services/knowledge-index/app.py)_ · _Delivered: [Phase 7](ai_stack_blueprint/ai_stack_checklist.md#phase-7--knowledge-index-mcp-integration)_

### `[X]` Localhost Library Discovery
The knowledge base can be populated by scanning a local filesystem directory for pre-packaged `.ai-library` bundles — no manual upload required.
- Scans `LIBRARIES_DIR` for subdirectories containing a `manifest.yaml` (name + version required)
- Verifies `checksums.txt` if present; missing checksum file is a warning, not a failure
- Ingests all document files from the package's `documents/` folder into Qdrant
- Already-cataloged packages are skipped unless `force=true` is passed
- Packages appear in `/v1/catalog` with `origin_node=localhost` and their filesystem path recorded
- _Powered by: [Knowledge Index Service](../services/knowledge-index/app.py)_ · _Schema: [configs/library-manifest-schema.json](../configs/library-manifest-schema.json)_ · _Delivered: [Phase 15](ai_stack_blueprint/ai_stack_checklist.md#phase-15)_

### `[X]` Volume Ingestion Pipeline
Raw document directories can be packaged into `.ai-library` bundles with a single command, ready for local scanning or pushing to the controller.
- `configure.sh build-library --source <dir> --name <slug> --version <semver>` — no running services required
- Copies all supported file types (`.md`, `.txt`, `.rst`, `.yaml`, `.json`, `.html`) into `documents/`
- Generates `manifest.yaml`, `metadata.json`, and `checksums.txt` automatically
- Produced packages are immediately consumable by `POST /v1/scan` and `configure.sh sync-libraries`
- _Powered by: [scripts/configure.sh](../scripts/configure.sh)_ · _Format: D-013_ · _Delivered: [Phase 16](ai_stack_blueprint/ai_stack_checklist.md#phase-16)

### `[X]` Operator Dashboard
A single-pane operator view at `dashboard.stack.localhost` showing all 16 stack services with health status, live metrics widgets, and direct links to each service's web UI.
- Deployed as [Homepage](https://gethomepage.dev/) behind Authentik SSO — same session cookie; seamless navigation
- Live widgets: Authentik user/flow counts, Grafana health, LiteLLM model count, Qdrant collection count, Flowise chatflow count, Loki build info, Prometheus metrics via Promtail widget
- All service `href` links use `*.stack.localhost` naming convention
- Credential injection via `HOMEPAGE_VAR_*` env vars in quadlet (no plain-text secrets in config files)
- _Powered by: [Homepage](https://gethomepage.dev/)_ · _Config: `~/ai-stack/configs/homepage/`_

### `[X]` Port Lockdown — Traefik-Only Ingress
All services are reachable exclusively through Traefik, which enforces Authentik SSO. Direct host-port bypass is architecturally eliminated.
- Only traefik (80/443), postgres (5432), and ollama (11434) publish host ports
- All other service quadlets have no `PublishPort` — container-network only
- `curl localhost:<port>` → connection refused for every Traefik-routed service
- Security posture documented in [docs/security-policy.md](../docs/security-policy.md) with 3-tier model
- Credentials captured to `configs/credentials.local` (git-ignored) via `scripts/capture-credentials.sh`
- _Enforced by: config.json `"ports": []` + quadlet generation_

---

## Partially Available Features

### `[-]` M2M IAM Gateway (Localhost)
The stack now includes a localhost-only machine-to-machine gateway for service identities, scoped workflow access, controlled long-running leases, and audited break-glass approvals.
- JWT validation supports secret and JWKS paths, with strict audience/workflow/scope enforcement
- Workflow policy gates model/tool/context source access with default-deny dynamic source behavior
- Long-running jobs use lease + heartbeat + extension controls with approval gates beyond auto-extend thresholds
- Break-glass approvals are scope-limited, reason-coded, audited, and expiry-bound
- Cross-platform trusted interoperability is explicit opt-in; project-bound MinIO/Open WebUI context is blocked from cross-platform sharing
- Publication adapter boundary contract is implemented at `/m2m/v1/publish/transform`
- Authentik provisioning helper supports issuer/JWKS wiring, per-service client template generation, and endpoint-driven API provisioning requests
- Automated security/acceptance coverage currently passes 21 tests across `testing/security/test_m2m_gateway.py` and `testing/security/test_m2m_gateway_client.py`
- Remaining work: deployed-runtime closure evidence
- _Implementation: [services/m2m-gateway/app.py](../services/m2m-gateway/app.py)_ · _Checklist: [docs/wip/m2m-localhost-mvp-checklist.md](wip/m2m-localhost-mvp-checklist.md)_ · _Operator how-to: [docs/library/actions/m2m-iam-crud/m2m-iam-crud-SKILL.md](library/actions/m2m-iam-crud/m2m-iam-crud-SKILL.md)_

### `[-]` Local GPU Acceleration (Controller)
The controller node's GPU can be used for high-speed inference, enabling larger or faster models to run locally.
- GPU configured with CDI device passthrough: **done**
- Ollama running with GPU acceleration: **done**
- vLLM for GPU-optimized large model serving: **pending**
- _Planned: [Phase 8](ai_stack_blueprint/ai_stack_checklist.md#phase-8--local-gpu-enablement-and-model-routing)_

### `[-]` Inference Node Security
Registered inference nodes are functional but not independently hardened — they rely on network-level trust rather than per-node authentication.
- The controller's API is fully protected; inference node endpoints are not
- The inference port on each node is reachable by any host on the same network segment
- Per-node API key enforcement: **pending**
- Firewall enforcement: **available** — `bash scripts/node.sh harden-worker --alias <alias>`
- _Delivered: [Security Audit Tool](#x-security-audit-tool)_ · _Delivered: [Inference Node Hardening](#x-inference-node-hardening)_

### `[-]` Local/WAN Discovery Profiles
Protocol specifications and stub endpoints for discovering knowledge libraries on peer nodes (local mDNS/DNS-SD) and federated registries (WAN).
- D-014a local profile specification (mDNS/DNS-SD `_ai-library._tcp`): **done**
- D-014b WAN profile specification (registry federation): **done**
- Node config `capabilities[]` populated: **done**
- `GET /v1/catalog/peers` stub endpoint: **done** (returns 501 — no peers run KI yet)
- `GET /v1/catalog/registry` stub endpoint: **done** (returns 501 — no registry server)
- Live mDNS broadcast/listen: **pending** (requires `zeroconf` + real peers)
- WAN registry server: **pending** (not yet built)
- _Delivered: [Phase 17](ai_stack_blueprint/ai_stack_checklist.md#phase-17) · Spec: D-014a, D-014b_

### `[X]` Security Audit Tool
`configure.sh security-audit` — automated posture scan: port bind exposure, auth enforcement probing, TLS cert expiry, secret hygiene in config.json, and unauthenticated Ollama detection on inference-worker nodes.
- `--json` for machine-readable output; `--skip-network` for offline/CI use
- Exit codes: 0 (clean), 1 (warnings), 2 (critical findings)
- T-113–T-116 bats coverage
- _Delivered: [Phase 19](ai_stack_blueprint/ai_stack_checklist.md#phase-19) · Checks: port exposure, auth probing, TLS, secret hygiene, worker hardening_

### `[X]` Dynamic Node Registration
Worker nodes self-register with the controller using a one-time join token, then maintain a live presence via a periodic heartbeat. The controller tracks node health, routes LiteLLM traffic based on node status, and queues resource suggestions for node operators.
- One-time join token flow: `configure.sh generate-join-token` → `bootstrap.sh` on worker → status `online`
- 5-state health machine: `online` → `caution` → `failed` → `offline` → `unregistered`
- Recovery from `caution`/`failed`: 2 consecutive healthy heartbeats within 70 s
- Heartbeat timer: `OnCalendar=*:*:0/30` (Linux systemd) or launchd `StartInterval=30` (macOS)
- Per-node API key issued at join time; all subsequent calls (heartbeats, status) use it
- LiteLLM routing updated automatically on status transitions
- _Powered by: [Node Registry](../services/knowledge-index/node_registry.py)_ · _Scripts: `node.sh`, `bootstrap.sh`, `heartbeat.sh`_ · _Delivered: [Phase 22](ai_stack_blueprint/ai_stack_checklist.md#phase-22)_

### `[X]` Worker Sleep Inhibitor
Prevents worker nodes from sleeping or hibernating while the AI stack is running, ensuring continuous inference availability.
- Opt-in per node: set `"sleep_inhibit": true` in `configs/config.json`
- macOS: `caffeinate -i -s` (built-in, no sudo)
- Linux: `systemd-inhibit --what=idle --mode=block` (no sudo required)
- Controller nodes always skip — they manage their own power policy
- PID tracked at `~/.config/ai-stack/inhibit.pid`; stale cleanup on `start`
- Automatically acquired by `start.sh` and released by `stop.sh`
- _Script: [scripts/inhibit.sh](../scripts/inhibit.sh)_ · _Delivered: [Phase 23](ai_stack_blueprint/ai_stack_checklist.md#phase-23)_

### `[X]` Inference Node Hardening
`node.sh harden-worker` — generates OS-appropriate firewall instructions to restrict Ollama port 11434 on an inference-worker node to the controller IP only.
- Reads controller IP from `configs/nodes/` (DNS-resolved to IP; falls back to `address_fallback`)
- Linux: prints `nftables` rules (primary) and `firewalld` rich-rules (alternative)
- macOS: prints `pf` anchor file + load commands + `/etc/pf.conf` persistence step
- `configure.sh security-audit` Check E now includes the exact `harden-worker` remediation command in its CRITICAL finding message
- _Delivered: [Phase 24](ai_stack_blueprint/ai_stack_checklist.md) · Script: [scripts/node.sh](../scripts/node.sh)_

### `[-]` Tailscale SSH — Zero-Config Node Access
Any enrolled cluster node can SSH to any other enrolled node without managing SSH keys — the tailnet ACL policy handles authentication.
- No key distribution required; `tailscale ssh <node>` works immediately after enabling `--ssh`
- ACL `ssh` block in `/etc/headscale/acl.json` grants `autogroup:nonroot` access between all `tag:net-ecotone-000-01` nodes
- headscale-host (photondatum.space) self-enrolled as `headscale-host` (`100.64.0.5`) — reach it as `tailscale ssh 3pdx7a@headscale-host`
- Known-hosts clearing required on first use when re-enrolling from Tailscale cloud (stale ED25519 key — run `ssh-keygen -R <node>` as the SSH user, not root)
- **TC25 (macOS App Store build):** Tailscale SSH server blocked by sandbox; use `ssh 3pdx7@100.64.0.3` via tailnet IP directly
- **SELinux (Fedora/RHEL):** `tailscale_use_ssh` boolean absent on Fedora 42; SSH works in practice under `unconfined_service_t`; check `ausearch -m avc` if blocked
- _Setup: [docs/getting-started.md Step 14](getting-started.md#step-14--enable-tailscale-ssh-optional-multi-node-deployments) · Runbook: CENTAURI playbook §7.9–§7.10_

---

## Pending Features

### `[ ]` vLLM GPU Inference
Running GPU-optimized large language models on the controller's dedicated GPU for maximum local performance on demanding tasks.
- _Planned: [Phase 8](ai_stack_blueprint/ai_stack_checklist.md#phase-8--local-gpu-enablement-and-model-routing)_

---

## Deferred Features

### `[D]` Peer Node Topology
Each node runs the complete stack independently. Nodes share inference capacity, discover each other's knowledge libraries, and continue working in a reduced capacity if any peer goes offline.
- _Planned: [Phase 10](ai_stack_blueprint/ai_stack_checklist.md#phase-10--full-peer-nodes-and-shared-knowledge)_



### `[D]` Live Throughput Profiling Dashboard
A real-time dashboard showing where the stack is slowest under load — so capacity planning and optimization effort is directed at the actual bottleneck, not the assumed one.
- Per-model inference latency and tokens/second across all nodes
- Knowledge Index query latency (embedding + vector search breakdown)
- LiteLLM gateway overhead and queue depth
- Per-node CPU/GPU/memory utilization over time
- _Tracked: BL-006_

### `[D]` Recursive Language Model (RLM) Integration
Research and integrate the MIT Recursive Language Model approach — a technique in which the model recursively decomposes complex problems into smaller sub-problems, solving each and composing results back up. Intended to improve multi-step reasoning quality on local models without requiring frontier-scale parameter counts.
- Requires design decision: prompting strategy (Flowise workflow), LiteLLM hook, or standalone service
- Evaluate against baseline reasoning test suite (Layer 3 tests) before and after
- _Tracked: BL-004; pending research — design decision required before implementation_

### `[D]` Federated Knowledge Search
A query sent to any node's knowledge base automatically fans out to all peer nodes' libraries and returns a merged result set — the user sees one unified answer regardless of where the relevant content lives.
- _Planned: [Phase 10](ai_stack_blueprint/ai_stack_checklist.md#phase-10--full-peer-nodes-and-shared-knowledge)_

### `[D]` Team-Shared Chat and Context
Conversation history and user context synchronized across all nodes so any team member can continue a conversation from any device connected to any node in the stack.
- _Tracked: [checklist Future Features](ai_stack_blueprint/ai_stack_checklist.md#4-future-features-architecture-roadmap)_

### `[D]` Knowledge Library Governance
Automated content classification, safety filtering, PII detection, and ethics alignment checks applied at ingestion time — ensuring the knowledge base remains accurate, safe, and compliant with operator-defined policies.
- _Tracked: [checklist Future Features](ai_stack_blueprint/ai_stack_checklist.md#4-future-features-architecture-roadmap)_

### `[D]` Model A/B Testing
Route a configurable fraction of requests to a candidate model and compare quality metrics against the current default — without requiring any changes to callers.
- _Tracked: [checklist Future Features](ai_stack_blueprint/ai_stack_checklist.md#4-future-features-architecture-roadmap)_

### `[D]` Federated MCP Tool Registry
Tools (web search, knowledge search, file access, API calls) defined once on any node are automatically discoverable and callable by AI agents running on any other node — a single registry, shared across the mesh, with no per-node duplication.
- _Tracked: [checklist Future Features](ai_stack_blueprint/ai_stack_checklist.md#4-future-features-architecture-roadmap)_

### `[D]` Knowledge Authority Tiers
Three explicitly demarcated authority layers can be attached to any Named Library Source: **Source** (canonical content), **Policy** (org-mandated override, binding), and **Annotation** (individual contributor opinion, advisory). Agents querying the knowledge base see results labeled by tier — so an org policy that overrides a source recommendation is never silently treated as just another document, and a personal opinion is never mistaken for a mandate.
- Policies travel with Sources during custody sync; annotations are local by default (explicit sharing required)
- Both are dependent entities — cannot exist without a Source (enforced at DB level via FK + CASCADE DELETE)
- `.ai-library` packages gain optional `policies/` and `annotations/` directories (structured YAML, machine-parseable)
- Search results carry a `tier` field enabling authority-filtered queries
- Includes extended circulation model: checkout/reserve, checkin/release (with overlay attachment), copy, hold, and flag operations
- _Design: D-037 — KAMS Phase A_

### `[D]` Configurable Stack Domain
At setup time, the operator is prompted for a custom domain base (e.g. `centauri.localhost`) instead of the hardcoded `stack.localhost` default. The domain is stored once in `config.json` and all generators derive from it — Traefik Host rules, TLS SANs, `/etc/hosts` entries, Authentik external_host/cookie_domain, Homepage ALLOWED_HOSTS, and `status.sh -vv` URL column.
- Eliminates hardcoded hostname strings scattered across config files
- Enables machine-named deployments: `auth.centauri.localhost`, `grafana.centauri.localhost`, etc.
- _Tracked: BL-007_

### `[D]` Knowledge Federation and Monetization
Knowledge Index nodes can form bilateral federations to share, mirror, and monetize content — with full source transparency on every result.
- **Peer tier**: minimal ceremony, symmetric, bootstrapped with two API calls; suitable for nodes operated by the same trusted operator
- **Institutional tier**: governed by out-of-band agreements; supports subscription, one-time, membership, and metered payment models
- **Entitlement verifier model**: the KI verifies payment status; payment processing is external (Stripe, Paddle, etc.); PCI-DSS scope stays out of the KI service
- **Origin transparency**: every catalog and search result always carries an `origin` block identifying whether the content is local or linked, who hosts it, and under which access agreement — not optional, always present
- **Access model**: default proxy (user never holds remote credentials); redirect and cached-proxy available per-agreement
- **Entitlement travel**: local by default; opt-in portability via explicit bilateral agreement terms
- _Design: D-038 — KAMS Phases B + C_
