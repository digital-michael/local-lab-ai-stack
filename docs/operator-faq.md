# Operator FAQ and How-To Guides

**Last Updated:** 2026-04-05

Practical guidance for operating the stack day-to-day. Organized as How-To recipes and an FAQ for common failure modes.

---

## How-To Guides

### Add a New Ollama Model

1. Pull the model into Ollama's local store:
   ```bash
   podman exec ollama ollama pull <model-name>
   # e.g.  podman exec ollama ollama pull mistral:7b-instruct-q4_K_M
   ```

2. Add an entry to `models[]` in `configs/config.json`:
   ```json
   { "name": "mistral:7b-instruct-q4_K_M", "backend": "ollama", "device": "cpu" }
   ```

3. Regenerate the LiteLLM routing table and register the new route:
   ```bash
   bash scripts/configure.sh generate-litellm-config
   bash scripts/pull-models.sh
   ```

4. Verify the model appears in LiteLLM:
   ```bash
   curl -s -H "Authorization: Bearer $(podman secret inspect litellm_master_key --format '{{.CreatedAt}}')" \
     http://localhost:9000/v1/models
   ```

---

### Add a Hosted API Provider (OpenAI, Anthropic, etc.)

1. Store the API key as a Podman secret:
   ```bash
   echo -n "sk-..." | podman secret create openai_api_key -
   ```

2. Add the model entry to `models[]` in `configs/config.json`:
   ```json
   { "name": "gpt-4o", "backend": "openai", "api_key_secret": "openai_api_key" }
   ```

3. Regenerate LiteLLM config and register:
   ```bash
   bash scripts/configure.sh generate-litellm-config
   bash scripts/pull-models.sh
   ```

> Supported backends: `openai`, `anthropic`, `groq`, `mistral`. Each requires its own `api_key_secret` entry pointing to the Podman secret name.

---

### Register a Worker Node

> Changed 2026-09-30 (D-045): the join-token / heartbeat registry lived in the Python Knowledge Index and was removed with it. Workers are registered statically.

1. Enroll the worker in the tailnet (headscale) so the controller can reach it.
2. On the worker, run `bash scripts/register-node.sh` and review the printed block.
3. On the controller, save it as `configs/nodes/<alias>.json` (static config model, D-020/D-026).
4. Register its models with LiteLLM: `bash scripts/pull-models.sh`.
5. Confirm it is on the tailnet: `bash scripts/node.sh list --headscale-url <url> --headscale-key <key>`.

---

### Remove a Worker Node

Remove its `configs/nodes/<alias>.json`, delete its model routes from LiteLLM (see "pull-models.sh registers duplicate model entries" below for listing and deleting routes), and expire or remove the node in headscale.

---

### Enable GPU Inference (vLLM)

1. Confirm NVIDIA GPU is present and CDI is configured:
   ```bash
   nvidia-smi
   podman run --rm --device nvidia.com/gpu=all ubuntu nvidia-smi
   ```

   If CDI is not configured:
   ```bash
   sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
   ```

2. Run hardware detection to get a recommended model and configuration:
   ```bash
   bash scripts/configure.sh detect-hardware
   ```

3. Download the recommended model weights (example — adjust path to your model):
   ```bash
   # Using Hugging Face CLI or manual download
   mkdir -p ~/ai-stack/models/qwen2.5-1.5b
   # place model files under ~/ai-stack/models/qwen2.5-1.5b/
   ```

4. The vLLM service entry in `configs/config.json` already includes startup flags; verify `--model`, `--served-model-name`, and `--gpu-memory-utilization` match your hardware.

5. Start vLLM and verify:
   ```bash
   systemctl --user start vllm.service
   nvidia-smi  # confirm vLLM process appears
   ```

---

### Ingest Documents into the Knowledge Base

Not available: ingestion (`POST /v1/scan`, `configure.sh sync-libraries`) ran in the Python Knowledge Index, removed 2026-09-30 (D-045). `configure.sh build-library` still packages `.ai-library` bundles (format D-013) for the Go Knowledge Index (ledger epic 2b9b1647).

