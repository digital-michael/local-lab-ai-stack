# PostgreSQL — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating PostgreSQL as the metadata database for the AI stack.

---

## Table of Contents

1. Deployment
2. Schema and Data Design
3. Performance Tuning
4. Backup and Recovery
5. Reliability

## References

- PostgreSQL Documentation: https://www.postgresql.org/docs/current/
- PostgreSQL Wiki — Don't Do This: https://wiki.postgresql.org/wiki/Don't_Do_This
- pgTune: https://pgtune.leopard.in.ua/

---

# 1 Deployment

- Use the official PostgreSQL Docker image from Docker Hub
- Mount the data directory (`/var/lib/postgresql/data`) on persistent storage — this is the most critical volume in the stack
- Inject `POSTGRES_PASSWORD` via Podman secrets; never set it in plaintext
- Set `POSTGRES_USER` and `POSTGRES_DB` via environment variables
- Use a dedicated database per application (LiteLLM, Authentik) or a shared database with schema-level separation

# 2 Schema and Data Design

- Use schemas to separate concerns: `litellm`, `authentik`, `knowledge_index` within the same database
- Apply migrations via versioned scripts; never modify production schemas manually
- Use appropriate data types: `UUID` for identifiers, `TIMESTAMPTZ` for timestamps, `JSONB` for flexible metadata
- Create indexes on frequently queried columns; avoid over-indexing on write-heavy tables
- Define foreign key constraints for referential integrity

# 3 Performance Tuning

- Use pgTune to generate initial configuration based on available RAM and CPU
- Key settings to adjust from defaults:
  - `shared_buffers`: 25% of available RAM (e.g., 1 GB for 4 GB allocation)
  - `effective_cache_size`: 75% of available RAM
  - `work_mem`: 4–16 MB depending on query complexity
  - `maintenance_work_mem`: 256 MB–1 GB for vacuum and index builds
- Enable `pg_stat_statements` for query performance monitoring
- Set `max_connections` based on actual client count; use connection pooling (PgBouncer) if needed
- Run `ANALYZE` after bulk data imports

# 4 Backup and Recovery

- Run `pg_dump` daily via cron; store compressed dumps in `$AI_STACK_DIR/backups/`
- Retain at least 7 days of backups
- Test restore procedures periodically — an untested backup is not a backup
- For point-in-time recovery, enable WAL archiving to a separate volume
- Consider `pg_basebackup` for full physical backups of large databases

# 5 Reliability

- Health check with `pg_isready -U aistack` at 30-second intervals
- Set `Restart=always` in the systemd quadlet
- PostgreSQL is a dependency for LiteLLM and Authentik — it must start first
- Monitor for long-running queries, dead tuples (bloat), and connection saturation
- Enable auto-vacuum and monitor its effectiveness
