# Qdrant — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for Qdrant within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Host ports 6333 (REST) and 6334 (gRPC) exposed for inter-service communication
- Persistent storage at `$AI_STACK_DIR/qdrant/` mounted to `/qdrant/storage`
- Resource limits: 2 cores, 8 GB RAM

# 2 Configuration Choices

- API key provisioned via Podman secret (`qdrant_api_key`)
- One collection per knowledge library, named after the library
- Vector dimensions: 1024 (matching `BAAI/bge-large-en-v1.5`)
- Distance metric: cosine similarity
- HNSW defaults: `m=16`, `ef_construct=100` — sufficient for initial library sizes

# 3 Integration Patterns

- Knowledge Index Service → Qdrant (writes embeddings, creates collections)
- Flowise → Qdrant (reads for RAG retrieval in workflows)
- Qdrant does not initiate connections to other services
- All access authenticated via API key

# 4 Operational Notes

- Qdrant is a critical stateful service — data loss requires complete re-embedding which is expensive
- Daily snapshots to `$AI_STACK_DIR/backups/` via the snapshot API
- Monitor disk usage aggressively; vector storage grows with each library addition
- When upgrading Qdrant, check for storage format migrations — test with a snapshot restore first
- Distributed sharding (multi-node Qdrant) is a future iteration; single-node is sufficient initially
