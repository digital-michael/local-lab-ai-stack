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

> **Status:** Deferrable — can use direct authentication initially. Traefik forward-auth (already configured) provides session enforcement without per-service OIDC; per-service OIDC adds SSO convenience.

### Overview

Authentik handles authentication in two complementary ways:

1. **Forward-auth** (already configured in `configs/traefik/dynamic/middlewares.yaml`) — Traefik intercepts every request to a protected service and calls Authentik's outpost to verify the session. No per-service configuration required. This is the MVP.
2. **Per-service OIDC** (this section) — Each service gets its own OIDC application in Authentik, enabling native SSO (single sign-on/out, user attribute mapping). Adds convenience but is not required for security.

### Forward-Auth Setup (required first)

The embedded Authentik outpost handles forward-auth at `http://authentik.ai-stack:9000/outpost.goauthentik.io/auth/traefik`. This is already defined in `middlewares.yaml` and applied to all user-facing routers in `services.yaml`.

**Initial Authentik setup steps (one-time, via browser):**

1. Browse to `https://auth.localhost` (after Traefik + Authentik are started)
2. Complete the initial admin setup wizard
3. Create a default provider of type **Proxy** (for forward-auth):
   - Type: Forward auth (single application)
   - External host: `https://auth.localhost`
4. Embed the proxy provider in the default embedded outpost (`Admin > Outposts`)
5. Restart the embedded outpost to apply changes

### Per-Service OIDC Configuration

For each service, create an **OAuth2/OpenID Connect Provider** and **Application** in Authentik:

**Prerequisite:** Note the Authentik base URL (e.g. `https://auth.localhost`) and generate a provider client ID and secret in Authentik Admin UI.

#### Grafana

Add to `configs/grafana/grafana.ini` under `[auth.generic_oauth]`:

```ini
[auth.generic_oauth]
enabled = true
name = Authentik
allow_sign_up = true
client_id = <grafana-client-id>
client_secret = <grafana-client-secret>
scopes = openid email profile
auth_url = https://auth.localhost/application/o/authorize/
token_url = https://auth.localhost/application/o/token/
api_url = https://auth.localhost/application/o/userinfo/
role_attribute_path = contains(groups[*], 'grafana-admins') && 'Admin' || 'Viewer'
```

Authentik Application settings:
- Redirect URI: `https://grafana.localhost/login/generic_oauth`
- Scopes: `openid`, `email`, `profile`

#### OpenWebUI

Add environment variables to `config.json` under `openwebui.environment`:

```json
"OAUTH_CLIENT_ID": "<openwebui-client-id>",
"OAUTH_CLIENT_SECRET": "<openwebui-client-secret>",
"OPENID_PROVIDER_URL": "https://auth.localhost/application/o/openwebui/.well-known/openid-configuration",
"OAUTH_SCOPES": "openid email profile",
"ENABLE_OAUTH_SIGNUP": "true"
```

Authentik Application settings:
- Redirect URI: `https://webui.localhost/oauth/callback`
- Scopes: `openid`, `email`, `profile`

#### Flowise

Flowise v3 does not natively support OIDC. Protection is handled entirely via Traefik forward-auth (already applied by the `authentik` middleware in `services.yaml`). No per-service OIDC configuration is needed.

### Service OIDC Summary

| Service | OIDC Support | Redirect URI | Method |
|---------|-------------|--------------|--------|
| OpenWebUI | Native (`OAUTH_*` env vars) | `https://webui.localhost/oauth/callback` | Per-service OIDC |
| Grafana | Native (`generic_oauth`) | `https://grafana.localhost/login/generic_oauth` | Per-service OIDC |
| Flowise | None — proxy only | N/A | Traefik forward-auth only |
| Prometheus | None — proxy only | N/A | Traefik forward-auth only |

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

Alert rules are stored in `configs/prometheus/rules/ai_stack_alerts.yml` (repo) and deployed to `$AI_STACK_DIR/configs/prometheus/rules/` by `deploy-stack.sh`. Prometheus is configured to load them via `rule_files` in `configs/prometheus/prometheus.yml`.

### Defined Alerts

