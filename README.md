# AI Stack — Local LLM Infrastructure

A self-hosted AI infrastructure stack running on rootless Podman with systemd quadlets. Designed for local inference, RAG-based knowledge retrieval, workflow automation, and full observability — all without cloud dependencies.

## What This Is

This repo contains the architecture, configuration, tooling, and reference documentation needed to deploy and operate a local AI stack comprising:

- **OpenWebUI** — chat interface for end users
- **Flowise** — low-code AI workflow builder
- **LiteLLM** — LLM API gateway and model proxy
- **vLLM** — GPU-accelerated model inference
- **llama.cpp** — CPU-based GGUF model inference
- **Qdrant** — vector database for RAG embeddings
- **PostgreSQL** — relational database for service state
- **Authentik** — identity provider and SSO (deferrable)
- **Prometheus + Grafana** — metrics and dashboards
- **Loki + Promtail** — log aggregation and shipping

All services run as rootless Podman containers managed by systemd quadlets on a single node.

## Repository Structure

```
.
├── README.md                          # This file
├── configs/
│   └── config.json                    # Single source of truth for all service definitions
├── scripts/
│   ├── configure.sh                   # CRUD on config, quadlet/secret generation
│   ├── deploy.sh                      # Orchestrates full deployment sequence
│   ├── install.sh                     # One-time system prerequisites and directory setup
│   └── validate-system.sh             # Pre-flight environment checks
└── docs/
    ├── ai_stack_blueprint/
    │   ├── ai_stack_architecture.md   # System design, component roles, data flows
    │   ├── ai_stack_implementation.md # Step-by-step deployment procedures
    │   ├── ai_stack_configuration.md  # Configuration schema and rationale
    │   └── ai_stack_checklist.md      # Task tracker: blockers, deferrables, future work
    └── library/
        ├── framework_components/      # Per-component reference documentation
        │   ├── README-agent.md        # Governance policy for LLM agents
        │   ├── openwebui/             # best_practices.md, security.md, guidance.md
        │   ├── flowise/
        │   ├── litellm/
        │   ├── vllm/
        │   ├── llamacpp/
        │   ├── qdrant/
        │   ├── postgresql/
        │   ├── authentik/
        │   ├── prometheus/
        │   ├── grafana/
        │   ├── loki/
        │   ├── promtail/
        │   ├── podman/
        │   └── shell-scripting/
        └── actions/                   # Agent skill definitions (SKILL.md)
            └── generate-playbook/     # Operational playbook generation skill
```

## Prerequisites

- Linux (Fedora/RHEL recommended)
- Podman v5.7+
- `jq`
- NVIDIA GPU + drivers (optional, for vLLM)

## Quick Start

```bash
# Check prerequisites
./scripts/validate-system.sh

# Install dependencies and create directory layout
./scripts/install.sh

# Review and edit service configuration
vi configs/config.json

# Generate quadlets and deploy
./scripts/deploy.sh
```

Run any script with `--help` for usage details.

## Documentation

Start with the **architecture doc** for the full picture, then consult the others as needed:

| Document | Purpose |
|---|---|
| [Architecture](docs/ai_stack_blueprint/ai_stack_architecture.md) | System design, component roles, data flows, network topology |
| [Implementation](docs/ai_stack_blueprint/ai_stack_implementation.md) | Deployment procedures: quadlets, secrets, GPU passthrough, OIDC |
| [Configuration](docs/ai_stack_blueprint/ai_stack_configuration.md) | Schema documentation for `configs/config.json` |
| [Checklist](docs/ai_stack_blueprint/ai_stack_checklist.md) | Task tracker with blockers, deferrables, and future iterations |

Per-component best practices, security hardening, and project-specific guidance live under `docs/library/framework_components/`.

## Status

This project is **deployed and operational** on the CENTAURI cluster. All core services are running as rootless Podman containers managed by systemd quadlets. The test suite (layers 0–4) passes. Outstanding items are tracked in the [checklist](docs/ai_stack_blueprint/ai_stack_checklist.md) and [features](docs/features.md).
