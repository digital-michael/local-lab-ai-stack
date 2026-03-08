# AI Stack Configuration Reference
**Last Updated:** 2026-03-08 UTC

## Purpose
This document is the single source of truth for all tunable configuration values in the AI Multivolume RAG Platform. Architecture decisions are in [ai_stack_architecture.md](ai_stack_architecture.md). Deployment procedures and structural artifacts are in [ai_stack_implementation.md](ai_stack_implementation.md).

Updating images, ports, resource limits, or environment defaults should only require changes to this file.

---

## Table of Contents

1. Container Images and Versions
2. Environment Variables
3. Resource Limits
4. Port Mappings
5. Network Configuration
6. Volume Paths
7. Model Configuration
8. Secrets Inventory
9. TLS Configuration
10. Health Check Parameters

---

# 1 Container Images and Versions

Pin all images to specific tags or digests before deployment.

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

---

# 2 Environment Variables

Replace all `<secret>` values using Podman secrets (see §8 and [implementation §1](ai_stack_implementation.md#1-secrets-management)).

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

---

# 3 Resource Limits

Tune after initial deployment. Set in quadlet files via `PodmanArgs=--cpus=N --memory=Xg`.

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

---

# 4 Port Mappings

| Host Port | Container Port | Service |
|-----------|---------------|---------|
| 9090 | 8080 | OpenWebUI |
| 9000 | 4000 | LiteLLM API gateway |
| 9443 | 443 | TLS reverse proxy |
| 6333 | 6333 | Qdrant REST API |
| 6334 | 6334 | Qdrant gRPC |
| 5432 | 5432 | PostgreSQL |
| 3000 | 3000 | Grafana |
| 3100 | 3100 | Loki |
| 9091 | 9090 | Prometheus |
| 8000 | 8000 | vLLM inference |
| 3001 | 3000 | Flowise |

---

# 5 Network Configuration

| Setting | Value |
|---------|-------|
| Network name | `ai-stack-net` |
| Driver | `bridge` |
| Internal only | `false` |

### Internal DNS aliases

| Alias | Service |
|-------|---------|
| `litellm.ai-stack` | LiteLLM |
| `qdrant.ai-stack` | Qdrant |
| `postgres.ai-stack` | PostgreSQL |
| `flowise.ai-stack` | Flowise |
| `webui.ai-stack` | OpenWebUI |
| `grafana.ai-stack` | Grafana |
| `loki.ai-stack` | Loki |
| `prometheus.ai-stack` | Prometheus |
| `authentik.ai-stack` | Authentik |

---

# 6 Volume Paths

Base path: `$AI_STACK_DIR` (defaults to `$HOME/ai-stack` for rootless Podman).

Use the `:Z` volume suffix for SELinux relabeling on Fedora/RHEL hosts.

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

---

# 7 Model Configuration

### Inference models

| Model | Backend | Use Case | Notes |
|-------|---------|----------|-------|
| `llama3.1-8b` | vLLM / llama.cpp | General purpose | Default model |
| `deepseek-coder` | vLLM / llama.cpp | Code generation | |
| `llama3.1-70b` | vLLM | Complex reasoning | Optional; requires ≥48 GB VRAM |

### Embedding model

| Model | Backend | Dimensions |
|-------|---------|------------|
| `BAAI/bge-large-en-v1.5` | vLLM | 1024 |

### Model storage

- Download location: `$AI_STACK_DIR/models/`
- Shared across inference containers via read-only bind mounts
- Files are cached locally; containers do not re-download on restart
- LiteLLM routes requests to the appropriate model and backend

### vLLM inference parameters

```env
TENSOR_PARALLEL_SIZE=1
MAX_MODEL_LEN=4096
GPU_MEMORY_UTILIZATION=0.9
```

### llama.cpp inference parameters

```env
CONTEXT_SIZE=4096
THREADS=4
BATCH_SIZE=512
```

---

# 8 Secrets Inventory

Secret names and the services that consume them. Values are never stored in this file — use `podman secret create` to provision them (see [implementation §1](ai_stack_implementation.md#1-secrets-management)).

| Secret Name | Consumer(s) | Target Env Var |
|-------------|------------|----------------|
| `postgres_password` | PostgreSQL, LiteLLM | `POSTGRES_PASSWORD` |
| `litellm_master_key` | LiteLLM | `LITELLM_MASTER_KEY` |
| `qdrant_api_key` | Qdrant | `QDRANT__SERVICE__API_KEY` |
| `openwebui_api_key` | OpenWebUI | `OPENAI_API_KEY` |
| `flowise_password` | Flowise | `FLOWISE_PASSWORD` |

---

# 9 TLS Configuration

| Setting | Value |
|---------|-------|
| Certificate path | `$AI_STACK_DIR/configs/tls/cert.pem` |
| Private key path | `$AI_STACK_DIR/configs/tls/key.pem` |
| CA bundle path | `$AI_STACK_DIR/configs/tls/ca.pem` (if self-signed) |
| Mode | Self-signed CA for internal traffic; trusted CA for external access |
| Exposed TLS port | 9443 (see §4) |

TLS termination occurs at the reverse proxy. Internal service-to-service traffic uses plain HTTP over the isolated `ai-stack-net` network.

---

# 10 Health Check Parameters

| Service | Health Check Command | Interval | Retries | Timeout |
|---------|---------------------|----------|---------|---------|
| PostgreSQL | `pg_isready -U aistack` | 30s | 3 | 5s |
| Qdrant | `curl -sf http://localhost:6333/healthz` | 30s | 3 | 5s |
| LiteLLM | `curl -sf http://localhost:4000/health` | 30s | 3 | 5s |
| vLLM | `curl -sf http://localhost:8000/health` | 60s | 3 | 10s |
| OpenWebUI | `curl -sf http://localhost:8080/health` | 30s | 3 | 5s |
| Grafana | `curl -sf http://localhost:3000/api/health` | 30s | 3 | 5s |
| Loki | `curl -sf http://localhost:3100/ready` | 30s | 3 | 5s |

Applied in quadlet files using `HealthCmd`, `HealthInterval`, `HealthRetries`, and `HealthTimeout` directives. See [implementation §2](ai_stack_implementation.md#2-quadlet-unit-files).