| Alert | Group | Condition | For | Severity |
|-------|-------|-----------|-----|----------|
| `ContainerDown` | service_health | `up == 0` | 2m | Critical |
| `PostgresUnhealthy` | service_health | `up{job="postgres"} == 0` | 2m | Critical |
| `QdrantUnhealthy` | service_health | `up{job="qdrant"} == 0` | 2m | Critical |
| `LiteLLMUnhealthy` | service_health | `up{job="litellm"} == 0` | 2m | Critical |
| `InferenceLatencyHigh` | inference_performance | p95 latency > 10s | 5m | Warning |
| `InferenceErrorRateHigh` | inference_performance | LiteLLM error rate > 10% | 5m | Warning |
| `GPUMemoryHigh` | gpu_resources | GPU VRAM > 90% | 5m | Critical |
| `DiskUsageHigh` | host_resources | Root FS > 85% | 10m | Warning |
| `DiskUsageCritical` | host_resources | Root FS > 95% | 5m | Critical |
| `ContainerRestartLooping` | host_resources | >3 restarts in 10m | 0m | Warning |
| `LokiIngestionStalled` | loki_pipeline | `up{job="loki"} == 0` | 5m | Warning |

### Alertmanager

Prometheus fires alerts to Alertmanager (not yet deployed). To receive notifications, add Alertmanager to the stack:

1. Add `alertmanager` service to `config.json`
2. Configure notification channel (email, PagerDuty, Slack) in `configs/prometheus/alertmanager.yml`
3. Add `alerting.alertmanagers` stanza to `configs/prometheus/prometheus.yml`

Without Alertmanager, alerts are visible in the Prometheus UI at `http://prometheus.localhost/alerts`.

### Updating rules

Prometheus hot-reloads rules on SIGHUP:
```bash
kill -HUP $(podman exec prometheus cat /tmp/prometheus.pid 2>/dev/null) 2>/dev/null || \
    curl -sf -X POST http://localhost:9091/-/reload
```

---

# 8 Backup and Restore

The `scripts/backup.sh` script handles all data backup and restore. See that file for full usage. This section documents the procedure and important notes.

### What is backed up

| Data | Backup method | Retention | Restore method |
|------|--------------|-----------|----------------|
| PostgreSQL | `pg_dumpall` via `podman exec` | 7 backup sets | `psql` restore via `podman exec -i` |
| Qdrant | Snapshot API per collection | 7 backup sets | Upload snapshot via REST API |
| Knowledge libraries | `tar -czf` of `$AI_STACK_DIR/libraries/` | 7 backup sets | `tar -xzf` |
| Service configuration | `tar -czf` of `$AI_STACK_DIR/configs/` (excludes TLS private keys) | 7 backup sets | `tar -xzf` |
| Podman secrets | Not automated — manual export required | Operator responsibility | `printf '%s' <value> \| podman secret create --replace <name> -` |
| TLS certificates | Not in backup — regenerate with `generate-tls.sh` | N/A | `scripts/generate-tls.sh` |

### Running a backup

```bash
# One-off backup
scripts/backup.sh

# With custom retention (keep 14 sets)
BACKUP_KEEP=14 scripts/backup.sh

# Dry run (see what would be done)
scripts/backup.sh --dry-run
```

Backup sets are stored in `$AI_STACK_DIR/backups/<timestamp>/`.

### Setting up a daily backup timer

```ini
# ~/.config/systemd/user/ai-stack-backup.service
[Unit]
Description=AI Stack daily backup
After=postgres.service qdrant.service

[Service]
Type=oneshot
ExecStart=%h/Projects/active/llm-agent-local-2/scripts/backup.sh
Environment=AI_STACK_DIR=%h/ai-stack
```

```ini
# ~/.config/systemd/user/ai-stack-backup.timer
[Unit]
Description=Run AI Stack backup daily at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
systemctl --user daemon-reload
systemctl --user enable --now ai-stack-backup.timer
```

### Restore procedure

**Before restoring:**
1. Stop all stack services (the restore script does this automatically when run interactively)
2. Confirm the backup timestamp to restore from: `ls $AI_STACK_DIR/backups/`
3. Ensure Podman secrets are still intact (secrets are not backed up automatically)

```bash
# List available backup sets
ls $AI_STACK_DIR/backups/

# Restore from a specific backup set
scripts/backup.sh --restore 20260308T020000
```

The restore script will:
1. Prompt for confirmation
2. Stop all running services
3. Start PostgreSQL temporarily and restore from `postgres_all.sql`
4. Start Qdrant temporarily and upload each collection's snapshot
5. Extract `libraries.tar.gz` and `configs.tar.gz` in place
6. Print instructions for restarting services in the correct order

