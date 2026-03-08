# Knowledge Index Service — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for building and operating the Knowledge Index Service — the standalone FastAPI microservice that provides query-to-volume routing and library metadata access for the AI stack.

---

## Table of Contents

1. API Design
2. Routing and Caching
3. Data Management
4. Observability
5. Reliability

## References

- FastAPI Documentation: https://fastapi.tiangolo.com/
- OpenAPI Specification: https://spec.openapis.org/oas/v3.1.0
- Qdrant Python Client: https://github.com/qdrant/qdrant-client

---

# 1 API Design

- Version all endpoints under `/v1/`; never expose unversioned routes
- Follow REST conventions: `GET` for reads, `POST` for actions, consistent resource naming
- Return structured error responses with `detail` and `code` fields; never surface raw exceptions
- Generate OpenAPI schema automatically via FastAPI; keep it accurate and up to date
- Keep the API surface minimal: implement only what consumers need today

# 2 Routing and Caching

- The primary responsibility of this service is query→library→topic routing — keep this path fast
- Implement an in-memory cache for route results with a configurable TTL (default: 60 seconds)
- Invalidate cache entries on library ingestion events — stale routes after ingestion are a correctness issue
- Do not cache ingestion results or health checks
- Log cache hits and misses as INFO-level events for diagnosability
- Use semantic similarity (Qdrant) for routing, not keyword matching — route quality depends on embedding model consistency

# 3 Data Management

- PostgreSQL is the source of truth for library metadata (manifest data, topic index, document tracking)
- Qdrant stores pre-computed embeddings per library collection (`{library-name}-{topic}` naming convention)
- Library ingestion is idempotent: re-ingesting the same version must produce the same state
- Validate library manifests against the schema before any ingestion step; reject invalid packages cleanly
- Record ingestion events in PostgreSQL with timestamps, library version, and outcome

# 4 Observability

- Expose a `/v1/health` endpoint returning JSON `{"status": "ok"}` with HTTP 200
- Log at structured JSON format; include `library`, `topic`, `latency_ms`, and `cached` fields on route responses
- Expose Prometheus metrics: `route_requests_total`, `route_latency_seconds`, `cache_hit_ratio`, `ingestion_total`
- Surface library count and last-ingestion timestamp in `GET /v1/libraries`

# 5 Reliability

- The service is stateless between requests — all state is in PostgreSQL and Qdrant
- On startup, wait for PostgreSQL and Qdrant to be healthy before accepting requests (use readiness probe logic)
- If PostgreSQL or Qdrant is unreachable, return 503 from `/v1/health`; do not crash the service
- Set connection pool limits for both PostgreSQL and Qdrant clients; tune based on concurrency needs
- Container restart policy: `always`
