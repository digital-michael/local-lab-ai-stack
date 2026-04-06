---
name: generate-playbook
description: 'Generate a complete, standalone operational playbook for the current AI stack deployment. Use when: creating or refreshing a point-in-time snapshot playbook; documenting the cluster before handoff or archival; after any image tag, secret rotation, node change, or make test-all failure pattern changes. Reads config.json, node configs, and live system state. Writes to ./output/. NEVER embeds secret values — uses Podman extraction patterns throughout.'
argument-hint: 'Optional: output filename override (default: <hostname>-playbook.md in ./output/)'
---

# Generate Operational Playbook

Produces `./output/<hostname>-playbook.md`: a complete, standalone, point-in-time
operational reference for the deployed AI stack cluster.  No cross-references to other
repo docs are needed to use it — all values are pulled from live config and system state
at the time of generation.

---

## When to Regenerate

Regenerate whenever any of the following occur:

- A service image tag is bumped in `configs/config.json`
- A secret is rotated or re-provisioned
- A node is added, removed, or changes status
- `make test-all` produces a new or resolved failure pattern
- Hardware changes on any node
- After a full cold-boot verification cycle (`T-054`)

---

## Security Constraint — Secrets

**Never embed secret values in the output document.** Every CLI example that
requires authentication MUST use inline Podman secret extraction.

Three verified patterns (Podman 5.8.x):

```bash
# Pattern A — inline substitution (preferred for curl / CLI one-liners)
$(podman secret inspect <secret-name> --showsecret --format '{{.SecretData}}')

# Pattern B — via alpine container (works on older Podman without --showsecret)
$(podman run --rm --secret <secret-name> alpine sh -c 'cat /run/secrets/<secret-name>')

# Pattern C — read from running container environment (verify what the container sees)
podman exec <container-name> env | grep <ENV_VAR_NAME>
```

Include the following note **once**, in §4.1 of the output document:

> **Shell history note:** Inline `$()` patterns embed the resolved secret value in the
> expanded command string, which appears in `~/.bash_history`. To suppress: prefix the
> command with a space (requires `HISTCONTROL=ignorespace`) or run `unset HISTFILE`
> before the session.

---

## Prerequisites

- Working directory is the project root (contains `Makefile` and `configs/config.json`)
- Core services are active: `bash scripts/status.sh` shows no unexpected `failed` state
- `podman`, `jq`, and `python3` are available on `$PATH`
- `output/` directory will be created if it does not exist (`mkdir -p output/`)

---

## Phase 1 — Collect System State

Run **all** of the following commands before writing any section.  Capture their output
verbatim; never approximate or use cached values.

