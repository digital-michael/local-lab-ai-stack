# Operator FAQ and How-To Guides

**Last Updated:** 2026-04-04

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

Worker registration uses a one-time join token. The token is generated on the controller, passed to the worker, and consumed once during the join handshake. After joining, the node authenticates all subsequent requests (including heartbeats) with a per-node API key issued by the controller.

**Step 1 — Generate a join token (on the controller)**

```bash
bash scripts/configure.sh generate-join-token \
  --node-id <id> \
  --profile knowledge-worker \
  --display-name "TC25 Mac Studio"
```

Options:
- `--node-id` — unique identifier for the node (default: random UUID)
- `--profile` — `knowledge-worker` (with KI + Qdrant) or `inference-worker` (Ollama only)
- `--address` — the worker's KI base URL if known (e.g. `http://192.168.1.50:8100`); can be set during join if omitted

The command prints the token and the exact `node.sh join` command to run on the worker. **The token is shown once — copy it before closing the terminal.**

**Step 2 — Bootstrap the worker node**

On the worker, from the project root:

```bash
bash scripts/bootstrap.sh \
  --controller 'http://<controller-host>:8100' \
  --token '<token>' \
  --node-id '<id>'
```

`bootstrap.sh` runs `node.sh join`, saves state to `~/.config/ai-stack/`, and installs the heartbeat timer (systemd on Linux, launchd on macOS).

Or, if the worker is already set up and only needs to join:

```bash
bash scripts/node.sh join \
  --controller 'http://<controller-host>:8100' \
  --token '<token>' \
  --node-id '<id>'
```

**Step 3 — Verify**

On the worker:
```bash
bash scripts/node.sh status
```

On the controller (lists all nodes):
```bash
bash scripts/node.sh list --controller 'http://localhost:8100'
```

The node should show `online` after two successful heartbeats (within ~70 seconds of each other).

---

### Remove (Unjoin) a Worker Node

On the worker (uses saved state from `~/.config/ai-stack/`):

```bash
bash scripts/node.sh unjoin
```

Or from the controller for a node that can no longer be reached:

```bash
bash scripts/node.sh unjoin \
  --controller 'http://localhost:8100' \
  --node-id '<id>'
```

This sets the node to `unregistered` and removes its models from LiteLLM routing. The node can rejoin later with a new `generate-join-token` call.

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

### Restricting Ollama port on inference worker nodes

The controller's Ollama binds to `127.0.0.1:11434` (set in `configs/config.json`) — it is
not exposed on the LAN because LiteLLM reaches it via the internal container network.

Remote **bare-metal** worker nodes run Ollama natively. By default, Ollama listens on
`0.0.0.0:11434`. To restrict it to the controller IP only, add a firewall rule on each
worker host:

**Linux (ufw):**
```bash
sudo ufw deny 11434              # block all by default
sudo ufw allow from <controller-ip> to any port 11434
sudo ufw reload
```

**Linux (iptables):**
```bash
iptables -A INPUT -p tcp --dport 11434 ! -s <controller-ip> -j DROP
```

**macOS (pf) — add to `/etc/pf.conf`:**
```
block in on en0 proto tcp from any to any port 11434
pass  in on en0 proto tcp from <controller-ip> to any port 11434
```
Then `sudo pfctl -f /etc/pf.conf && sudo pfctl -e`.

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

---

### Worker node registered but never sends heartbeats

`node.sh join` only writes the state files (`controller_url`, `node_id`, `api_key`) to
`~/.config/ai-stack/` on the worker. It does **not** install the systemd timer units.
The heartbeat timer must be installed separately by running `bootstrap.sh` locally on the
worker — if that step was skipped, the node will appear in `node.sh list` (the DB entry
exists) but will immediately fall to `caution` → `failed` → `offline` with no errors, since
there is simply no timer present to fire.

**Symptoms:**
- `systemctl --user status ai-stack-heartbeat.timer` → `Unit ... could not be found`
- `~/.config/ai-stack/` exists but contains only files created manually (no state files, or
  state files were written manually without a matching bootstrap run)
- Node shows in `node.sh list` but transitions to `failed` within 3 minutes of joining

**Fix — install the timer on the worker:**
```bash
cp ~/ai-stack/configs/quadlets/ai-stack-heartbeat.service ~/.config/systemd/user/
cp ~/ai-stack/configs/quadlets/ai-stack-heartbeat.timer   ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ai-stack-heartbeat.timer
```

