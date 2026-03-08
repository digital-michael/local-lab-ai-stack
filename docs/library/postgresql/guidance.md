# PostgreSQL — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for PostgreSQL within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Host port 5432 maps to container port 5432
- Persistent storage at `$AI_STACK_DIR/postgres/` mounted to `/var/lib/postgresql/data`
- Resource limits: 2 cores, 4 GB RAM
- PostgreSQL is the **first** service to start in the dependency chain

# 2 Configuration Choices

- Single database `aistack` with schema-level separation per application
- User `aistack` as the primary application user (not superuser for remote connections)
- Password injected via Podman secret (`postgres_password`)
- Use pgTune defaults for 4 GB RAM, 2 CPU, SSD storage type
- `max_connections=100` — sufficient for the limited number of internal services

# 3 Integration Patterns

- LiteLLM → PostgreSQL (model config, usage tracking, spend logging)
- Authentik → PostgreSQL (identity provider data)
- Knowledge Index → PostgreSQL (library metadata, document tracking)
- Flowise may use PostgreSQL in the future (currently uses local SQLite — see checklist consideration #25)

# 4 Operational Notes

- PostgreSQL is the most critical stateful dependency — if it's down, LiteLLM and Authentik fail
- Daily `pg_dump` backups to `$AI_STACK_DIR/backups/`; retain 7 days
- Monitor with `pg_isready` health checks at 30-second intervals
- Watch for connection count approaching `max_connections`; add PgBouncer if needed
- WAL archiving deferred to future iteration; `pg_dump` is sufficient initially
