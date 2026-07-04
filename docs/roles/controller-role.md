# Controller Role

## Purpose

The controller role runs on the primary compute host — typically a residential
machine with substantial RAM and optional GPU. It orchestrates AI inference,
manages the knowledge pipeline, hosts user-facing applications, and aggregates
observability data from all nodes. All AI workloads route through this role.

The controller depends on the edge role for external SSO login. It remains
fully functional on the LAN and tailnet when the edge role is offline, but
external user authentication (social login, `forward_auth`) will fail until
the edge role recovers.

---

## Target Hardware Profile

| Property | Minimum | Recommended |
|---|---|---|
| RAM | 16 GB | 32 GB+ |
| CPU | 6 cores | 12+ cores |
| GPU | None (CPU inference) | NVIDIA GPU (8GB+ VRAM) |
| Storage | 100 GB | 500 GB+ (model storage) |
| Network | LAN + tailnet | LAN + tailnet |
| Availability | On when needed | Sleep-inhibited during active use |

---

## Deployment Groups

### Group: `ai-stack-route`

Internal reverse proxy and auth enforcement. Traefik routes all LAN/tailnet
traffic to backend services, calling Authentik for `forwardAuth` on every
protected route. Runs on host network to bind :80/:443.

**Network:** `host` + joins all other group networks to reach backends
**SystemD target:** `ai-stack-route.target`

| Container | Image | Purpose |
|---|---|---|
| `ai-stack-route-traefik` | `docker.io/traefik:v3` | Internal reverse proxy, TLS, forwardAuth |

**Key configuration:**
- `forwardAuth` middleware points to `https://auth.<domain>` (the always-on edge Authentik)
- Self-signed TLS for LAN access; Traefik manages the cert
- Traefik must join every group network to route to backends

---

### Group: `ai-stack-infer`

AI inference gateway and runtimes. LiteLLM provides a unified OpenAI-compatible
API across all backends. Ollama runs local models. vLLM is optional and requires
a CUDA-capable GPU. TurboQuant is a one-shot model optimization tool — it
compresses model weights before loading into Ollama/vLLM and does not run
continuously.

**Network:** `ai-stack-infer`
**SystemD target:** `ai-stack-infer.target`

| Container | Image | Purpose | Notes |
|---|---|---|---|
| `ai-stack-infer-litellm` | `ghcr.io/berriai/litellm` | Model gateway — unified API | File config mode; no DB dependency |
| `ai-stack-infer-ollama` | `docker.io/ollama/ollama` | Local model runtime — CPU/GPU | |
| `ai-stack-infer-vllm` | `docker.io/vllm/vllm-openai` | GPU-accelerated runtime | Optional; GPU nodes only |
| `ai-stack-infer-turbo` | TBD | TurboQuant model compression | One-shot; not started at boot |

**LiteLLM file config mode:**
Model routes live in `configs/litellm/proxy_config.yaml`. No PostgreSQL dependency.
Adding a model = edit the config file + `systemctl --user restart ai-stack-infer-litellm.service`.
Spend tracking and virtual key management are not available in file mode; upgrade to
DB mode and connect to `ai-stack-store-postgres` if those features are needed.

**TurboQuant placeholder:**
No stable open-source container image confirmed at time of writing. Reserved as a
named slot in the `infer` group. When available: run as a one-shot container against
a model file to produce a compressed weight artifact, then restart Ollama/vLLM to
pick up the new weights. Does not start at boot; invoked during model provisioning.

**Startup order within group:**
1. `ai-stack-infer-ollama` (+ `ai-stack-infer-vllm` if GPU present, parallel)
2. `ai-stack-infer-litellm` (after at least one runtime healthy)

---

### Group: `ai-stack-know`

Knowledge pipeline and vector storage. The knowledge-index ingests documents,
chunks and embeds them, and serves RAG queries. Qdrant owns the vector index
and is exclusive to this group — no other group reads or writes it directly.

**Network:** `ai-stack-know` + joins `ai-stack-infer` (for embedding calls to LiteLLM)
**SystemD target:** `ai-stack-know.target`

| Container | Image | Purpose |
|---|---|---|
| `ai-stack-know-index` | `localhost/knowledge-index:0.1.0` | Ingest, chunk, embed, serve RAG |
| `ai-stack-know-qdrant` | `docker.io/qdrant/qdrant` | Vector store — exclusive to know group |

**Cross-group dependency:**
`ai-stack-know-index` calls LiteLLM for embeddings via `ai-stack-infer-litellm`.
The container joins both `ai-stack-know` and `ai-stack-infer` networks.

**Startup order within group:**
1. `ai-stack-know-qdrant`
2. `ai-stack-know-index` (after qdrant healthy)

---

### Group: `ai-stack-app`

User-facing applications. OpenWebUI provides the AI chat interface. Flowise
builds agent workflows. Homepage is the service dashboard. These containers
all call LiteLLM for model access and authenticate via Authentik forwardAuth
through Traefik.

**Network:** `ai-stack-app` + joins `ai-stack-infer` + `ai-stack-store`
**SystemD target:** `ai-stack-app.target`

| Container | Image | Purpose |
|---|---|---|
| `ai-stack-app-openwebui` | `ghcr.io/open-webui/open-webui` | AI chat interface |
| `ai-stack-app-flowise` | `docker.io/flowiseai/flowise` | Agent workflow builder |
| `ai-stack-app-homepage` | `ghcr.io/gethomepage/homepage` | Service dashboard |

**Startup order within group:**
1. All app containers in parallel (after `ai-stack-store-postgres` healthy)

---