```bash
# ── Identity ─────────────────────────────────────────────────────────────────
HOSTNAME=$(hostname -s)
TODAY=$(date +%Y-%m-%d)
GIT_COMMIT=$(git log --oneline -1 2>/dev/null || echo "no git")
PODMAN_VER=$(podman --version)

# ── Core config values ───────────────────────────────────────────────────────
AI_STACK_DIR=$(jq -r '.ai_stack_dir | gsub("\\$HOME"; env.HOME)' configs/config.json)
NODE_PROFILE=$(jq -r '.node_profile' configs/config.json)
NETWORK=$(jq -r '.network.name' configs/config.json)

# ── Service inventory (image:tag, ports, bind address, dependencies) ─────────
python3 - <<'PYEOF'
import json, os
with open('configs/config.json') as f:
    cfg = json.load(f)
for svc, v in cfg['services'].items():
    img  = v.get('image', '?')
    tag  = v.get('tag', '?')
    ports = v.get('ports', [])
    deps  = v.get('depends_on', [])
    bind_ports = [(p.get('bind','?'), p['host']) for p in ports]
    print(f"{svc}|{img}:{tag}|{bind_ports}|{deps}")
PYEOF

# ── Secrets per service ───────────────────────────────────────────────────────
python3 - <<'PYEOF'
import json
with open('configs/config.json') as f:
    cfg = json.load(f)
for svc, v in cfg['services'].items():
    for s in v.get('secrets', []):
        print(f"{svc}|{s['name']}|{s['target']}")
PYEOF

# ── Model inventory ───────────────────────────────────────────────────────────
python3 - <<'PYEOF'
import json
with open('configs/config.json') as f:
    cfg = json.load(f)
for m in cfg.get('models', []):
    print(f"{m['name']}|{m.get('backend')}|{m.get('device','-')}")
PYEOF

# ── Node inventory ────────────────────────────────────────────────────────────
for f in configs/nodes/*.json; do
    jq -r '[.node_id, (.alias // "-"), .profile,
            (.address // .address_fallback // "-"),
            (.status // "unknown")] | @tsv' "$f"
done

# ── Live service states ───────────────────────────────────────────────────────
bash scripts/status.sh

# ── Provisioned secrets (names only — never values) ──────────────────────────
podman secret ls --format '{{.Name}}'

# ── Loki retention ────────────────────────────────────────────────────────────
grep retention_period configs/loki/local-config.yaml 2>/dev/null || echo "168h"

# ── Storage layout ────────────────────────────────────────────────────────────
ls -1 "$AI_STACK_DIR/" 2>/dev/null || ls -1 ~/ai-stack/ 2>/dev/null

# ── Grafana dashboards provisioned ────────────────────────────────────────────
ls -1 configs/grafana/provisioning/dashboards/ 2>/dev/null || echo "(none found)"

# ── Last known test result (if available) ────────────────────────────────────
# Run manually if system is healthy; note the 3 known pre-existing failures:
#   T-019: Authentik via Traefik proxy
#   T-023: TLS SAN check on port 443
#   T-047: Promtail→Loki e2e within 60s
# make test-all 2>&1 | grep -E '✗|FAILED|passed|failed|skipped'
```

---

## Phase 2 — Document Structure

Use the section map below to build the output document.  Each subsection notes its
data source, required content, and any special rules.

### Document Header

```markdown
# <HOSTNAME> Cluster — Operational Playbook

**Cluster:** <HOSTNAME> (controller) + <worker aliases from nodes/*.json>
**Last Updated:** <TODAY>
**Config Snapshot:** commit <GIT_COMMIT>
**Node Profile:** <NODE_PROFILE>
**Podman Version:** <PODMAN_VER>

> **Freshness Contract:** Regenerate this document when any image tag changes, a secret
> is rotated, a node is added or removed, or `make test-all` shows new failures.
> Generator: `docs/library/actions/generate-playbook/SKILL.md`

---
```

Follow with a full Table of Contents using internal anchor links for all 12 sections,
then an Index anchor at the bottom.

---

### §1 — About This Document

Content:

- What this document covers: the established cluster, operational reference for a human
  or agent operating it day-to-day
- What it does NOT cover: architecture decisions (→ `docs/ai_stack_blueprint/ai_stack_architecture.md`),
  feature roadmap (→ `docs/features.md`), agent API surfaces
- How to use it: TOC for navigation, §12 Index for keyword lookup
- How to regenerate: run the skill at `docs/library/actions/generate-playbook/SKILL.md`
- Security note: no secret values appear in this document; §4.1 shows extraction patterns

---

### §2 — System Snapshot

**§2.1 Node Inventory** — Source: `configs/nodes/*.json`

Table columns: Node ID | Alias | Role | Profile | Address | Status | OS (if known)

Mark the controller node explicitly.  Include hardware notes (GPU, RAM) if captured
in the node config or known at time of generation.

**§2.2 Service Inventory** — Source: config.json service extraction

Table columns: Service | Image:Tag | Host Port | Bind | Current State

Group rows by layer using the documentation convention:
Application → Edge → Inference → Knowledge → Storage → Observability

