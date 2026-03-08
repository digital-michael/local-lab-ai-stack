# AI Stack Implementation Guide
**Last Updated:** 2026-03-08 UTC

## Purpose
This document contains concrete implementation details, configurations, and deployment artifacts for the AI Multivolume RAG Platform. It is the companion to [ai_stack_architecture.md](ai_stack_architecture.md), which defines the high-level design.

An LLM agent can read this document to generate deployment configurations, create quadlet files, and configure services.

---

## Table of Contents

1. Container Images and Versions
2. Environment Variables
3. Volume Mounts
4. Secrets Management
5. Quadlet Unit Files
6. Service Dependency Order
7. Resource Limits
8. Health Checks
9. GPU Passthrough Configuration
10. Authentik OIDC Integration
11. Library Manifest Schema
12. Alerting Rules
13. Backup and Restore
14. Troubleshooting

---

# 1 Container Images and Versions

> **Status:** Blocker — required before first deployment.

| Service | Image | Tag/Digest | Notes |
|---------|-------|------------|-------|
| OpenWebUI | `ghcr.io/open-webui/open-webui` | TBD | |
| LiteLLM | `ghcr.io/berriai/litellm` | TBD | |
| vLLM | `vllm/vllm-openai` | TBD | GPU inference |
| llama.cpp | `ghcr.io/ggerganov/llama.cpp` | TBD | CPU/Mac inference |
| Qdrant | `docker.io/qdrant/qdrant` | TBD | |
| PostgreSQL | `docker.io/library/postgres` | TBD | |
| Flowise | `docker.io/flowiseai/flowise` | TBD | |
| Authentik | `ghcr.io/goauthentik/server` | TBD | |
| Prometheus | `docker.io/prom/prometheus` | TBD | |
| Grafana | `docker.io/grafana/grafana` | TBD | |
| Loki | `docker.io/grafana/loki` | TBD | |
| Promtail | `docker.io/grafana/promtail` | TBD | |

Pin all images to specific tags or digests before deployment.

---

# 2 Environment Variables

> **Status:** Blocker — required before first deployment.

### PostgreSQL

```env
POSTGRES_USER=aistack
POSTGRES_PASSWORD=<secret>
POSTGRES_DB=aistack
```

### LiteLLM

```env
LITELLM_MASTER_KEY=<secret>
DATABASE_URL=postgresql://aistack:<secret>@postgres.ai-stack:5432/aistack
```

### Qdrant

```env
QDRANT__SERVICE__API_KEY=<secret>
```

### vLLM

```env
MODEL_NAME=llama3.1-8b
TENSOR_PARALLEL_SIZE=1
```

### llama.cpp

```env
MODEL_PATH=/models/llama3.1-8b.gguf
CONTEXT_SIZE=4096
```

### OpenWebUI

```env
OPENAI_API_BASE=http://litellm.ai-stack:9000
OPENAI_API_KEY=<secret>
```

### Flowise

```env
FLOWISE_USERNAME=admin
FLOWISE_PASSWORD=<secret>
DATABASE_PATH=/data/flowise
```

Replace all `<secret>` values using Podman secrets (see §4).

---

# 3 Volume Mounts

> **Status:** Blocker — required before first deployment.

| Container | Host Path | Container Path | Mode |
|-----------|-----------|----------------|------|
| vLLM | `$AI_STACK_DIR/models` | `/models` | ro |
| llama.cpp | `$AI_STACK_DIR/models` | `/models` | ro |
| Qdrant | `$AI_STACK_DIR/qdrant` | `/qdrant/storage` | rw |
| PostgreSQL | `$AI_STACK_DIR/postgres` | `/var/lib/postgresql/data` | rw |
| Knowledge Index | `$AI_STACK_DIR/libraries` | `/libraries` | rw |
| Grafana | `$AI_STACK_DIR/configs/grafana` | `/etc/grafana` | ro |
| Prometheus | `$AI_STACK_DIR/configs/prometheus` | `/etc/prometheus` | ro |
| Loki | `$AI_STACK_DIR/logs/loki` | `/loki` | rw |
| Promtail | `$AI_STACK_DIR/configs/promtail` | `/etc/promtail` | ro |

`$AI_STACK_DIR` defaults to `$HOME/ai-stack` for rootless Podman deployments.

Use the `:Z` volume suffix for SELinux relabeling on Fedora/RHEL hosts.