---

### Back Up All Stack Data

```bash
bash scripts/backup.sh
```

Backs up PostgreSQL (pg_dump), Qdrant (snapshot), libraries, and configs. Keeps the 7 most recent sets by default.

```bash
# Keep 14 sets:
BACKUP_KEEP=14 bash scripts/backup.sh

# Dry run (show what would be done):
bash scripts/backup.sh --dry-run

# Restore from a specific backup:
bash scripts/backup.sh --restore 20260324T120000
```

---

### Enable Sleep Inhibitor on Worker Nodes

Prevents a worker node from sleeping due to inactivity while the AI stack is running.

1. Enable in local `configs/config.json` (edit on the worker node — do not push to git):
   ```bash
   # Linux:
   sed -i 's/"sleep_inhibit": false/"sleep_inhibit": true/' configs/config.json
   # macOS:
   sed -i '' 's/"sleep_inhibit": false/"sleep_inhibit": true/' configs/config.json
   ```

2. Start the inhibitor:
   ```bash
   bash scripts/inhibit.sh start
   bash scripts/inhibit.sh status
   ```

3. To verify it will start automatically on next `bash scripts/start.sh`, confirm `Enabled: yes` in `status` output.

> **Note:** `sleep_inhibit` defaults to `false` in the repo. Each worker node enables it locally. The controller profile is always skipped — controllers manage their own power policy.
>
> No sudo required. macOS uses `caffeinate -i -s`; Linux uses `systemd-inhibit --what=idle`.

---

### Run the Security Audit

```bash
bash scripts/configure.sh security-audit
```

Runs five checks:

| Check | What it tests |
|---|---|
| A | Port exposure — services bound to `0.0.0.0` vs `127.0.0.1` |
| B | Auth enforcement — unauthenticated probes of LiteLLM, Qdrant, Knowledge Index |
| C | TLS certificate validity and expiry |
| D | Secret hygiene — no plaintext secrets in `configs/config.json` |
| E | Worker hardening — Ollama on inference-worker nodes reachable without auth |

A Check E CRITICAL finding includes the exact `harden-worker` command to remediate:

```
CRITICAL  WORKER-OLLAMA-SOL  Ollama on SOL (...) is unauthenticated — run: bash scripts/node.sh harden-worker --alias inference-worker-2
```

