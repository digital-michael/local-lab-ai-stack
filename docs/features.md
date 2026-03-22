# AI Stack — Feature Status

**Last Updated:** 2026-03-21

A human-readable summary of what this stack provides, ordered from most to least foundational. Intended for communicating capabilities to a non-technical audience and tracking progress toward a complete platform.

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
- _Powered by: OpenWebUI_

### `[X]` Multi-Model Inference Routing
The stack runs multiple AI models simultaneously and routes requests to the right one automatically. Models can live on different machines.
- Models on the controller workstation (local), M1 MacBook (remote), and Alienware GPU (remote)
- A single API endpoint handles all models — callers choose by model name
- Transparent failover routing when a node is offline
- _Powered by: LiteLLM_

### `[X]` Retrieval-Augmented Generation (RAG)
AI responses can be grounded in a private knowledge base rather than relying solely on the model's training data.
- Ingest documents into the knowledge library
- Questions automatically retrieve relevant context before answering
- Vector similarity search across all indexed content
- _Powered by: Knowledge Index Service + Qdrant_

### `[X]` AI Workflow Builder
Non-developers can build multi-step AI pipelines visually — chain models, tools, and knowledge sources together without writing code.
- Drag-and-drop flow authoring
- Supports RAG pipelines, tool-calling chains, and agent workflows
- REST API for programmatic flow execution
- _Powered by: Flowise_

### `[X]` Distributed GPU Inference
AI inference workload is distributed across multiple machines with dedicated GPUs, increasing throughput and enabling larger models to run simultaneously.
- Alienware (GTX 970M, 3GB VRAM) running `llama3.2:3b-instruct-q4_K_M`
- MacBook M1 (Apple Silicon, unified memory) running `llama3.1:8b-instruct-q4_K_M`
- Controller workstation running local CPU-based models
- New nodes added via a single setup script

### `[X]` Authentication and Access Control
All services require login. External identity providers can be connected via SSO.
- Single sign-on across all web interfaces
- OAuth2/OIDC support (Google Workspace, GitHub, LDAP, etc.)
- Forward-auth at the reverse proxy — no per-service login configuration
- _Powered by: Authentik + Traefik_

### `[X]` Observability — Metrics and Dashboards
Operators can see the health, performance, and resource usage of every service in real time.
- Per-service CPU, memory, and request rate metrics
- Pre-built dashboards out of the box
- Alerting rules for degraded or failed services
- _Powered by: Prometheus + Grafana_

### `[X]` Centralized Log Aggregation
All service logs from all nodes are collected in one place, searchable by service, level, time range, and content.
- Logs from controller and all remote inference nodes
- Structured log queries
- 7-day retention by default (configurable)
- _Powered by: Loki + Promtail_

### `[X]` Secure Reverse Proxy with TLS
All external traffic is encrypted. Services are not directly exposed; all requests pass through a single entry point.
- Automatic HTTPS with local CA certificate
- Path and hostname-based routing to all services
- Authentication middleware applied globally
- _Powered by: Traefik_

### `[X]` Automated Backup
The full stack state — databases, vector store, model files, configs — can be backed up with a single command and restored from backup.
- Covers: PostgreSQL, Qdrant, Flowise, Grafana, Ollama model cache
- Timestamped archives
- Restore procedure documented

---

## Partially Available Features

### `[-]` MCP Tool Integration
AI agents can call external tools (web search, file read, API calls) during a conversation by following the Model Context Protocol standard.
- REST API for knowledge search and document ingestion: **available**
- MCP SSE/HTTP transport for agent tool-calling: **pending** (Phase 7)
- _Powered by: Knowledge Index Service_

### `[-]` Local GPU Acceleration (Controller)
The controller's own NVIDIA GPU (RTX 3070 Ti, 8GB VRAM) can be used for high-speed inference.
- GPU configured and CDI passthrough enabled: **done**
- Ollama running on the GPU: **done**
- vLLM for larger GPU-optimized models: **pending** (Phase 8)

### `[-]` Worker Node Security
Remote inference nodes (M1, Alienware) are functional but not hardened.
- Ollama port (11434) reachable on LAN — no authentication enforced on nodes directly
- Controller access is protected; node-to-node channel is not
- Firewall rules and Ollama API key enforcement: **pending**

---

## Pending Features

### `[ ]` Security Audit Tool
A script (and future admin dashboard tool) that checks all ports, API keys, TLS configurations, and auth enforcement across the controller and all registered nodes, and reports any gaps.

### `[ ]` vLLM GPU Inference
Running GPU-optimized large language models on the controller's RTX 3070 Ti for maximum local performance on demanding tasks.

### `[ ]` Inference Node Hardening
Lock down remote Ollama endpoints with API keys or firewall rules so only the controller can reach them on port 11434.

---

## Deferred Features

### `[D]` Peer Node Topology
Each node runs the complete stack independently. Nodes share inference capacity, discover each other's knowledge libraries, and continue working if any peer goes offline. (Phase 10)

### `[D]` Operator Dashboard
A unified web UI for users, teams, and administrators with tabs for user contexts, system health, node management, and admin operations. (Future Features)

### `[D]` Dynamic Node Registration
Inference workers automatically announce themselves to the controller when they start, and are removed when they go offline — no manual config.json updates required. (Phase 9 deferred)

### `[D]` Federated Knowledge Search
A query sent to one node's knowledge base automatically fans out to all peer nodes' libraries and returns a merged result set. (Phase 10)

### `[D]` Team-Shared Chat and Context
Conversation history, user accounts, and conversation context synchronized across all peer nodes so any team member can continue a conversation on any device. (Phase 10+)

### `[D]` Knowledge Library Governance
Automated content classification, safety filtering, PII detection, and ethics alignment checks applied at ingestion time across all knowledge bases. (Future Features)

### `[D]` Model A/B Testing
Route a fraction of requests to a candidate model and compare quality against the default — built into the LiteLLM routing layer. (Future Features)
