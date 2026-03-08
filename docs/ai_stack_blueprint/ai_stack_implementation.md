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
10. Knowledge Index Service API Specification
11. Discovery Profile Specification
12. Quadlet Translation Specification

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
echo "<value>" | podman secret create authentik_secret_key -
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
- `traefik.container`
- `postgres.container`
- `qdrant.container`
- `litellm.container`
- `vllm.container`
- `llamacpp.container`
- `flowise.container`
- `openwebui.container`
- `authentik.container`
- `knowledge-index.container`
- `prometheus.container`
- `grafana.container`
- `loki.container`
- `promtail.container`

---

# 3 Service Dependency Order

> **Status:** Blocker — required before first deployment.

Start services in this order:

```
1.  ai-stack-net (network)
2.  Traefik
3.  PostgreSQL
4.  Qdrant
5.  Authentik
6.  LiteLLM
7.  vLLM / llama.cpp
8.  Knowledge Index
9.  Flowise           ← depends on LiteLLM + Qdrant + Knowledge Index
10. OpenWebUI
11. Prometheus → Grafana → Loki → Promtail
```

Traefik starts immediately after the network — it has no service dependencies and must be ready before user-facing services come online. Knowledge Index depends on PostgreSQL and Qdrant (steps 3–4).

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

The `.ai-library` package format is specified in the architecture doc (§4 Knowledge Library System) and formalized in D-013.

### Example `manifest.yaml`

```yaml
schema_version: "1.0"
library:
  name: "golang-best-practices"
  version: "0.1.0"
  description: "Best practices for Go development"
  author: "operator"
  license: "internal"
  created: "2026-03-08"
  profiles:
    - localhost
    - local
  embedding_model: "BAAI/bge-large-en-v1.5"
  chunk_strategy:
    method: "recursive"
    chunk_size: 512
    overlap: 50
```

### Example `metadata.json`

```json
{
  "schema_version": "1.0",
  "topic_count": 2,
  "document_count": 20,
  "vector_dimensions": 1024,
  "embedding_model": "BAAI/bge-large-en-v1.5",
  "topics": ["concurrency", "error-handling"]
}
```

### Example `topics.json`

```json
{
  "schema_version": "1.0",
  "topics": [
    {
      "name": "concurrency",
      "description": "Go concurrency patterns, goroutines, channels, sync primitives",
      "document_count": 12
    },
    {
      "name": "error-handling",
      "description": "Error wrapping, sentinel errors, custom error types",
      "document_count": 8
    }
  ]
}
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

---

# 10 Knowledge Index Service API Specification

> **Status:** Deferrable — define before building the Knowledge Index Service.

The Knowledge Index Service (D-012) is a standalone Python/FastAPI microservice providing query→volume routing and library metadata access.

### Base URL

```
http://knowledge-index.ai-stack:8900/v1/
```

### Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/v1/health` | Health check |
| `GET` | `/v1/libraries` | List all discovered libraries |
| `GET` | `/v1/libraries/{name}` | Get library metadata (manifest + topics) |
| `GET` | `/v1/libraries/{name}/topics` | List topics for a library |
| `POST` | `/v1/route` | Given a query, return ranked list of relevant libraries and topics |
| `POST` | `/v1/ingest` | Trigger ingestion of a new or updated library volume |

### Route Request

```json
{
  "query": "How do Go channels handle buffering?",
  "max_results": 5
}
```

### Route Response

```json
{
  "routes": [
    {
      "library": "golang-best-practices",
      "topic": "concurrency",
      "relevance": 0.92,
      "collection": "golang-best-practices-concurrency"
    }
  ],
  "cached": false
}
```

### Caching

The service maintains a short-lived in-memory cache (TTL configurable, default 60s) for query→route mappings. Cache is invalidated on library ingestion. The cache is a performance optimization, not a correctness requirement — cache misses fall through to PostgreSQL + Qdrant.

### Dependencies

- **PostgreSQL** — library metadata, topic indexes
- **Qdrant** — vector similarity for routing queries to relevant topics

### OpenAPI

FastAPI auto-generates an OpenAPI spec at `/v1/docs` (Swagger UI) and `/v1/openapi.json`.

---

# 11 Discovery Profile Specification