Within each layer, order by "most directly exposed to caller" first
(e.g. LiteLLM before Ollama/vLLM; see D-001 in docs/meta_local/decisions.md).

Mark services that are intentionally stopped (e.g., vllm when GPU is not active).

**§2.3 Model Inventory** — Source: config.json models[] + live Ollama check

```bash
# Cross-check: what LiteLLM knows vs. what Ollama has pulled
podman exec ollama ollama list
curl -s -H "Authorization: Bearer $(podman secret inspect litellm_master_key \
  --showsecret --format '{{.SecretData}}')" \
  http://localhost:9000/v1/models | python3 -c \
  "import sys,json; [print(m['id']) for m in json.load(sys.stdin)['data']]"
```

Table columns: Model Name (LiteLLM ID) | Backend | Device | Pulled to Ollama

**§2.4 Storage Layout** — Source: `ls -1 $AI_STACK_DIR/`

Annotated directory tree.  Expand `$HOME` to the real path.  List each subdirectory
with a one-line purpose note (e.g., `libraries/` — mounted read-only into knowledge-index
for localhost discovery profile).

**§2.5 Active Configuration Highlights** — Source: config.json

Capture these key values explicitly so the snapshot is self-contained:

- `ai_stack_dir` (expanded)
- `node_profile`
- `network.name`
- Loki retention period
- `sleep_inhibit` setting
- `BACKUP_KEEP` (if set)

---

### §3 — Architecture Reference

**§3.1 Layer Diagram**

Mermaid diagram showing all 15 services in their layers, with arrows derived from
`depends_on` in config.json.  Use top-down flowchart style (`graph TB`).

**§3.2 Service Dependency Graph** — Source: config.json `depends_on`

Table columns: Service | Depends On | Cascade Impact (what stops when this service stops)

Explicitly note multi-level cascades:
- postgres stops → litellm + authentik + knowledge-index stop
- qdrant stops → knowledge-index stops
- litellm stops → openwebui + flowise + ollama + vllm stop

**§3.3 Startup / Shutdown Order**

Ordered numbered list with parallel groups (services at the same depth can start
together).  Derive from dependency graph.

Include manual override commands for each group:
```bash
systemctl --user start postgres.service qdrant.service
# wait for health checks, then:
systemctl --user start authentik.service litellm.service knowledge-index.service
```

