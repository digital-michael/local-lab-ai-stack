# Loki — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating Loki as the log aggregation backend.

---

## Table of Contents

1. Deployment
2. Schema and Storage
3. Log Ingestion
4. Querying
5. Reliability

## References

- Loki Documentation: https://grafana.com/docs/loki/latest/
- Loki Best Practices: https://grafana.com/docs/loki/latest/best-practices/
- LogQL Reference: https://grafana.com/docs/loki/latest/logql/

---

# 1 Deployment

- Deploy Loki in single-binary mode for simplicity; scale to microservices mode only if needed
- Mount a persistent volume for log chunk storage at `/loki`
- Loki is designed for labels, not full-text indexing — keep label cardinality low
- Set rate limits (`ingestion_rate_mb`, `ingestion_burst_size_mb`) appropriate to the stack's log volume
- Pin the image to a specific version; Loki storage schema versions are not always backward-compatible

# 2 Schema and Storage

- Use the `boltdb-shipper` index type with a filesystem store for single-node deployments
- Set the schema config `from` date to the deployment date; never change schema for historical periods
- Configure chunk encoding to `snappy` for a good compression/speed tradeoff
- Set retention via the compactor: `retention_enabled: true` with `retention_period: 720h` (30 days)
- Plan storage capacity: compressed logs use ~10:1 ratio; estimate based on container log volume

# 3 Log Ingestion

- All logs arrive via Promtail (the log shipping agent); Loki does not pull logs
- Labels should describe the source, not the content: `{service="litellm", node="gpu-01"}`
- Avoid high-cardinality labels: do not use request IDs, user IDs, or timestamps as labels
- Use pipeline stages in Promtail to extract structured fields from log lines
- Set tenant ID to `ai-stack` for multi-tenancy isolation (even in single-tenant mode, for future flexibility)

# 4 Querying

- Use LogQL for log queries in Grafana: `{service="vllm"} |= "error"`
- Filter by labels first, then apply line filters — this is the most efficient query pattern
- Use `rate()` and `count_over_time()` for log-based metrics (error rates, request counts)
- Set query timeouts to prevent runaway queries: `query_timeout: 5m`
- Limit query concurrency to protect Loki's resources

# 5 Reliability

- Loki is append-only; data loss on crash is limited to the current in-memory chunk
- Set `Restart=always` in the systemd quadlet
- Monitor Loki's ingestion rate and query latency via its `/metrics` endpoint
- Back up the `/loki` data directory for disaster recovery
- Health check: HTTP 200 on `/ready` — testable from outside the container; the Grafana Loki image is **distroless** (no shell, no curl, no wget). Do NOT configure a container-internal `HealthCmd` — it will always fail. Remove `HealthCmd` and rely on systemd process supervision via the quadlet's `Restart=always`.