**After restoring:**
- If TLS certificates were not in the backup, run `scripts/generate-tls.sh`
- Verify all services start cleanly: `journalctl --user -u <service>.service -n 50`
- Run `bats testing/layer1_smoke.bats` to validate service reachability

### Secrets export (manual)

Podman secrets cannot be read back after creation. Store the source values in a secure secrets manager (e.g., pass, Bitwarden, HashiCorp Vault) and re-create them after a restore:

```bash
printf '%s' '<value>' | podman secret create --replace postgres_password -
printf '%s' '<value>' | podman secret create --replace litellm_master_key -
printf '%s' '<value>' | podman secret create --replace qdrant_api_key -
printf '%s' '<value>' | podman secret create --replace openwebui_api_key -
printf '%s' '<value>' | podman secret create --replace flowise_password -
printf '%s' '<value>' | podman secret create --replace authentik_secret_key -
```

---

# 9 Troubleshooting

### Diagnostic commands

```bash
# Check service status and recent logs
journalctl --user -u <service>.service -n 50

# Fast go/no-go signal — all 11 deployed services
bats testing/layer0_preflight.bats testing/layer1_smoke.bats

# Full component-level diagnostics
bats testing/layer2_*.bats

# Container health state
podman ps --format "table {{.Names}}\t{{.Status}}\t{{.Health}}"

# List failed units
systemctl --user list-units --state=failed
```

### Common issues

| Symptom | Likely Cause | Resolution |
|---------|-------------|------------|
| Service unit fails to start | Dependency not ready; secret missing | Check `journalctl --user -u <svc>.service`; run `configure.sh validate` |
| `podman: secret not found` | Secret not created | Run `scripts/configure.sh generate-secrets` |
| GPU not visible in container | CDI not configured | Run `sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml` (§4) |
| vLLM OOM crash | Model too large for VRAM | Lower `GPU_MEMORY_UTILIZATION` or `MAX_MODEL_LEN` in config.json; use a smaller GGUF |
| Qdrant disk growing unbounded | No vector TTL configured | Set per-collection TTL via Qdrant API; expand `$AI_STACK_DIR/qdrant` volume path |
| Containers fail to resolve DNS | Network not yet created | `podman network create ai-stack-net`; or `scripts/deploy-stack.sh` creates it |
| Permission denied on volumes | Rootless UID/SELinux | Ensure all volume mounts use `:Z` (done by `configure.sh generate-quadlets`) |
| Traefik 502 Bad Gateway | Backend container not running | Check backend service: `podman ps`, `systemctl --user start <svc>.service` |
| Authentik outpost not responding | Outpost not started or embedded outpost misconfigured | `journalctl --user -u authentik.service -n 100`; check outpost config in Authentik admin |
| LiteLLM returns 500 for all models | No model backend is reachable | Check vllm/llamacpp service status; verify model file exists in `$AI_STACK_DIR/models/` |
| Grafana datasource shows error | Prometheus/Loki not reachable from Grafana container | Verify Prometheus/Loki are running; check internal DNS `prometheus.ai-stack:9090` from Grafana network |
| TLS certificate not trusted | CA cert not installed in browser/OS | Trust `$AI_STACK_DIR/configs/tls/ca.crt`: `sudo update-ca-trust` (see `scripts/generate-tls.sh`) |
| `pg_isready` fails after restart | PostgreSQL data directory ownership issue | Check `:Z` on volume mount; run `podman unshare ls -la $AI_STACK_DIR/postgres` |
| Loki log gaps | Promtail not running or watched path missing | `systemctl --user status promtail.service`; verify `scrape_configs.static_configs.labels.__path__` in promtail config |

### Container does not start after `daemon-reload`

```bash
# Validate the generated quadlet file
systemd-analyze verify ~/.config/containers/systemd/<service>.container

# Regenerate quadlets from config
scripts/configure.sh generate-quadlets
systemctl --user daemon-reload
```

### Reset a single service to a clean state

```bash
svc=<service>
systemctl --user stop ${svc}.service
podman rm -f "$svc" 2>/dev/null || true
systemctl --user start ${svc}.service
journalctl --user -u ${svc}.service -f
```

### Inspect all container health states

```bash
for svc in traefik postgres qdrant authentik litellm openwebui \
           prometheus grafana loki flowise promtail; do
    health=$(podman inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || echo 'not running')
    printf '  %-15s %s\n' "$svc" "$health"
done
```

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

