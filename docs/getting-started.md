# Getting Started

**Last Updated:** 2026-03-25

A step-by-step guide to installing, configuring, deploying, and verifying the AI stack on a new Linux controller node.

---

## Prerequisites

| Requirement | Notes |
|---|---|
| Linux (Fedora/RHEL/CentOS) | Tested on Fedora 40+; other systemd-based distros should work |
| Podman 4.x+ | Rootless mode; systemd user units (quadlets) |
| Python 3.9+ | Used by `configure.sh` and the knowledge-index service |
| `git`, `jq` | Required by all scripts |
| NVIDIA GPU (optional) | Required for vLLM; Ollama runs on CPU without it |

---

## Step 1 — Clone the repository

```bash
git clone git@github.com:digital-michael/local-lab-ai-stack.git
cd local-lab-ai-stack
```

---

## Step 2 — Install system dependencies and create the storage layout

```bash
bash scripts/install.sh
```

This installs `podman`, `git`, and `python3` via `dnf`, then creates the storage layout under `$AI_STACK_DIR` (default: `~/ai-stack`).

To use a custom storage location:

```bash
AI_STACK_DIR=/opt/ai-stack bash scripts/install.sh
```

---

## Step 3 — Validate the environment

```bash
bash scripts/validate-system.sh
```

Checks that Podman is installed, the storage directory exists, and (optionally) that a GPU is detected. Exits non-zero on any error.

---

## Step 4 — Generate TLS certificates

```bash
bash scripts/generate-tls.sh
```

Creates a local CA and a server certificate under `~/ai-stack/configs/tls/`. Traefik uses these for HTTPS on all services.

> To trust the local CA in your browser, follow the instructions printed by the script.

---

## Step 5 — Review and edit configuration

Open `configs/config.json` to verify defaults. Most values are ready to use, but you should at minimum review:

- `"node_profile"` — should be `"controller"` on the primary machine
- `"models"` — add or remove models depending on your hardware (see [How-To: Add a Model](operator-faq.md#add-a-new-ollama-model))
- GPU-backed models require an NVIDIA GPU with CDI configured (see [How-To: Enable GPU Inference](operator-faq.md#enable-gpu-inference))

To run hardware detection and get a recommended configuration:

```bash
bash scripts/configure.sh detect-hardware
bash scripts/configure.sh recommend
```

---

## Step 6 — Generate LiteLLM model config

```bash
bash scripts/configure.sh generate-litellm-config
```

Reads `models[]` from `config.json` and writes `configs/models.json`, which LiteLLM uses as its routing table. Re-run this whenever you add or change models.

---

## Step 7 — Provision secrets

```bash
bash scripts/configure.sh generate-secrets
```

Prompts you to enter values for each required secret and stores them in the Podman secret store. Required secrets:

| Secret | Purpose |
|---|---|
| `postgres_password` | PostgreSQL admin password |
| `litellm_master_key` | Bearer token for LiteLLM API |
| `qdrant_api_key` | Qdrant API authentication |
| `openwebui_api_key` | OpenWebUI → LiteLLM auth (must match `litellm_master_key`) |
| `flowise_password` | Flowise admin password |
| `knowledge_index_api_key` | Knowledge Index Service API key |
| `minio_root_user` | MinIO root username |
| `minio_root_password` | MinIO root password |

> **Important:** `openwebui_api_key` must be set to the same value as `litellm_master_key`. The `generate-secrets` script derives it automatically if you leave it blank.

---

## Step 8 — Validate configuration

```bash
bash scripts/configure.sh validate
```

Checks that all required fields are present, no tags are `TBD`, and the node profile is valid. Fix any errors before continuing.

---

## Step 9 — Deploy

```bash
bash scripts/deploy.sh
```

Validates config, generates systemd quadlet files into `~/.config/containers/systemd/`, and creates the Podman network.

---

## Step 10 — Start services

```bash
bash scripts/start.sh
```

Starts all services in dependency order via systemd user units. On first run this will pull container images — allow several minutes depending on network speed.

Check progress at any time:

```bash
bash scripts/status.sh
```

---

## Step 11 — Pull and register models

```bash
# Pull models into Ollama's model store
podman exec ollama ollama pull llama3.1:8b

# Register all model routes in LiteLLM
bash scripts/pull-models.sh
```

---

## Step 12 — Verify

```bash
bash scripts/status.sh -v
```

All services should show `active`. Then open a browser and navigate to `https://localhost` — you should see the Authentik login page. Create your account and start using the stack.

Run the offline preflight tests to confirm everything is wired correctly:

```bash
bats testing/layer0_preflight.bats
```

---

## Step 13 — Enroll the node in the Headscale tailnet (multi-node deployments)

If this node needs to reach the controller (or peers) across the internet, enroll it in the WireGuard overlay mesh managed by Headscale at `headscale.photondatum.space`.

**Prerequisites:** `tailscale` installed and daemon running. A pre-auth key issued by the Headscale operator.

### 1. Clear any existing Tailscale enrollment

```bash
sudo tailscale logout
# A TLS error from the old coordination server is expected — local state is still cleared.
```

### 2. Enroll

```bash
sudo tailscale up \
  --login-server https://headscale.photondatum.space \
  --authkey <preauthkey> \
  --hostname <node-alias> \
  --reset --force-reauth
```

- `--reset` clears prior non-default flags (e.g. `--exit-node-allow-lan-access`)
- `--force-reauth` is required when a prior enrollment exists; safe to omit on a fresh node
- Do **not** pass `--ssh` or `--exit-node-allow-lan-access` — Tailscale cloud-only flags; will error on a Headscale server

### 3. Confirm enrollment

```bash
tailscale status   # node should show online with a 100.64.x.x IP
```

The Headscale operator must then tag the node on the server. **Always pass all desired tags in one command** — the `tag` subcommand replaces, not appends:

```bash
# Standard enrollment — role tag + namespace tag (required for ACL to permit the node):
sudo headscale nodes tag --identifier <node-ID> \
  --tags tag:<role>,tag:net-ecotone-000-01
# Role tags: controller  inference  knowledge

# To additionally expose the node to any peer in the tailnet (e.g. a shared inference worker):
sudo headscale nodes tag --identifier <node-ID> \
  --tags tag:<role>,tag:net-ecotone-000-01,tag:net-public
```

**ACL model:** The tailnet runs namespace-isolated ACLs. Only nodes bearing `tag:net-ecotone-000-01` can communicate by default. Nodes tagged `tag:net-public` are additionally reachable from any enrolled node (all ports). A node with neither tag cannot send or receive tailnet traffic.

For per-node commands specific to this cluster, see the CENTAURI playbook §7.8.

---

## Quick Reference — Day-to-Day Commands

| Goal | Command |
|---|---|
| Start all services | `bash scripts/start.sh` |
| Stop all services | `bash scripts/stop.sh` |
| Check service health | `bash scripts/status.sh` |
| Run diagnostics | `bash scripts/diagnose.sh --profile full` |
| Back up all data | `bash scripts/backup.sh` |
| Run security audit | `bash scripts/configure.sh security-audit` |
| Update model routes | `bash scripts/pull-models.sh` |

---

## Next Steps

- [Operator FAQ and How-To Guides](operator-faq.md) — add models, register nodes, ingest documents, troubleshoot
- [Feature Overview](features.md) — full capability inventory
- [Architecture](ai_stack_blueprint/ai_stack_architecture.md) — system design reference
