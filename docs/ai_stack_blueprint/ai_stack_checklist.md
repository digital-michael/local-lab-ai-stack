# AI Stack — Implementation Checklist
**Last Updated:** 2026-03-08 UTC

## Purpose
Master task tracker for the AI Multivolume RAG Platform. Covers blockers, deferrable work, future features, and open considerations. Updated as items are resolved.

Cross-references: [architecture](ai_stack_architecture.md) · [implementation](ai_stack_implementation.md) · [configuration](ai_stack_configuration.md)

---

## Table of Contents

1. Configuration System (configure.sh + JSON)
2. Blockers
3. Deferrable
4. Future Features
5. Open Considerations

---

# 1 Configuration System

The `configure.sh` script and its JSON config file are the primary mechanism for standing up and maintaining the stack. The JSON file is the machine-readable single source of truth for all service configuration. The markdown configuration doc describes the schema and rationale.

### Tasks

- [ ] **Design JSON config schema** — define structure for services, images, env vars, ports, volumes, secrets, dependencies, resource limits, health checks
- [ ] **Create `scripts/configure.sh`** — CRUD operations against the JSON config file
  - [x] `configure.sh init` — generate default config.json with all services
  - [x] `configure.sh set <path> <value>` — update a config value
  - [x] `configure.sh get <path>` — read a config value
  - [x] `configure.sh validate` — check config completeness (all TBDs resolved, required fields present)
  - [x] `configure.sh generate-quadlets` — produce systemd quadlet files from config
  - [x] `configure.sh generate-secrets` — prompt for and provision Podman secrets from config inventory
- [x] **Create default `configs/config.json`** — populated with current documented defaults
- [ ] **Support multi-environment configs** — `configs/dev.json`, `configs/prod.json`
- [ ] **Update `deploy-stack.sh`** — call `configure.sh validate` and `configure.sh generate-quadlets` before deployment
- [ ] **Update `ai_stack_configuration.md`** — reframe as schema documentation; values live in config.json

---

# 2 Blockers (required before first deployment)

These collapse into the configuration system above. Tracked individually for visibility.

- [ ] **Pin all container image tags/digests** — resolve all TBD entries (Configuration §1)
- [ ] **Finalize environment variables per service** — confirm defaults, secret references (Configuration §2)
- [ ] **Confirm volume mount paths per container** — verify host/container path mappings (Configuration §6)
- [ ] **Provision Podman secrets** — create secrets from inventory; integrate with configure.sh (Implementation §1)
- [ ] **Generate quadlet unit files** — from config.json via configure.sh (Implementation §2)
- [ ] **Define service dependency/startup order** — encode as `depends_on` in config.json (Implementation §3)
- [ ] **Resolve reverse proxy service** — no proxy container defined; port 9443 TLS has no backing service (see Consideration #23)
- [ ] **Resolve Knowledge Index Service** — listed as component but no image/repo/spec exists (see Consideration #24)

---

# 3 Deferrable (address incrementally post-deployment)

- [ ] **Tune resource limits** — CPU/memory/GPU per container after observing baseline (Configuration §3)
- [ ] **Add health checks and readiness probes** — incrementally per service (Configuration §10)
- [ ] **Configure GPU passthrough / CDI** — required only for GPU nodes (Implementation §4)
- [ ] **Authentik OIDC integration** — redirect URIs, client config, scopes (Implementation §5)
- [ ] **Define library manifest YAML schema** — JSON Schema for .ai-library packages (Implementation §6)
- [ ] **Create Prometheus alerting rules** — after monitoring stack is operational (Implementation §7)
- [ ] **Document backup and restore procedures** — including restore runbook (Implementation §8)
- [ ] **Build troubleshooting guide** — incrementally from operational experience (Implementation §9)
- [ ] **TLS certificate setup** — self-signed CA vs trusted CA for port 9443 (Configuration §9)
- [ ] **Add config subdirectories to install.sh** — `configs/tls`, `configs/grafana`, `configs/prometheus`, `configs/promtail`
- [ ] **Define log retention/rotation policy** — Loki storage unbounded without config (see Consideration #26)
- [ ] **Decide Flowise database backend** — local SQLite path vs shared PostgreSQL (see Consideration #25)

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
| 23 | **Reverse proxy service** — port 9443 TLS termination referenced but no proxy container (Traefik/Caddy/nginx) defined in component list or config | Open | — |
| 24 | **Knowledge Index Service** — listed as core component but no image, repository, or specification exists; needs to be built or an existing tool identified | Open | — |
| 25 | **Flowise database backend** — config shows local `DATABASE_PATH=/data/flowise` (SQLite); should it share the PostgreSQL instance? | Open | — |
| 26 | **Log retention policy** — Loki storage will grow unbounded without a retention/compaction config | Open | — |
| 27 | **Multi-environment support** — only one set of config values exists; no dev/staging/prod separation | Open | Addressed by configure.sh multi-env support |