> **Status:** Deferrable — specify before implementing discovery beyond localhost.

Discovery profiles (D-014) define how knowledge library volumes are found, trusted, and verified across deployment contexts.

### Profile Summary

| Profile | Discovery Mechanism | Trust Model | Verification | MVP Status |
|---------|-------------------|-------------|--------------|------------|
| **localhost** | Filesystem scan of `$AI_STACK_DIR/libraries/` | Implicit — operator placed the files | `checksums.txt` integrity only | **Implement** |
| **local** | mDNS/DNS-SD service advertisement | Network membership + optional signature | `checksums.txt` + optional `signature.asc` | Specify, defer |
| **WAN** | Registry/federation protocol (TBD) | Mandatory cryptographic verification | `checksums.txt` + mandatory `signature.asc` | Specify, defer |

### localhost Profile (MVP)

The Knowledge Index Service scans `$AI_STACK_DIR/libraries/` on startup and on a configurable interval (default: 300s). Each subdirectory containing a valid `manifest.yaml` is registered as an available library.

Validation steps:
1. Parse `manifest.yaml` — reject if missing or schema-invalid
2. Verify `checksums.txt` — reject if any file fails integrity check
3. Parse `metadata.json` and `topics.json` — register topics in PostgreSQL
4. Index vectors in Qdrant if `vectors/` contains pre-computed embeddings

No signature verification is required for localhost — the operator's act of placing files in the directory constitutes implicit trust.

### local Profile (Deferred)

Nodes advertise available libraries via mDNS/DNS-SD on the local network. Discovering nodes query for `_ai-library._tcp.local` service records. Each record includes the library name, version, and a URL to fetch the manifest.

Trust is established by network membership. Signatures in `signature.asc` are optional but recommended. If present, they are verified before ingestion.

### WAN Profile (Deferred)

Libraries are published to a registry (protocol TBD — likely a simple REST API with signed manifests). Discovering nodes query the registry for available libraries matching their topic interests.

All WAN-sourced libraries **must** include a valid `signature.asc`. Unsigned or invalid-signature libraries are rejected. The signing key trust model (TOFU, CA-based, or web-of-trust) is a future design decision.

### Volume Manifest Integration

Each `.ai-library` package declares its supported profiles in `manifest.yaml`:

```yaml
profiles:
  - localhost
  - local
```

The Knowledge Index Service only attempts discovery mechanisms that match both the instance's active profiles and the volume's declared profiles.

---

# 12 Quadlet Translation Specification

> **Status:** Blocker — required to generate quadlet files in Phase 5.

This section documents how each field in `configs/config.json` maps to directives in a Podman systemd quadlet `.container` unit file. `configure.sh generate-quadlets` uses this mapping to produce the 15 unit files.

---

## 12.1 config.json Field → Quadlet Directive Mapping

| config.json field | Quadlet directive | Format / Notes |
|---|---|---|
| `image` + `tag` | `Image=` | `{image}:{tag}` |
| `container_name` | `ContainerName=` | |
| (all services) | `Network=` | `ai-stack-net:alias={dns_alias}` |
| `ports[].host:container` | `PublishPort=` | `{host}:{container}` — one directive per entry; omit if `ports` is empty |
| `volumes[].host:container:mode` | `Volume=` | `{host}:{container}:Z` — append `:Z` for SELinux; include `,ro` if mode is `ro` |
| `environment.KEY` | `Environment=` | `KEY=VALUE` — one directive per entry |
| `secrets[].name + target` | `Secret=` | `{name},type=env,target={target}` |
| `health_check.command` | `HealthCmd=` | Omit section if `health_check` is null |
| `health_check.interval` | `HealthInterval=` | |
| `health_check.retries` | `HealthRetries=` | |
| `health_check.timeout` | `HealthStartPeriod=` | Use as startup grace period |
| `resources.cpus` + `resources.memory` | `PodmanArgs=` | `--cpus={cpus} --memory={memory}` — single directive |
| `resources.gpu` (non-null) | `AddDevice=nvidia.com/gpu=all` | Only include when gpu is non-null |
| `depends_on` | `After=` + `Requires=` | See §12.4 |

---

## 12.2 Unit File Template