If the repo is not at `~/ai-stack/` on this machine, the `ExecStart` path in the installed
service unit must be corrected before reloading:
```bash
sed -i "s|%h/ai-stack/scripts/heartbeat.sh|$(pwd)/scripts/heartbeat.sh|" \
  ~/.config/systemd/user/ai-stack-heartbeat.service
```

---

### A worker node shows `failed` or `caution` instead of `online`

The node missed consecutive heartbeats. The state machine is:

| State | Meaning |
|---|---|
| `online` | Heartbeating normally |
| `caution` | Last heartbeat > 90s ago |
| `failed` | Last heartbeat > 150s ago |
| `offline` | Last heartbeat > 24h ago (requires a new token to rejoin) |

Recovery requires **two consecutive heartbeats within 70 seconds** of each other. One manual heartbeat is not enough — the second is what triggers the transition back to `online`.

On the worker:
```bash
# Send first beat
bash scripts/heartbeat.sh

# Send second beat within 70s
bash scripts/heartbeat.sh

# Confirm
bash scripts/node.sh status
```

If the heartbeat timer is not running, check it and restart:

```bash
# Linux:
systemctl --user status ai-stack-heartbeat.timer
systemctl --user start ai-stack-heartbeat.timer

# macOS:
launchctl list | grep ai-stack          # look for com.ai-stack.heartbeat with PID or "-"
tail -20 ~/.config/ai-stack/heartbeat.log
```

---

### Heartbeat timer is not running on macOS

The heartbeat timer is installed as a launchd `LaunchAgent`. Common failure causes:

**1. Broken plist (empty `ProgramArguments`)** — happens if `bootstrap.sh` was run from the wrong directory and `HEARTBEAT_SCRIPT` resolved to an empty path. Check:

```bash
grep -A3 'ProgramArguments' ~/Library/LaunchAgents/com.ai-stack.heartbeat.plist
```

If the array contains only `/bin/bash` with no second `<string>`, rewrite it:

```bash
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.heartbeat.plist"
HEARTBEAT_SCRIPT="$HOME/Projects/active/local-lab-ai-stack/scripts/heartbeat.sh"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.ai-stack.heartbeat</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>${HEARTBEAT_SCRIPT}</string>
    </array>
    <key>StartInterval</key><integer>30</integer>
    <key>RunAtLoad</key><true/>
    <key>StandardOutPath</key><string>${HOME}/.config/ai-stack/heartbeat.log</string>
    <key>StandardErrorPath</key><string>${HOME}/.config/ai-stack/heartbeat.log</string>
</dict>
</plist>
EOF
```

**2. launchd not loaded** — reload with the deprecated-but-domain-agnostic API (works both over SSH and with a GUI session):

```bash
launchctl load -w ~/Library/LaunchAgents/com.ai-stack.heartbeat.plist
launchctl list | grep ai-stack      # PID "-" with exit 0 = loaded, running between intervals
```

**3. Verify beats are landing:**
```bash
tail -20 ~/.config/ai-stack/heartbeat.log
```

If the log shows heartbeats but the node stays `failed`, remember two beats within 70s are required (see above).

---

### Rebuilding the knowledge-index container after code changes

After editing `services/knowledge-index/app.py` or `node_registry.py`, the running container
must be rebuilt and restarted. Two pitfalls:

**1. Build the correct tag** — the quadlet is pinned to `0.1.0`. Building `:latest` creates a
separate image; `systemctl restart` will silently keep running the old `0.1.0` image:

```bash
# Correct:
podman build --no-cache -t localhost/knowledge-index:0.1.0 services/knowledge-index/

# Wrong (container won't pick it up):
podman build -t localhost/knowledge-index:latest services/knowledge-index/
```

**2. Always pass `--no-cache`** — the `COPY app.py node_registry.py` layer is cache-keyed
on the Containerfile, not the source files. Without `--no-cache`, changed Python files are
silently skipped and the old code is deployed.

After building, restart and verify:

```bash
systemctl --user restart knowledge-index
podman exec knowledge-index grep -c "<changed-symbol>" /app/node_registry.py
```

---

### A node shows `offline` and cannot send heartbeats

`offline` is a terminal state — the node has been absent for > 24 hours. Heartbeats are rejected with 403. Re-register with a fresh token:

**On the controller:**
```bash
bash scripts/configure.sh generate-join-token --node-id <id>
```

**On the worker:**
```bash
bash scripts/node.sh join \
  --controller 'http://<controller-host>:8100' \
  --token '<new-token>' \
  --node-id '<id>'
```

The existing `node_id` is reused — no data is lost.