### Group: `ai-stack-store`

Application data storage. One PostgreSQL instance serves OpenWebUI and Flowise.
No other groups use this instance — the IAM group has its own dedicated PostgreSQL
on the edge node.

**Network:** `ai-stack-store`
**SystemD target:** `ai-stack-store.target`

| Container | Image | Purpose |
|---|---|---|
| `ai-stack-store-postgres` | `docker.io/library/postgres:16` | App database — openwebui + flowise |

**Volumes:**
| Volume | Mount | Purpose |
|---|---|---|
| `ai-stack-store-postgres-data` | `/var/lib/postgresql/data` | Persistent database |

**Databases within the instance:**
- `openwebui` — OpenWebUI conversations, users, settings
- `flowise` — Flowise chatflows, credentials, API keys

**Storage split:**
This PostgreSQL instance is intentionally separate from `ai-stack-iam-postgres`
on the edge node. IAM data and application data have different backup frequencies,
different availability requirements, and different lifecycle events.

---

### Group: `ai-stack-obs`

Observability aggregation. Prometheus scrapes metrics from all services.
Grafana visualizes them. Loki aggregates logs. Promtail runs as an agent on
every node (including edge and workers) and ships to this Loki instance.

**Network:** `ai-stack-obs`
**SystemD target:** `ai-stack-obs.target`

| Container | Image | Purpose | Node |
|---|---|---|---|
| `ai-stack-obs-prometheus` | `docker.io/prom/prometheus` | Metrics store | controller |
| `ai-stack-obs-grafana` | `docker.io/grafana/grafana` | Dashboards | controller |
| `ai-stack-obs-loki` | `docker.io/grafana/loki` | Log aggregation | controller |
| `ai-stack-obs-promtail` | `docker.io/grafana/promtail` | Log shipping agent | every node |

**Startup order within group:**
1. `ai-stack-obs-loki` + `ai-stack-obs-prometheus` (parallel)
2. `ai-stack-obs-grafana` (after loki + prometheus healthy)
3. `ai-stack-obs-promtail` (independent — starts any time)

---

## Network Topology

### Isolated mode (default for controller)

Each group has its own Podman network. Traefik joins every group network to
route requests to backends. Containers that need cross-group access declare
multiple `Network=` entries in their quadlet.

```
[tailnet/LAN] → ai-stack-route-traefik (host net)
                    │ joins all group networks
                    ├─→ ai-stack-app-openwebui  (ai-stack-app)
                    ├─→ ai-stack-app-flowise     (ai-stack-app)
                    ├─→ ai-stack-obs-grafana     (ai-stack-obs)
                    └─→ ai-stack-know-index      (ai-stack-know)

ai-stack-know-index   → ai-stack-infer-litellm  (cross: ai-stack-know + ai-stack-infer)
ai-stack-app-openwebui→ ai-stack-infer-litellm  (cross: ai-stack-app + ai-stack-infer)
ai-stack-app-flowise  → ai-stack-store-postgres (cross: ai-stack-app + ai-stack-store)
```

### Combined mode (instance override)

Single `ai-stack` network. All containers reachable by name. No explicit
cross-group joins needed. Appropriate for development or resource-constrained
deployments.

---

## Startup Order (full controller role)

```
1. ai-stack-store-postgres          ← data layer first
   ai-stack-know-qdrant             │ parallel
   ai-stack-obs-loki                │
   ai-stack-obs-prometheus          │

2. ai-stack-infer-ollama            ← runtimes (no DB dep)
   ai-stack-infer-vllm              │ parallel

3. ai-stack-infer-litellm           ← gateway (after runtimes)
   ai-stack-obs-grafana             │ parallel (after loki + prometheus)

4. ai-stack-know-index              ← after qdrant + litellm
   ai-stack-app-openwebui           │ parallel (after store-postgres + litellm)
   ai-stack-app-flowise             │
   ai-stack-app-homepage            │

5. ai-stack-obs-promtail            ← any time
   ai-stack-route-traefik           ← any time (routes fail gracefully until backends ready)
```

SystemD target for full role: `ai-stack-controller-role.target`
(Wants= all group targets above)

---

## Pre-Deployment Checklist

- [ ] Tailscale enrolled; node visible to Headscale on edge node
- [ ] Traefik `forwardAuth` URL points to `https://auth.<domain>` (edge Authentik)
- [ ] Traefik TLS cert covers all `*.stack.localhost` or LAN hostnames
- [ ] PostgreSQL: separate databases for `openwebui` and `flowise` within the instance
- [ ] Qdrant API key provisioned as Podman secret
- [ ] LiteLLM `proxy_config.yaml` populated with at least one model route
- [ ] At least one Ollama model pulled before starting OpenWebUI
- [ ] Promtail configured to ship to `ai-stack-obs-loki:3100` on the controller
- [ ] GPU passthrough configured if vLLM or GPU-accelerated Ollama is planned
- [ ] Sleep inhibitor configured if Ollama should not be interrupted during inference

---

## Instance Customization

Instance overlay documents provide:

| Setting | Instance override |
|---|---|
| Hostname and tailnet IP | CENTAURI, `100.64.0.4` |
| Network mode | isolated vs combined |
| GPU configuration | vLLM enabled/disabled, device flags |
| Traefik router hostnames | Per-instance domain patterns |
| PostgreSQL DB names and users | Per-instance credentials |
| Model list | Which models are pulled to Ollama |
| Resource limits | `--cpus`, `--memory` per container |
| Sleep inhibitor | Enabled/disabled per host |

See: [docs/instances/centauri.md](../instances/centauri.md)