---

# 4 Secrets Management

> **Status:** Blocker — required before first deployment.

Use Podman secrets to inject sensitive values. Never store secrets in plain text configuration files.

### Create secrets

```bash
echo "<value>" | podman secret create postgres_password -
echo "<value>" | podman secret create litellm_master_key -
echo "<value>" | podman secret create qdrant_api_key -
echo "<value>" | podman secret create openwebui_api_key -
echo "<value>" | podman secret create flowise_password -
```

### Reference in quadlet files

```ini
[Container]
Secret=postgres_password,type=env,target=POSTGRES_PASSWORD
```

### TLS certificates

Store under `$AI_STACK_DIR/configs/tls/` and mount into the reverse proxy container. Use either a self-signed CA for internal traffic or certificates from a trusted CA for external access.

---

# 5 Quadlet Unit Files

> **Status:** Blocker — required before first deployment.

Quadlet files are placed in `~/.config/containers/systemd/` for rootless Podman.

### Network quadlet

```ini
# ai-stack.network
[Network]
NetworkName=ai-stack-net
Driver=bridge
Internal=false
```

### Example: PostgreSQL quadlet

```ini
# postgres.container
[Unit]
Description=AI Stack PostgreSQL
After=ai-stack-network.service

[Container]
Image=docker.io/library/postgres:TBD
ContainerName=postgres
Network=ai-stack-net
Volume=%h/ai-stack/postgres:/var/lib/postgresql/data:Z
Secret=postgres_password,type=env,target=POSTGRES_PASSWORD
Environment=POSTGRES_USER=aistack
Environment=POSTGRES_DB=aistack
PublishPort=5432:5432
HealthCmd=pg_isready -U aistack
HealthInterval=30s
HealthRetries=3

[Service]
Restart=always

[Install]
WantedBy=default.target
```

### Quadlet files to create

- `ai-stack.network`
- `postgres.container`
- `qdrant.container`
- `litellm.container`
- `vllm.container`
- `llamacpp.container`
- `flowise.container`
- `openwebui.container`
- `authentik.container`
- `prometheus.container`
- `grafana.container`
- `loki.container`
- `promtail.container`

---

# 6 Service Dependency Order

> **Status:** Blocker — required before first deployment.

Start services in this order:

```
1. ai-stack-net (network)
2. PostgreSQL
3. Qdrant
4. Authentik
5. LiteLLM
6. vLLM / llama.cpp
7. Knowledge Index
8. Flowise
9. OpenWebUI
10. Prometheus → Grafana → Loki → Promtail
```

Express dependencies using `After=` and `Requires=` directives in quadlet unit files. Services that depend on PostgreSQL or Qdrant should not start until those services pass their health checks.

---

# 7 Resource Limits

> **Status:** Deferrable — tune after initial deployment.

Example limits (adjust per node capacity):

| Container | CPU | Memory | GPU |
|-----------|-----|--------|-----|
| vLLM | 4 cores | 24 GB | 1 GPU |
| llama.cpp | 4 cores | 16 GB | — |
| PostgreSQL | 2 cores | 4 GB | — |
| Qdrant | 2 cores | 8 GB | — |
| LiteLLM | 2 cores | 2 GB | — |
| OpenWebUI | 1 core | 1 GB | — |
| Flowise | 1 core | 1 GB | — |
| Prometheus | 1 core | 2 GB | — |
| Grafana | 1 core | 1 GB | — |
| Loki | 1 core | 2 GB | — |

Set in quadlet files:

```ini
[Container]
PodmanArgs=--cpus=2 --memory=4g
```

---

# 8 Health Checks

> **Status:** Deferrable — add incrementally.

| Service | Health Check Command | Interval |
|---------|---------------------|----------|
| PostgreSQL | `pg_isready -U aistack` | 30s |
| Qdrant | `curl -f http://localhost:6333/healthz` | 30s |
| LiteLLM | `curl -f http://localhost:9000/health` | 30s |
| vLLM | `curl -f http://localhost:8000/health` | 60s |
| OpenWebUI | `curl -f http://localhost:8080/health` | 30s |
| Grafana | `curl -f http://localhost:3000/api/health` | 30s |
| Loki | `curl -f http://localhost:3100/ready` | 30s |

Add to quadlet files using `HealthCmd`, `HealthInterval`, and `HealthRetries` directives.

