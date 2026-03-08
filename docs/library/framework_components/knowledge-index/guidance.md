# Knowledge Index Service — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for the Knowledge Index Service within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Implementation Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Internal port: 8900 (not published to host)
- No persistent data volume; library volumes mounted read-only from `$AI_STACK_DIR/libraries/`
- Resource limits: 1 CPU, 512 MB RAM
- Position 8 in the startup order: depends on PostgreSQL (position 3) and Qdrant (position 4)
- Decision: D-012 — standalone FastAPI microservice selected over Qdrant plugin, Flowise workflow, and LiteLLM integration

# 2 Implementation Choices

- **Python/FastAPI** — pragmatic MVP choice; async-native, auto-generates OpenAPI
- **REST `/v1/`** — versioned API; gRPC deferred to future iteration
- **In-memory cache** — TTL 60s default; configurable via environment variable `ROUTE_CACHE_TTL`
- **Discovery** — MVP implements localhost profile only (filesystem scan at startup + 300s interval)
- **Qdrant collection naming** — `{library-name}_{topic}` (underscore separator; hyphens not permitted in all Qdrant versions)
- **PostgreSQL schema** — `knowledge_index` schema within the shared `aistack` database

# 3 Integration Patterns

- **Flowise → Knowledge Index:** Flowise calls `POST /v1/route` to determine which library collection to query before issuing a Qdrant vector search
- **Knowledge Index → PostgreSQL:** Library metadata, topic index, document tracking stored in `knowledge_index` schema
- **Knowledge Index → Qdrant:** Vector similarity search for query routing; collections named `{library}_{topic}`
- **Library ingestion:** Triggered by `POST /v1/ingest` with library name; the service reads from the mounted library volume path

# 4 Operational Notes

- This service is **deferrable for MVP deployment** — the stack functions without it if Flowise is configured to query Qdrant directly
- Implementation deferred until after Phase 5 (deployment artifacts); tracked in checklist deferrable items
- When implementing, start with the localhost discovery profile and a single library to validate the routing pipeline end-to-end
- FastAPI dev server (`uvicorn --reload`) for development; gunicorn + uvicorn workers for production
- Log library discovery scan results at INFO level each cycle — useful for diagnosing why a library is not being routed to
