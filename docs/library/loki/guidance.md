# Loki — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for Loki within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- No host port published — Loki is internal only, accessed by Grafana and Promtail via Podman DNS
- Data volume at `$AI_STACK_DIR/data/loki`; config at `$AI_STACK_DIR/configs/loki/`
- Resource limits: 1 core, 2 GB RAM
- No external dependencies — Loki can start independently

# 2 Configuration Choices

- Single-binary mode (not microservices) — appropriate for single-node deployment
- `boltdb-shipper` + filesystem store for index and chunks
- Retention: 30 days via compactor
- Chunk encoding: `snappy` compression
- Tenant ID: `ai-stack` (single-tenant, but configured for future flexibility)
- Schema version: `v13` (latest stable at time of writing)

# 3 Integration Patterns

- Promtail → Loki (pushes log streams)
- Grafana → Loki (queries logs via LogQL)
- All AI stack containers → Promtail → Loki (log pipeline)
- Prometheus does not interact with Loki directly (separate data paths)

# 4 Operational Notes

- Loki is part of the observability stack — it's critical for debugging but not for inference
- If Loki is down, logs are buffered (and potentially dropped) by Promtail
- Monitor Loki's ingestion rate and storage growth via Prometheus
- When adding new services, ensure Promtail is configured to ship their logs
