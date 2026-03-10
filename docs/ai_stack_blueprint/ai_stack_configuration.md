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
| OpenWebUI | `ghcr.io/open-webui/open-webui` | `v0.8.9` | |
| LiteLLM | `ghcr.io/berriai/litellm` | `main-v1.81.14-stable` | |
| vLLM | `vllm/vllm-openai` | `v0.17.0` | GPU inference |
| ollama | `docker.io/ollama/ollama` | `0.17.7` | Local model inference |
| Qdrant | `docker.io/qdrant/qdrant` | `v1.17.0` | |
| PostgreSQL | `docker.io/library/postgres` | `17.9` | |
| Flowise | `docker.io/flowiseai/flowise` | `3.0.13` | |
| Authentik | `ghcr.io/goauthentik/server` | `2026.2.1` | |
| Prometheus | `docker.io/prom/prometheus` | `v3.10.0` | |
| Grafana | `docker.io/grafana/grafana` | `12.4.0` | |
| Loki | `docker.io/grafana/loki` | `3.6.7` | |
| Promtail | `docker.io/grafana/promtail` | `3.6.7` | |
| Traefik | `docker.io/library/traefik` | `v3.6.10` | Reverse proxy and TLS termination |
| Knowledge Index | `localhost/knowledge-index` | `0.1.0` | Locally built FastAPI service |

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

### ollama

```env
OLLAMA_HOST=0.0.0.0
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

### Authentik

```env
AUTHENTIK_POSTGRESQL__HOST=postgres.ai-stack
AUTHENTIK_POSTGRESQL__NAME=aistack
AUTHENTIK_POSTGRESQL__USER=aistack
AUTHENTIK_POSTGRESQL__PASSWORD=<secret>
AUTHENTIK_SECRET_KEY=<secret>
AUTHENTIK_ERROR_REPORTING__ENABLED=false
AUTHENTIK_LOG_LEVEL=info
```

### Knowledge Index

```env
DATABASE_URL=postgresql://aistack:<secret>@postgres.ai-stack:5432/aistack
QDRANT_HOST=qdrant.ai-stack
QDRANT_PORT=6333
ROUTE_CACHE_TTL=60
LISTEN_PORT=8900
```

---

# 3 Resource Limits

Tune after initial deployment. Set in quadlet files via `PodmanArgs=--cpus=N --memory=Xg`.

| Container | CPU | Memory | GPU |
|-----------|-----|--------|-----|
| vLLM | 4 cores | 24 GB | 1 GPU |
| ollama | 4 cores | 16 GB | — |
| PostgreSQL | 2 cores | 4 GB | — |
| Qdrant | 2 cores | 8 GB | — |
| LiteLLM | 2 cores | 2 GB | — |
| OpenWebUI | 1 core | 1 GB | — |
| Flowise | 1 core | 1 GB | — |
| Prometheus | 1 core | 2 GB | — |
| Grafana | 1 core | 1 GB | — |
| Loki | 1 core | 2 GB | — |
| Promtail | 1 core | 1 GB | — |
| Traefik | 0.5 cores | 256 MB | — |
| Knowledge Index | 1 core | 512 MB | — |

---

# 4 Port Mappings

| Host Port | Container Port | Service |
|-----------|---------------|---------|
| 9090 | 8080 | OpenWebUI |
| 9000 | 4000 | LiteLLM API gateway |
| 80 | 80 | Traefik (HTTP → HTTPS redirect) |
| 443 | 443 | Traefik (HTTPS) |
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
| `traefik.ai-stack` | Traefik |
| `knowledge-index.ai-stack` | Knowledge Index Service |

---

# 6 Volume Paths

Base path: `$AI_STACK_DIR` (defaults to `$HOME/ai-stack` for rootless Podman).

Use the `:Z` volume suffix for SELinux relabeling on Fedora/RHEL hosts.

| Container | Host Path | Container Path | Mode |
|-----------|-----------|----------------|------|
| vLLM | `$AI_STACK_DIR/models` | `/models` | ro |
| ollama | `$AI_STACK_DIR/ollama` | `/root/.ollama` | rw |
| ollama | `$AI_STACK_DIR/models` | `/gguf` | ro |
| Qdrant | `$AI_STACK_DIR/qdrant` | `/qdrant/storage` | rw |
| PostgreSQL | `$AI_STACK_DIR/postgres` | `/var/lib/postgresql/data` | rw |
| Knowledge Index | `$AI_STACK_DIR/libraries` | `/libraries` | rw |
| Grafana | `$AI_STACK_DIR/configs/grafana` | `/etc/grafana` | ro |
| Prometheus | `$AI_STACK_DIR/configs/prometheus` | `/etc/prometheus` | ro |
| Loki | `$AI_STACK_DIR/logs/loki` | `/loki` | rw |
| Promtail | `$AI_STACK_DIR/configs/promtail` | `/etc/promtail` | ro |
| Traefik | `$AI_STACK_DIR/configs/traefik/traefik.yaml` | `/etc/traefik/traefik.yaml` | ro |
| Traefik | `$AI_STACK_DIR/configs/traefik/dynamic` | `/etc/traefik/dynamic` | ro |
| Traefik | `$AI_STACK_DIR/configs/tls` | `/etc/traefik/tls` | ro |
| Flowise | `$AI_STACK_DIR/flowise` | `/data/flowise` | rw |
| OpenWebUI | `$AI_STACK_DIR/openwebui` | `/app/backend/data` | rw |
| Grafana (data) | `$AI_STACK_DIR/grafana` | `/var/lib/grafana` | rw |
| Loki (config) | `$AI_STACK_DIR/configs/loki` | `/etc/loki` | ro |

---

# 7 Model Configuration

### Inference models

| Model | Backend | Use Case | Notes |
|-------|---------|----------|-------|
| `llama3.1-8b` | vLLM / ollama | General purpose | Default model |
| `deepseek-coder` | vLLM / ollama | Code generation | |
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

### ollama inference parameters

Controlled via LiteLLM `litellm_params` and per-request fields. Key ollama environment variables:

```env
OLLAMA_HOST=0.0.0.0
OLLAMA_NUM_PARALLEL=1
OLLAMA_KEEP_ALIVE=5m
```

#### Model import Modelfile (tool-calling enabled)

GGUF models must be imported with the llama3.1 template that handles `.Tools`. A bare `FROM <blob>`
Modelfile omits this and causes `does not support tools` errors at runtime.

```
FROM /root/.ollama/models/blobs/sha256-<gguf-sha256>