```ini
# {service_name}.container
[Unit]
Description=AI Stack {ServiceDisplayName}
After=ai-stack-network.service{after_deps}
Requires=ai-stack-network.service{requires_deps}

[Container]
Image={image}:{tag}
ContainerName={container_name}
Network=ai-stack-net:alias={dns_alias}
{PublishPort= entries}
{Volume= entries}
{Environment= entries}
{Secret= entries}
{HealthCmd= block}
PodmanArgs=--cpus={cpus} --memory={memory}

[Service]
Restart=always

[Install]
WantedBy=default.target
```

Notes:
- `{after_deps}` and `{requires_deps}` are space-prefixed service names derived from `depends_on` (see §12.4)
- Omit the `HealthCmd=` block entirely when `health_check` is null
- For GPU services, add `AddDevice=nvidia.com/gpu=all` before `PodmanArgs=`

---

## 12.3 Special Cases

**1. DATABASE_URL with embedded password**

`LiteLLM` and `Knowledge Index` use `DATABASE_URL` containing the database password. Podman `Environment=` does not perform variable substitution. The `generate-quadlets` script must write an `EnvironmentFile=` pointing to `$AI_STACK_DIR/configs/run/{service}.env`, where the file is generated at deploy time with the password injected from the Podman secret. Format:

```
DATABASE_URL=postgresql://aistack:<resolved_password>@postgres.ai-stack:5432/aistack
```

**2. Network alias**

Use the `Network=ai-stack-net:alias={dns_alias}` form (Podman 4.4+) to register the container under its DNS alias on `ai-stack-net`. This replaces a separate `NetworkAlias=` directive.

**3. SELinux volume labels**

All volume mounts require `:Z` for SELinux relabeling on Fedora/RHEL. Append `:Z` to every `Volume=` entry. For read-only volumes, the combined suffix is `:ro,Z`. config.json stores the logical mode; the generator appends the SELinux label.

**4. Multiple PodmanArgs lines**

Do not use multiple `PodmanArgs=` lines — they are not additive in Podman quadlet. Combine all extra arguments into a single `PodmanArgs=` line.

**5. Network unit service name**

The `ai-stack.network` quadlet generates a systemd service named `ai-stack-network.service` (Podman appends `-network` to the base name of `.network` files). All containers must declare `After=ai-stack-network.service`.

**6. Container unit service names**

A `foo.container` file generates `foo.service`. The `depends_on` array values map directly: `"postgres"` → `After=postgres.service`.

---

## 12.4 Complete Dependency Chain

| Quadlet file | After= | Requires= |
|---|---|---|
| `traefik.container` | `ai-stack-network.service` | `ai-stack-network.service` |
| `postgres.container` | `ai-stack-network.service` | `ai-stack-network.service` |
| `qdrant.container` | `ai-stack-network.service` | `ai-stack-network.service` |
| `authentik.container` | `ai-stack-network.service postgres.service` | `ai-stack-network.service postgres.service` |
| `litellm.container` | `ai-stack-network.service postgres.service` | `ai-stack-network.service postgres.service` |
| `vllm.container` | `ai-stack-network.service litellm.service` | `ai-stack-network.service litellm.service` |
| `llamacpp.container` | `ai-stack-network.service litellm.service` | `ai-stack-network.service litellm.service` |
| `knowledge-index.container` | `ai-stack-network.service postgres.service qdrant.service` | `ai-stack-network.service postgres.service qdrant.service` |
| `flowise.container` | `ai-stack-network.service litellm.service qdrant.service knowledge-index.service` | `ai-stack-network.service litellm.service qdrant.service knowledge-index.service` |
| `openwebui.container` | `ai-stack-network.service litellm.service` | `ai-stack-network.service litellm.service` |
| `prometheus.container` | `ai-stack-network.service` | `ai-stack-network.service` |
| `grafana.container` | `ai-stack-network.service prometheus.service` | `ai-stack-network.service prometheus.service` |
| `loki.container` | `ai-stack-network.service` | `ai-stack-network.service` |
| `promtail.container` | `ai-stack-network.service loki.service` | `ai-stack-network.service loki.service` |

`Requires=` means systemd will refuse to start the unit if its dependency fails. All service-to-service `Requires=` here are intentional — if a dependency is down at startup, the dependent service should not attempt to start.