---

# 9 GPU Passthrough Configuration

> **Status:** Deferrable — required only for GPU nodes.

### Prerequisites

- NVIDIA driver installed on the host
- NVIDIA Container Toolkit (`nvidia-ctk`) installed

### Generate CDI spec

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
```

### Verify GPU access

```bash
podman run --device nvidia.com/gpu=all --rm vllm/vllm-openai:TBD nvidia-smi
```

### Quadlet GPU access

```ini
[Container]
AddDevice=nvidia.com/gpu=all
```

---

# 10 Authentik OIDC Integration

> **Status:** Deferrable — can use direct authentication initially.

Services to configure as OIDC relying parties:

| Service | Redirect URI | Notes |
|---------|-------------|-------|
| OpenWebUI | `http://webui.ai-stack:9090/oauth/callback` | TBD |
| Grafana | `http://grafana.ai-stack:3000/login/generic_oauth` | TBD |
| Flowise | `http://flowise.ai-stack:3001/api/v1/oauth/callback` | TBD |

Authentik provider configuration and client IDs/secrets to be generated during setup. Each service requires an OIDC application configured in Authentik with the appropriate redirect URIs and scopes.

---

# 11 Library Manifest Schema

> **Status:** Deferrable — define before building knowledge libraries.

### Example `manifest.yaml`

```yaml
schema_version: "1.0"
library:
  name: "golang-best-practices"
  version: "0.1.0"
  description: "Best practices for Go development"
  created: "2026-03-08"
  topics:
    - name: "concurrency"
      document_count: 12
    - name: "error-handling"
      document_count: 8
  embedding_model: "BAAI/bge-large-en-v1.5"
  chunk_strategy:
    method: "recursive"
    chunk_size: 512
    overlap: 50
```

Full JSON Schema to be defined during implementation. The schema should validate library packages before ingestion.

---

# 12 Alerting Rules

> **Status:** Deferrable — add after monitoring stack is operational.

Planned Prometheus alert rules:

| Alert | Condition | Severity |
|-------|-----------|----------|
| InferenceLatencyHigh | `inference_latency_seconds > 10` for 5m | Warning |
| GPUMemoryHigh | `gpu_memory_used_percent > 90` for 5m | Critical |
| ContainerRestart | `container_restart_count > 3` in 10m | Warning |
| DiskUsageHigh | `disk_used_percent > 85` | Warning |
| QdrantUnhealthy | Qdrant health check failing for 2m | Critical |
| PostgresUnhealthy | PostgreSQL health check failing for 2m | Critical |

Alert rules will be defined as Prometheus YAML and stored in `$AI_STACK_DIR/configs/prometheus/rules/`.

---

# 13 Backup and Restore

> **Status:** Deferrable — implement before production use.

### What to back up

| Data | Path | Method |
|------|------|--------|
| PostgreSQL | `$AI_STACK_DIR/postgres/` | `pg_dump` via cron |
| Qdrant snapshots | `$AI_STACK_DIR/qdrant/` | Qdrant snapshot API |
| Knowledge libraries | `$AI_STACK_DIR/libraries/` | rsync / tar |
| Configuration | `$AI_STACK_DIR/configs/` | git-tracked |
| Secrets | Podman secret store | `podman secret inspect` + encrypted export |

### Backup schedule

| Data | Frequency | Retention |
|------|-----------|-----------|
| PostgreSQL | Daily | 7 days |
| Qdrant snapshots | Daily | 7 days |
| Configuration | On change (git) | Full history |

### Restore procedure

TBD — document restore steps for each data source during implementation.

---

# 14 Troubleshooting

> **Status:** Deferrable — build incrementally from operational experience.

### Common issues

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| GPU not visible in container | CDI not configured | Run `nvidia-ctk cdi generate` (see §9) |
| vLLM OOM | Model too large for VRAM | Use a smaller model or enable tensor parallelism |
| Qdrant disk full | Vector storage unbounded | Add retention policy or expand storage |
| Containers fail to resolve DNS | Network not created | Run `podman network create ai-stack-net` |
| Permission denied on volumes | Rootless UID mapping | Use `:Z` suffix on volume mounts |
| Service fails to start | Dependency not ready | Check startup order (§6) and health checks (§8) |

Additional troubleshooting entries will be added as issues are encountered.