TEMPLATE """{{- if or .System .Tools }}<|start_header_id|>system<|end_header_id|>
{{- if .System }}

{{ .System }}
{{- end }}
{{- if .Tools }}

Cutting Knowledge Date: December 2023

When you receive a tool call response, use the output to format an answer to the original user question.

You are a helpful assistant with tool calling capabilities.
{{- end }}<|eot_id|>
{{- end }}
{{- range $i, $_ := .Messages }}
{{- $last := eq (len (slice $.Messages $i)) 1 }}
{{- if eq .Role "user" }}<|start_header_id|>user<|end_header_id|>
{{- if and (eq (len (slice $.Messages $i)) 1) $.Tools }}

Given the following functions, please respond with a JSON for a function call with its proper arguments that best answers the given prompt.

Respond in the format {"name": function name, "parameters": dictionary of argument name and its value}. Do not use variables.
{{ range $.Tools }}
{{- . }}
{{ end }}
Question: {{ .Content }}<|eot_id|>
{{- else }}

{{ .Content }}<|eot_id|>
{{- end }}{{ if $last }}<|start_header_id|>assistant<|end_header_id|>

{{ end }}
{{- else if eq .Role "assistant" }}<|start_header_id|>assistant<|end_header_id|>
{{- if .ToolCalls }}
{{ range .ToolCalls }}
{"name": "{{ .Function.Name }}", "parameters": {{ .Function.Arguments }}}
{{ end }}
{{- else }}

{{ .Content }}
{{- end }}{{ if not $last }}<|eot_id|>{{ end }}
{{- else if eq .Role "tool" }}<|start_header_id|>ipython<|end_header_id|>

{{ .Content }}<|eot_id|>{{ if $last }}<|start_header_id|>assistant<|end_header_id|>

{{ end }}
{{- end }}
{{- end }}"""

PARAMETER stop <|start_header_id|>
PARAMETER stop <|end_header_id|>
PARAMETER stop <|eot_id|>
```

---

# 8 Secrets Inventory

Secret names and the services that consume them. Values are never stored in this file — use `podman secret create` to provision them (see [implementation §1](ai_stack_implementation.md#1-secrets-management)).

| Secret Name | Consumer(s) | Target Env Var |
|-------------|------------|----------------|
| `postgres_password` | PostgreSQL, LiteLLM, Knowledge Index | `POSTGRES_PASSWORD` |
| `litellm_master_key` | LiteLLM | `LITELLM_MASTER_KEY` |
| `qdrant_api_key` | Qdrant, Knowledge Index | `QDRANT__SERVICE__API_KEY` (Qdrant); `QDRANT_API_KEY` (Knowledge Index) |
| `openwebui_api_key` | OpenWebUI | `OPENAI_API_KEY` |
| `flowise_password` | Flowise | `FLOWISE_PASSWORD` |
| `authentik_secret_key` | Authentik | `AUTHENTIK_SECRET_KEY` |

---

# 9 TLS Configuration

| Setting | Value |
|---------|-------|
| Certificate path | `$AI_STACK_DIR/configs/tls/cert.pem` |
| Private key path | `$AI_STACK_DIR/configs/tls/key.pem` |
| CA bundle path | `$AI_STACK_DIR/configs/tls/ca.pem` (if self-signed) |
| Mode | Self-signed CA for internal traffic; trusted CA for external access |
| Exposed TLS port | 443 (see §4) |

TLS termination occurs at Traefik. Internal service-to-service traffic uses plain HTTP over the isolated `ai-stack-net` network.

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
| Traefik | `wget -qO- http://localhost:8080/ping \|\| exit 1` | 30s | 3 | 5s |
| Knowledge Index | `curl -sf http://localhost:8900/v1/health` | 30s | 3 | 5s |

Applied in quadlet files using `HealthCmd`, `HealthInterval`, `HealthRetries`, and `HealthTimeout` directives. See [implementation §2](ai_stack_implementation.md#2-quadlet-unit-files).