**§3.4 Network Topology** — Source: config.json ports/bind + nodes/*.json

Table: Service | Host Port | Bind | LAN Accessible?

Separate table for internal container DNS aliases (`dns_alias` from config.json):
Container Name | DNS Alias | Internal Base URL

Worker node LAN addresses from nodes/*.json.

---

### §4 — Secrets Reference

**§4.1 How to Read a Secret**

Show all three Podman extraction patterns (A, B, C) as documented in the Security
Constraint section above.  Include the shell history advisory note.

State explicitly: "Verified against Podman 5.8.x on Fedora Linux."

**§4.2 Secret × Service × Env-Var Matrix**

Source: python3 extraction from config.json secrets[] arrays.

Full table columns: Secret Name | Services That Use It | Env Var in Container | Purpose | Optional?

Annotations (apply inline):
- `openwebui_api_key` → must equal `litellm_master_key`; mark with ⚠ LINKED
- `flowise_secret_key` → AES credential encryption key; mark with ⚠ ROTATION DANGER
- `openai_api_key`, `groq_api_key`, `anthropic_api_key`, `mistral_api_key` → mark (optional — cloud routing)

**§4.3 Linked Secrets**

Write a dedicated warning block for each linked/dangerous secret:

1. **`openwebui_api_key = litellm_master_key`**: OpenWebUI uses this as the Bearer token
   when calling LiteLLM.  If they differ, every model call from OpenWebUI returns 401.
   `configure.sh generate-secrets` sets them equal automatically if you leave
   `openwebui_api_key` blank.

2. **`flowise_secret_key` — AES encryption key danger**: Flowise encrypts all stored
   credentials (Qdrant keys, API keys, etc.) using this value.  If the secret is lost,
   rotated, or absent at container start, Flowise generates a new random key on boot and
   every existing credential decryption fails with `Error: Unauthorized`.  Never rotate
   this unless you immediately re-create all Flowise credentials.

**§4.4 Secret Rotation Procedures**

Table: Secret | Rotation Command | Services to Restart After | Additional Steps Required

Standard rotation template:
```bash
podman secret rm <secret-name>
printf '%s' '<new-value>' | podman secret create <secret-name> -
systemctl --user restart <service>.service
# Verify:
curl -sf http://localhost:<port>/<health-path>
```

For `flowise_secret_key` specifically, document the full re-seed procedure:
1. Rotate the secret and restart Flowise
2. Log in via `POST /api/v1/auth/login`
3. Delete all existing credentials via `DELETE /api/v1/credentials/<id>`
4. Re-create each credential via `POST /api/v1/credentials`
5. Verify with a live prediction call against a chatflow that uses the credential

**§4.5 Reprovisioning after Disaster Recovery**

When to use: host migration, complete secret store loss, fresh OS install.

```bash
# Interactive re-provisioning of all secrets:
bash scripts/configure.sh generate-secrets
```

Note: `openwebui_api_key` must equal `litellm_master_key`; leave it blank when prompted
and the script derives it automatically.

---

### §5 — Port and Auth Reference

**§5.1 All Services — Port and Auth Table**

Full table columns: Service | Host Port | Bind | Protocol | Auth Method | Token Retrieval Command

For each authenticated service, include the exact, copy-paste extraction command
using Pattern A (inline `--showsecret`).  Example rows:

```
LiteLLM  | 9000 | 127.0.0.1 | HTTP | Bearer token |
  podman secret inspect litellm_master_key --showsecret --format '{{.SecretData}}'

Qdrant   | 6333 | 127.0.0.1 | HTTP | api-key header |
  podman secret inspect qdrant_api_key --showsecret --format '{{.SecretData}}'

knowledge-index | 8100 | 0.0.0.0 | HTTP | Bearer token |
  podman secret inspect knowledge_index_api_key --showsecret --format '{{.SecretData}}'
```

For services accessed via Traefik (OpenWebUI, Flowise, Grafana, Authentik):
note that authentication goes through Authentik forwardAuth on port 443.

**§5.2 Internal Container DNS Aliases** — Source: `dns_alias` from config.json

Table: Service | Container Name | DNS Alias | Internal Base URL

**§5.3 External Exposure Map**

Two lists:
- LAN-accessible (bind = 0.0.0.0): Traefik :80/:443, knowledge-index :8100
- Localhost-only (bind = 127.0.0.1): all others

For LAN-accessible services: note auth requirement and recommended firewall position.

---

### §6 — Installation Runbook (condensed, standalone)

Source material: `docs/getting-started.md` — condense to a single narrative with
all commands copy-paste executable.  Do not cross-reference; inline everything.

Required steps in order:

1. **Prerequisites** — OS, Podman version, git, jq, python3
2. **Clone and prepare** — `git clone` + `cd`
3. **Install dependencies** — `bash scripts/install.sh`
4. **Validate environment** — `bash scripts/validate-system.sh`
5. **Generate TLS certificates** — `bash scripts/generate-tls.sh`; browser trust note
6. **Review config.json** — key fields to verify: `node_profile`, `ai_stack_dir`, `models[]`
7. **Provision secrets** — `bash scripts/configure.sh generate-secrets`

   In this step: write out the full secret list (from §4.2 matrix) with purpose and type,
   then the Podman create pattern for manual provisioning if needed:
   ```bash
   printf '%s' '<value>' | podman secret create <secret-name> -
   ```
   Note the `openwebui_api_key = litellm_master_key` invariant.

8. **Generate quadlets** — `bash scripts/configure.sh generate-quadlets`
9. **Deploy** — `bash scripts/deploy.sh`
10. **Start services** — `bash scripts/start.sh`
11. **Pull and register models** — `podman exec ollama ollama pull llama3.1:8b` then
    `bash scripts/pull-models.sh`
12. **Verify** — `bash scripts/status.sh -v` then `bats testing/layer0_preflight.bats`

---

### §7 — Worker Node Runbook (condensed, standalone)

Source material: `docs/operator-faq.md` sections on node registration through node recovery.
Condense to sequential steps; do not cross-reference.

Required sections:

**§7.1 Generate a Join Token (controller)**
```bash
bash scripts/configure.sh generate-join-token \
  --node-id <id> --profile <knowledge-worker|inference-worker> \
  --display-name "<display name>"
# Token is shown once — copy it before closing the terminal.
```

**§7.2 Bootstrap the Worker**
```bash
# On the worker machine, from the project root:
bash scripts/bootstrap.sh \
  --controller 'http://<controller-host>:8100' \
  --token '<token>' \
  --node-id '<id>'
```

**§7.3 Verify Registration**
```bash
bash scripts/node.sh status                                     # on worker
bash scripts/node.sh list --controller 'http://localhost:8100'  # on controller
# Node shows 'online' after two consecutive heartbeats (~70s apart)
```

**§7.4 Heartbeat Timer**

Linux (systemd):
```bash
systemctl --user status ai-stack-heartbeat.timer
systemctl --user enable --now ai-stack-heartbeat.timer
```

macOS (launchd):
```bash
launchctl list | grep ai-stack
launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.ai-stack.heartbeat.plist
```

If the timer is missing entirely, see: Troubleshooting §11.8.

**§7.5 Harden the Worker (Ollama port restriction)**
```bash
# Generates OS-appropriate firewall rules restricting port 11434 to controller IP only:
bash scripts/node.sh harden-worker --alias <worker-alias>
# Copy the printed commands and run them on the worker node.
```

**§7.6 Unjoin / Rejoin**
```bash
# Unjoin from worker:
bash scripts/node.sh unjoin
# Rejoin with a new token from the controller:
bash scripts/node.sh join \
  --controller 'http://<controller-host>:8100' \
  --token '<new-token>' --node-id '<id>'
```

**§7.7 Node State Machine**

Table: State | Meaning | Recovery Action

- `online`: Heartbeating normally
- `caution`: Last heartbeat > 90s ago — send 2 beats within 70s
- `failed`: Last heartbeat > 150s ago — send 2 beats within 70s
- `offline`: Absent > 24h — requires new join token

---

### §8 — Day-to-Day Operations

**§8.1 Routine Operations Calendar**

Table: Cadence | Task | Command

| Cadence | Task | Command |
|---|---|---|
| Daily | Service health | `bash scripts/status.sh` |
| Daily | Node heartbeat check | `bash scripts/node.sh list --controller http://localhost:8100` |
| Weekly | Full test run | `make test-all` |
| Weekly | Security audit | `bash scripts/configure.sh security-audit` |
| Monthly | TLS expiry check | `bash scripts/configure.sh security-audit \| grep TLS` |
| Monthly | Backup verify | `bash scripts/backup.sh --verify` |
| Monthly | Review base image tags | check for upstream releases; bump in config.json |

**§8.2 Start / Stop / Restart Reference**

```bash
bash scripts/start.sh          # all services, dependency order
bash scripts/stop.sh           # all services
systemctl --user restart <svc>.service          # single service
bash scripts/status.sh -v      # verbose — health checks included
make wait-services             # wait for readiness post-restart (use after test-all)
```

**§8.3 Add a Model**

Ollama (local):
```bash
podman exec ollama ollama pull <model-name>
# Add entry to models[] in configs/config.json, then:
bash scripts/configure.sh generate-litellm-config
bash scripts/pull-models.sh
```

Cloud provider (OpenAI, Anthropic, Groq, Mistral):
```bash
printf '%s' '<api-key>' | podman secret create <provider>_api_key -
# Add entry to models[] in configs/config.json with "api_key_secret":.., then:
bash scripts/configure.sh generate-litellm-config && bash scripts/pull-models.sh
```

**§8.4 Ingest Documents**

```bash
# 1. Build the .ai-library package:
bash scripts/configure.sh build-library \
  --source /path/to/docs --name my-library --version 1.0.0

# 2. Scan into the knowledge index (key retrieved inline — never hardcoded):
curl -s -X POST http://localhost:8100/v1/scan \
  -H "Authorization: Bearer $(podman secret inspect knowledge_index_api_key \
    --showsecret --format '{{.SecretData}}')" \
  -H "Content-Type: application/json" \
  -d '{"path": "/libraries/my-library"}'

# 3. Verify:
curl -s http://localhost:8100/v1/catalog \
  -H "Authorization: Bearer $(podman secret inspect knowledge_index_api_key \
    --showsecret --format '{{.SecretData}}')" | python3 -m json.tool
```

**§8.5 Security Audit**

```bash
bash scripts/configure.sh security-audit
# Exit codes: 0=clean  1=warnings only  2=critical findings
bash scripts/configure.sh security-audit --json   # machine-readable
bash scripts/configure.sh security-audit --skip-network   # offline/CI
```

Checks: port exposure (A), auth enforcement (B), TLS validity (C),
secret hygiene (D), worker Ollama hardening (E).

**§8.6 Backup and Restore**

```bash
bash scripts/backup.sh                         # default retention (7 sets)
BACKUP_KEEP=14 bash scripts/backup.sh          # keep 14 sets
bash scripts/backup.sh --dry-run               # show what would be done
bash scripts/backup.sh --restore 20260406T120000
```

Backs up: PostgreSQL (pg_dump), Qdrant (snapshot), libraries dir, configs.

**§8.7 Sleep Inhibitor**

Enable per worker (edit locally — do not push to git):
```bash
# Linux:
sed -i 's/"sleep_inhibit": false/"sleep_inhibit": true/' configs/config.json
# macOS:
sed -i '' 's/"sleep_inhibit": false/"sleep_inhibit": true/' configs/config.json
bash scripts/inhibit.sh start
bash scripts/inhibit.sh status
```

Linux uses `systemd-inhibit --what=idle`; macOS uses `caffeinate -i -s`.

---

### §9 — Component Upgrade Runbook

**§9.1 Standard Container Image Upgrade**

```bash
# 1. Update image tag in configs/config.json
# 2. Regenerate quadlets and reload:
bash scripts/configure.sh generate-quadlets
systemctl --user daemon-reload
# 3. Pull new image:
podman pull <new-image:tag>
# 4. Restart service:
systemctl --user restart <service>.service
# 5. Verify health:
bash scripts/status.sh | grep <service>
```

**§9.2 knowledge-index Custom Image**

Both flags are required — omitting either silently deploys stale or wrong code:

```bash
podman build --no-cache -t localhost/knowledge-index:0.1.0 services/knowledge-index/
systemctl --user daemon-reload
systemctl --user restart knowledge-index.service
# Verify new code is running:
podman inspect knowledge-index --format '{{.Image}}'
```

Why `--no-cache`: the `COPY app.py node_registry.py` layer is keyed on the Containerfile,
not the source files.  Without `--no-cache`, changed Python files are silently skipped.

Why `:0.1.0` not `:latest`: the quadlet is pinned to this tag.  Building `:latest` creates
a separate image that `systemctl restart` ignores.

**§9.3 LiteLLM Upgrade**

After any image change that resets the LiteLLM database, model routes are gone.
Re-register:

```bash
bash scripts/pull-models.sh
# Verify:
curl -s -H "Authorization: Bearer $(podman secret inspect litellm_master_key \
  --showsecret --format '{{.SecretData}}')" \
  http://localhost:9000/v1/models | python3 -m json.tool
```

**§9.4 Flowise Upgrade**

Before upgrading, confirm `FLOWISE_SECRETKEY_OVERWRITE` is set and will persist:
```bash
podman exec flowise env | grep FLOWISE_SECRETKEY
# Must return a value — if blank, set it before upgrading or all stored
# credentials will fail decryption after restart.
```

After upgrade, verify stored credentials with a live prediction call.

**§9.5 PostgreSQL Upgrade**

Always back up first:
```bash
bash scripts/backup.sh
# Verify the dump is readable:
podman exec postgres pg_dump -U aistack aistack | wc -l
```

Then follow standard image upgrade (§9.1).  After restart, verify schema migration:
```bash
podman exec postgres psql -U aistack -c '\dt' aistack | head -20
```

---

### §10 — Observability Guide

**§10.1 Status at a Glance**

| Tool | When to Use | Command |
|---|---|---|
| `status.sh` | First check — service states + health | `bash scripts/status.sh` |
| `status.sh -v` | Verbose — includes health check output | `bash scripts/status.sh -v` |
| `diagnose.sh` | Service won't start — dependency chain | `bash scripts/diagnose.sh --profile full` |
| `security-audit` | Periodic hardening check | `bash scripts/configure.sh security-audit` |
| `make test-all` | Full regression gate | `make test-all` |

**§10.2 Grafana Dashboards**

Access: `https://localhost` → Authentik login → Grafana

List provisioned dashboards from Phase 1 collection (`configs/grafana/provisioning/`).
For each dashboard: name and primary signal it shows.

URL pattern: `https://localhost/grafana/d/<uid>/<slug>`

**§10.3 Loki Log Queries**

Access: Grafana → Explore → select Loki datasource

Label structure (all containers ship via Promtail):
```logql
{container_name="<service-name>"}               # single service
{job="containers"} |= "ERROR"                   # all services, errors only
{container_name="litellm"} |= "Exception"       # LiteLLM exceptions
{container_name="knowledge-index"} |= "401"     # auth failures
```

Retention: **168 hours (7 days)**. For longer retention, update `retention_period`
in `configs/loki/local-config.yaml` and restart loki.

**§10.4 Prometheus Metrics**

Access: `http://localhost:9091` (localhost only; via Grafana for team access)

Key metrics:
- `up` — scrape target health (1=up, 0=down)
- `container_cpu_usage_seconds_total` — per-container CPU
- `container_memory_working_set_bytes` — per-container memory

Check scrape target health:
```bash
curl -s http://localhost:9091/api/v1/targets | \
  python3 -c "import sys,json; \
  [print(t['labels']['job'], t['health']) \
  for t in json.load(sys.stdin)['data']['activeTargets']]"
```

**§10.5 make test-all as Operational Health Gate**

`make test-all` runs 60 BATS infrastructure tests + 93 pytest model/security tests.
A clean run indicates the full stack is wired correctly end-to-end.

**Known pre-existing failures (not regressions — expected on this cluster):**

| Test | Reason | Acceptable? |
|---|---|---|
| T-019: Authentik via Traefik | Traefik TLS route not wired for HTTP | Yes |
| T-023: TLS SAN on :443 | Self-signed cert omits `localhost` SAN | Yes |
| T-047: Promtail→Loki e2e | Scrape path config for test log file | Yes |

Any failure BEYOND these three in a clean run of `make test-all` should be
investigated before treating the cluster as production-ready.

Document the actual last test run summary at capture time:
`N passed, M failed (list), K skipped (list)`

---

### §11 — Troubleshooting Reference

Source material: `docs/operator-faq.md` — condense each failure mode to the standard
pattern below.  Do not cross-reference; inline all diagnosis and fix commands.

**Standard pattern for each entry:**

```
### <Symptom headline>

**Symptoms:** <what the operator observes>

**Diagnose:**
```bash
<copy-paste command>
```

**Fix:**
```bash
<copy-paste command>
```

**Note:** <anything not obvious>
```

**Required entries (minimum):**

1. Service shows `failed` or `inactive`
2. Model returns 404 from LiteLLM
3. LiteLLM returns 401 on all requests
4. OpenWebUI shows no models / "Failed to fetch models"
5. Authentik unreachable via Traefik (502/404)
6. knowledge-index returns 401 on `/v1/catalog`
7. Node shows `caution` or `failed`
8. Node shows `offline` — cannot send heartbeats
9. Heartbeat timer not running (Linux)
10. Heartbeat timer not running (macOS)
11. knowledge-index stopped after running the test suite
12. Flowise credentials fail after restart (`flowise_secret_key` rotation)
13. TLS certificate errors in browser
14. Duplicate model entries in LiteLLM

For each `curl` or service call in this section, use inline Pattern A secret
extraction.  Verify every command is executable as written before including it.

---

### §12 — Index

Alphabetical index of all named entities in the document.  Format:

```
<term>                               →  §<section>.<subsection> [<page hint>]
```

Include at minimum:

- All 15 service names (traefik, postgres, qdrant, knowledge-index, authentik,
  litellm, vllm, ollama, flowise, openwebui, prometheus, grafana, loki, promtail, minio)
- All Podman secret names (from §4.2)
- All script names (configure.sh, deploy.sh, start.sh, stop.sh, status.sh,
  diagnose.sh, backup.sh, pull-models.sh, bootstrap.sh, node.sh, heartbeat.sh,
  generate-tls.sh, inhibit.sh)
- All `make` targets (make test-all, make test-bats, make test-pytest, make wait-services)
- Key troubleshooting terms: 401, 404, 502, cascade stop, credential encryption,
  AES key, forwardAuth, heartbeat, join token, caution, failed, offline, cold-boot

---

## Phase 3 — Output and Verification

```bash
mkdir -p output
OUTPUT_FILE="output/$(hostname -s)-playbook.md"
# Write document to $OUTPUT_FILE

# Verify:
wc -l "$OUTPUT_FILE"          # expect 800–1500 lines for a 3-node cluster
grep -c "^##" "$OUTPUT_FILE"  # expect ≥ 15 section headings
grep -i "secret\b" "$OUTPUT_FILE" | grep -v "#\|extract\|rotation\|pattern\|podman" | head -5
# ^ should return nothing — no loose plaintext secret discussions outside §4
```

Output file is gitignored (`output/` in `.gitignore`).  
**Do NOT `git add output/`.**

---

## Phase 4 — Quality Checklist

Verify each item before declaring the document complete:

- [ ] No secret values appear anywhere in the document (only extraction commands)
- [ ] Every `curl` or auth CLI example uses inline `$()` Pattern A extraction
- [ ] §2 values match live `config.json` and `configs/nodes/*.json` — not approximated
- [ ] All 12 sections present and non-empty
- [ ] Table of Contents anchor links resolve to actual headings
- [ ] §12 Index covers all 15 service names and all secret names from §4.2
- [ ] Freshness Contract block present in document header
- [ ] Shell history advisory note present in §4.1
- [ ] Known pre-existing test failures documented in §10.5 match last actual run
- [ ] `wc -l` output is ≥ 800 lines (if shorter, a section is missing content)

---

## VS Code Skill Invocation

This file is formatted as a VS Code Copilot SKILL.md.  To make it auto-discoverable
as a slash command, place a copy (or symlink) at:

```
.github/skills/generate-playbook/SKILL.md
```

The `name` field (`generate-playbook`) must match the folder name.
Invoke with `/generate-playbook` in VS Code Copilot chat, or the agent will load it
automatically when a request matches the description keywords.
