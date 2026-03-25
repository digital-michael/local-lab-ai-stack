# Operator FAQ and How-To Guides

**Last Updated:** 2026-03-25

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

### Register a Remote Inference Node

1. Run hardware detection and Ollama setup on the remote machine (Linux, Podman):
   ```bash
   # On the remote node:
   bash scripts/podman/setup-worker.sh
   ```

   For a macOS bare-metal node (Apple Silicon):
   ```bash
   # On macOS:
   bash scripts/bare_metal/setup-macos.sh
   ```

2. On the remote node, run the registration helper to generate the config block:
   ```bash
   bash scripts/register-node.sh
   ```

3. Copy the printed JSON block into `configs/nodes/` on the controller as a new file (e.g. `configs/nodes/inference-worker-3.json`).

4. On the controller, regenerate the LiteLLM config and register models:
   ```bash
   bash scripts/configure.sh generate-litellm-config
   bash scripts/pull-models.sh
   ```

5. Verify the remote node's models appear in LiteLLM:
   ```bash
   curl -s http://localhost:9000/v1/models
   ```

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

1. Package a directory of documents into a `.ai-library` bundle:
   ```bash
   bash scripts/configure.sh build-library \
     --source /path/to/my-docs \
     --name my-library \
     --version 1.0.0 \
     --author "Your Name"
   ```
   Output is written to `~/ai-stack/libraries/my-library/`.

2. Trigger ingestion via the Knowledge Index Service:
   ```bash
   curl -s -X POST http://localhost:8100/v1/scan \
     -H "Authorization: Bearer $(cat /run/secrets/knowledge_index_api_key 2>/dev/null)" \
     -H "Content-Type: application/json" \
     -d '{"path": "/path/to/ai-stack/libraries/my-library"}'
   ```

3. Confirm the library appears in the catalog:
   ```bash
   curl -s http://localhost:8100/v1/catalog \
     -H "Authorization: Bearer <your-api-key>"
   ```

> Supported file types: `.txt`, `.md`, `.pdf` (plain-text extraction). Documents are chunked, embedded (via Ollama), and stored in Qdrant.

---

### Push a Library to the Controller (from a worker node)

```bash
# On the worker node:
bash scripts/configure.sh sync-libraries
```

Reports per-library status: `new / updated / unchanged / failed`.

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

### Run the Security Audit

```bash
bash scripts/configure.sh security-audit
```

Checks port exposure, API key enforcement, TLS certificate expiry, secret hygiene, and worker node hardening. For machine-readable output:

```bash
bash scripts/configure.sh security-audit --json
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

### Knowledge Index returns 401 on `/v1/catalog`

The endpoint requires a valid API key:

```bash
curl -H "Authorization: Bearer $(podman run --rm --secret knowledge_index_api_key \
  alpine sh -c 'cat /run/secrets/knowledge_index_api_key')" \
  http://localhost:8100/v1/catalog
```

If the key is lost, re-provision it:
```bash
echo -n "<new-key>" | podman secret rm knowledge_index_api_key ; \
  echo -n "<new-key>" | podman secret create knowledge_index_api_key -
systemctl --user restart knowledge-index.service
```
