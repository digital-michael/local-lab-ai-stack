# Framework Components — Agent Guidelines

## Scope

This directory contains normative documentation for every framework component in the AI stack. Each subdirectory corresponds to a single component (service, runtime, or practice area) and contains three files:

| File | Purpose |
|---|---|
| `best_practices.md` | Vendor-recommended and industry-standard practices for the component |
| `security.md` | Security hardening, access control, and vulnerability guidance |
| `guidance.md` | Project-specific preferences and opinionated decisions |

## Compliance

The contents of this directory define **strong guidelines** that must be adhered to for any and all changes to this repository.

When proposing, reviewing, or implementing changes that involve a component listed here, you **must**:

1. **Read** the relevant component's `best_practices.md`, `security.md`, and `guidance.md` before making changes.
2. **Follow** the guidance unless there is a documented, justified reason to deviate.
3. **Flag deviations** explicitly — if a change contradicts guidance in these files, note the deviation and the rationale in the commit or pull request.
4. **Update** these files when the project's practices evolve. Guidance must stay current with implementation reality.

## Components

| Directory | Component |
|---|---|
| `authentik/` | Identity provider and SSO gateway |
| `flowise/` | Low-code AI workflow builder |
| `grafana/` | Visualization and dashboarding |
| `knowledge-index/` | Query-to-library routing microservice (FastAPI) |
| `litellm/` | LLM API gateway and proxy |
| `llamacpp/` | CPU-based GGUF model inference |
| `loki/` | Log aggregation backend |
| `openwebui/` | Chat interface for end users |
| `podman/` | Rootless container runtime and systemd quadlets |
| `postgresql/` | Relational database for service state |
| `prometheus/` | Metrics collection and alerting |
| `promtail/` | Log shipping agent |
| `qdrant/` | Vector database for RAG embeddings |
| `shell-scripting/` | Bash conventions for project scripts |
| `traefik/` | Reverse proxy and TLS termination |
| `vllm/` | GPU-accelerated model inference |

## Naming Convention

Files named `README-agent.md` (this file pattern) are specifically intended as directives for LLM agents operating on this repository. They are distinct from standard `README.md` files, which serve a human audience.
