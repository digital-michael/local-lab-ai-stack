# Qdrant — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating Qdrant as the vector database for RAG retrieval.

---

## Table of Contents

1. Deployment
2. Collection Design
3. Performance Tuning
4. Data Management
5. Reliability

## References

- Qdrant Documentation: https://qdrant.tech/documentation/
- Qdrant GitHub: https://github.com/qdrant/qdrant

---

# 1 Deployment

- Deploy as a single-node instance initially; plan for distributed sharding as data grows
- Use persistent storage mounted at `/qdrant/storage` — data loss requires full re-embedding
- Set an API key for all access; inject via Podman secrets
- Qdrant exposes REST (6333) and gRPC (6334) — prefer gRPC for high-throughput programmatic access
- Pin the image version; Qdrant storage format changes between major versions

# 2 Collection Design

- Create one collection per knowledge library — this provides natural isolation and independent lifecycle management
- Set vector dimensions to match the embedding model (1024 for `BAAI/bge-large-en-v1.5`)
- Use cosine similarity as the default distance metric for text embeddings
- Enable payload indexing on frequently filtered fields (e.g., `library_name`, `topic`, `document_id`)
- Store metadata as payloads alongside vectors for context during retrieval

# 3 Performance Tuning

- Set HNSW index parameters appropriate for the dataset size:
  - `m=16` and `ef_construct=100` for datasets under 1M vectors
  - Increase `m` and `ef_construct` for larger datasets at the cost of memory
- Use `ef` (search parameter) to trade accuracy for speed at query time
- Enable quantization (scalar or product) for large collections to reduce memory footprint
- Monitor query latency — p99 should stay under 100ms for interactive RAG workflows
- Allocate sufficient RAM: Qdrant keeps HNSW indexes in memory

# 4 Data Management

- Implement a consistent naming scheme for collections: `{library-name}-{version}`
- Include checksums or version identifiers in payloads to detect stale embeddings
- When re-embedding a library, create a new collection and swap atomically rather than updating in place
- Use Qdrant's snapshot API for point-in-time backups
- Set collection-level retention policies if applicable

# 5 Reliability

- Health check on `/healthz` at 30-second intervals
- Set `Restart=always` in the systemd quadlet
- Qdrant is stateful — prioritize data durability; use SSD storage for predictable I/O
- Monitor disk usage; Qdrant does not compact automatically in all configurations
- Back up snapshots to `$AI_STACK_DIR/backups/` daily