See [Hardening Ollama port on inference worker nodes](#hardening-ollama-port-on-inference-worker-nodes).

For machine-readable output or offline/CI use:

```bash
bash scripts/configure.sh security-audit --json
bash scripts/configure.sh security-audit --skip-network
```

Exit codes: `0` = clean, `1` = warnings only, `2` = critical findings.

---

## FAQ — Common Failure Modes

### A service shows `failed` or `inactive` in `status.sh`

```bash
# Check the systemd unit log:
journalctl --user -u <service-name>.service -n 50

# Or use the built-in diagnostics:
bash scripts/diagnose.sh --profile full
```

Common causes:
- **Image not pulled yet** — `podman pull <image>` manually, then `systemctl --user restart <service>.service`
- **Secret not provisioned** — run `configure.sh generate-secrets` and restart the affected service
- **Config file missing** — check that `~/ai-stack/configs/` was populated by `deploy.sh`
- **Port conflict** — check `ss -tlnp | grep <port>`

---

### OpenWebUI shows "Failed to fetch models" or a blank model list

This is almost always a misconfiguration between OpenWebUI and LiteLLM. Check the following in order:

1. **`openwebui_api_key` must equal `litellm_master_key`** — if they differ, every model call returns 401:
   ```bash
   bash scripts/diagnose.sh --profile full --fix
   ```

2. **`webui.db` cached a stale URL** — OpenWebUI persists its connection config to SQLite at first boot; env-var changes have no effect until the DB is patched. Running `diagnose.sh --fix` corrects this automatically.

3. **LiteLLM is not running** — `bash scripts/status.sh | grep litellm`

---

### A model call returns 404 from LiteLLM

The model is not registered. Run:

```bash
bash scripts/pull-models.sh
```

If the issue persists, check that the model name in `configs/models.json` matches exactly what Ollama or vLLM serves:

```bash
# Ollama:
podman exec ollama ollama list
# vLLM:
curl http://localhost:8000/v1/models
```

---

### LiteLLM returns 401 on all requests

The bearer token in the request does not match `litellm_master_key`. Retrieve the key:

```bash
podman secret inspect litellm_master_key --show-secret-values 2>/dev/null || \
  podman run --rm --secret litellm_master_key alpine sh -c 'cat /run/secrets/litellm_master_key'
```

---

### TLS certificate errors in the browser

```bash
# Check expiry:
bash scripts/configure.sh security-audit | grep TLS

# Regenerate if expired:
bash scripts/generate-tls.sh
systemctl --user restart traefik.service
```

Re-trust the new CA in your browser after regeneration.

---

### Authentik login page is unreachable (Traefik returns 502 or 404)

```bash
# Check Traefik is running:
bash scripts/status.sh | grep traefik

# Check Authentik:
bash scripts/status.sh | grep authentik

# View Traefik routing decisions:
curl http://localhost:8080/api/http/routers
```

Common causes:
- Authentik container is still starting (first boot takes ~60 seconds)
- Traefik dynamic config is missing or malformed — check `~/ai-stack/configs/traefik/dynamic/`

---

### `pull-models.sh` registers duplicate model entries

LiteLLM's `POST /model/new` always adds; it does not update. Running `pull-models.sh` deletes the old entry before creating the new one. If you see duplicates, they were left by a previous failed run:

```bash
# List all registered model IDs:
curl -s -H "Authorization: Bearer <key>" http://localhost:9000/model/info | \
  python3 -c "import sys,json; [print(m['model_info']['id'], m['model_name']) for m in json.load(sys.stdin)['data']]"

# Delete a stale entry by UUID:
curl -X POST -H "Authorization: Bearer <key>" \
  -H "Content-Type: application/json" \
  -d '{"id": "<uuid>"}' \
  http://localhost:9000/model/delete
```

Then re-run `pull-models.sh`.

---

### A remote inference node's models are not showing in LiteLLM

1. Confirm the node file exists and has `"status": "active"`:
   ```bash
   cat configs/nodes/inference-worker-N.json
   ```

2. Confirm the node is reachable from the controller:
   ```bash
   curl http://<node-address>:11434/api/tags
   ```

3. Regenerate LiteLLM config and re-register:
   ```bash
   bash scripts/configure.sh generate-litellm-config
   bash scripts/pull-models.sh
   ```

---

### Hardening Ollama port on inference worker nodes

The controller's Ollama binds to `127.0.0.1:11434` — it is not LAN-exposed because
LiteLLM reaches it via the internal container network.

Remote inference-worker nodes run Ollama natively on `0.0.0.0:11434`. Use
`harden-worker` to generate OS-appropriate firewall rules that restrict port 11434
to the controller IP only:

```bash
# Run on the controller — prints instructions for the named worker
bash scripts/node.sh harden-worker --alias <alias>

# Examples:
bash scripts/node.sh harden-worker --alias inference-worker-2   # Linux worker
bash scripts/node.sh harden-worker --alias inference-worker-1   # macOS worker
```

The command auto-resolves the controller IP from `configs/nodes/`. If DNS is
unavailable, set `address_fallback` on the controller node or pass
`--controller-ip <ip>` explicitly.

Copy the printed commands and run them **on the worker node**. Each OS path
includes persistence steps (nftables/firewalld for Linux; pf anchor for macOS).

After applying, verify from the controller:

```bash
bash scripts/configure.sh security-audit
# WORKER-OLLAMA-<NODE-ID> should change from CRITICAL → OK
```

> **Note:** If `configure.sh security-audit` reports a CRITICAL finding for a worker,
> the message includes the exact `harden-worker` command to run.

