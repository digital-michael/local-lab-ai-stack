# AI Stack Implementation Guide
**Last Updated:** 2026-03-08 UTC

## Purpose
This document contains deployment procedures, structural artifacts, and operational runbooks for the AI Multivolume RAG Platform. Architecture decisions are in [ai_stack_architecture.md](ai_stack_architecture.md). All tunable values (images, env vars, ports, limits) are in [ai_stack_configuration.md](ai_stack_configuration.md).

An LLM agent can read this document to generate quadlet files, execute deployment steps, and operate services.

---

## Table of Contents

1. Secrets Management
2. Quadlet Unit Files
3. Service Dependency Order
4. GPU Passthrough Configuration
5. Authentik OIDC Integration
6. Library Manifest Schema
7. Alerting Rules
8. Backup and Restore
9. Troubleshooting

---

# 1 Secrets Management

> **Status:** Blocker — required before first deployment.

Use Podman secrets to inject sensitive values. Never store secrets in plain text configuration files. The full secrets inventory is in [configuration §8](ai_stack_configuration.md#8-secrets-inventory).

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

# 2 Quadlet Unit Files

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

Image references, port mappings, volume paths, environment variables, resource limits, and health check parameters are sourced from [ai_stack_configuration.md](ai_stack_configuration.md).

### Example: PostgreSQL quadlet

```ini
# postgres.container
[Unit]
Description=AI Stack PostgreSQL
After=ai-stack-network.service

[Container]
Image=docker.io/library/postgres:TBD       # configuration §1
ContainerName=postgres
Network=ai-stack-net                        # configuration §5
Volume=%h/ai-stack/postgres:/var/lib/postgresql/data:Z  # configuration §6
Secret=postgres_password,type=env,target=POSTGRES_PASSWORD  # configuration §8
Environment=POSTGRES_USER=aistack           # configuration §2
Environment=POSTGRES_DB=aistack
PublishPort=5432:5432                       # configuration §4
HealthCmd=pg_isready -U aistack             # configuration §10
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

# 3 Service Dependency Order

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

Express dependencies using `After=` and `Requires=` directives in quadlet unit files. Services that depend on PostgreSQL or Qdrant should not start until those services pass their health checks (see [configuration §10](ai_stack_configuration.md#10-health-check-parameters)).

---

# 4 GPU Passthrough Configuration

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

# 5 Authentik OIDC Integration

> **Status:** Deferrable — can use direct authentication initially.

Services to configure as OIDC relying parties:

| Service | Redirect URI | Notes |
|---------|-------------|-------|
| OpenWebUI | `http://webui.ai-stack:9090/oauth/callback` | TBD |
| Grafana | `http://grafana.ai-stack:3000/login/generic_oauth` | TBD |
| Flowise | `http://flowise.ai-stack:3001/api/v1/oauth/callback` | TBD |

Authentik provider configuration and client IDs/secrets to be generated during setup. Each service requires an OIDC application configured in Authentik with the appropriate redirect URIs and scopes.

---

# 6 Library Manifest Schema

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

# 7 Alerting Rules

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

Alert rules will be defined as Prometheus YAML and stored in `$AI_STACK_DIR/configs/prometheus/rules/`. Alert threshold values may be extracted to [ai_stack_configuration.md](ai_stack_configuration.md) once rules are concrete.

---

# 8 Backup and Restore

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

# 9 Troubleshooting

> **Status:** Deferrable — build incrementally from operational experience.

### Common issues

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| GPU not visible in container | CDI not configured | Run `nvidia-ctk cdi generate` (see §4) |
| vLLM OOM | Model too large for VRAM | Use a smaller model or enable tensor parallelism ([configuration §7](ai_stack_configuration.md#7-model-configuration)) |
| Qdrant disk full | Vector storage unbounded | Add retention policy or expand storage |
| Containers fail to resolve DNS | Network not created | Run `podman network create ai-stack-net` ([configuration §5](ai_stack_configuration.md#5-network-configuration)) |
| Permission denied on volumes | Rootless UID mapping | Use `:Z` suffix on volume mounts ([configuration §6](ai_stack_configuration.md#6-volume-paths)) |
| Service fails to start | Dependency not ready | Check startup order (§3) and health checks ([configuration §10](ai_stack_configuration.md#10-health-check-parameters)) |

Additional troubleshooting entries will be added as issues are encountered.
