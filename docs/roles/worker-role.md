# Worker Role

## Purpose

The worker role extends inference capacity. A worker node runs Ollama (and
optionally vLLM) and registers itself with the controller's knowledge-index
heartbeat system. LiteLLM on the controller routes model requests to registered
workers automatically. Workers can be added or removed without changing any
controller configuration beyond the LiteLLM model route list.

Workers are not always-on. They can be idle machines that come online when
inference demand is high, or dedicated GPU machines that stay on continuously.

---

## Dependencies

### Role dependencies (must be deployed first)

| Role | Required by | What fails without it |
| --- | --- | --- |
| Edge role — mesh group | Tailscale agent | Cannot enroll in Headscale; tailnet connectivity unavailable |
| Controller role | All worker function | No LiteLLM endpoint to register with; no knowledge-index heartbeat target; no model routing |

The worker has no independent value without the controller. Its only job is to
extend the controller's inference capacity. Both the edge role (for Headscale)
and the controller role (for LiteLLM and heartbeat) must be reachable before a
worker can register.

### Infrastructure (must exist on the worker host)

| Dependency | Required by | Notes |
| --- | --- | --- |
| Podman 5.0+ (rootless) | `ai-stack-infer-ollama` | Ollama runs as a user container |
| Tailscale enrolled via Headscale | All | Tailnet IP required for controller to reach Ollama |
| GPU + CUDA drivers | `ai-stack-infer-vllm` | Optional; CPU inference via Ollama works without GPU |
| Sufficient storage | `ai-stack-infer-ollama` | Model files; 4–8 GB per model minimum |
| Ollama port 11434 reachable from controller tailnet IP only | `ai-stack-infer-ollama` | Harden via firewall after registration |

### External service dependencies

| Service | Where it runs | Required by |
| --- | --- | --- |
| Headscale | Edge node (`ai-stack-mesh`) | Tailscale enrollment; tailnet IP assignment |
| knowledge-index | Controller (`ai-stack-know-index`) | Heartbeat registration endpoint |
| LiteLLM | Controller (`ai-stack-infer-litellm`) | Model route target; config updated after worker joins |

---

## Target Hardware Profile

| Property | Minimum | Recommended |
| --- | --- | --- |
| RAM | 8 GB | 16 GB+ |
| CPU | 4 cores | 8+ cores |
| GPU | None (CPU inference) | NVIDIA GPU (8GB+ VRAM) |
| Storage | 40 GB | 200 GB+ (model files) |
| Network | LAN or tailnet to controller | LAN preferred for throughput |

---

## Deployment Groups

### Group: `ai-stack-infer` (subset)

Workers run only the inference runtime containers from the `infer` group.
LiteLLM and TurboQuant stay on the controller. Ollama on a worker exposes
its API on port 11434; LiteLLM on the controller routes to it by tailnet/LAN IP.

**Network:** `host` (Ollama binds to a specific interface; host network simplest for cross-node routing)
**SystemD target:** `ai-stack-infer-worker.target`

| Container | Image | Purpose | Notes |
| --- | --- | --- | --- |
| `ai-stack-infer-ollama` | `docker.io/ollama/ollama` | Local model runtime | Same image as controller |
| `ai-stack-infer-vllm` | `docker.io/vllm/vllm-openai` | GPU-accelerated runtime | Optional; CUDA required |

**Agent bundle (every node — not containerized):**
| Service | Manager | Purpose |
| --- | --- | --- |
| `tailscale` | systemd | Mesh connectivity to controller |
| `ai-stack-obs-promtail` | quadlet or systemd | Log shipping to controller Loki |
| `ai-stack-heartbeat` | systemd timer | Reports node status to knowledge-index |

---

## Worker Registration

Workers register with the controller's `ai-stack-know-index` via heartbeat.
The controller then makes the worker visible to LiteLLM for model routing.

**Generate join token (on controller):**
```bash
bash scripts/configure.sh generate-join-token \
  --node-id <worker-id> \
  --profile inference-worker \
  --display-name "<display name>"
# Token displayed once — copy before closing terminal
```

**Bootstrap worker (on worker node):**
```bash
bash scripts/bootstrap.sh \
  --controller "http://<controller-tailnet-ip>:8100" \
  --token "<token>" \
  --node-id "<worker-id>"
```

**Add worker to LiteLLM (on controller, `configs/litellm/proxy_config.yaml`):**
```yaml
model_list:
  - model_name: llama3.1:8b
    litellm_params:
      model: ollama/llama3.1:8b
      api_base: http://<worker-tailnet-ip>:11434
```
Restart LiteLLM after editing: `systemctl --user restart ai-stack-infer-litellm.service`

---

## Port Requirements

| Port | Protocol | Bind | Purpose |
| --- | --- | --- | --- |
| 11434 | TCP | LAN/tailnet IP | Ollama API — LiteLLM connects here |
| 8000 | TCP | LAN/tailnet IP | vLLM API (if running) |

**Harden Ollama port (restrict to controller only):**
```bash
bash scripts/node.sh harden-worker --alias <worker-alias>
# Prints firewall commands; run them on the worker
```
Ollama should not be reachable from the public internet or untrusted LAN segments.

---

## Node State Machine

| State | Condition | Recovery |
| --- | --- | --- |
| `online` | Heartbeat received within last 90s | Normal |
| `caution` | Last heartbeat 90–150s ago | Send 2 beats within 70s |
| `failed` | Last heartbeat > 150s ago | Send 2 beats within 70s |
| `offline` | Absent > 24h | Generate new join token from controller |

Check node status from controller:
```bash
bash scripts/node.sh list --controller http://localhost:8100
```

---

## Scripts Reference

| Script | Phase | Purpose |
| --- | --- | --- |
| `scripts/install.sh` | Setup | Install Podman and create storage layout on the worker host |
| `scripts/validate-system.sh` | Setup | Validate Podman version, GPU availability, storage prerequisites |
| `scripts/bootstrap.sh` | Registration | Zero-touch worker bootstrap — joins the controller with a token |
| `scripts/register-node.sh` | Registration | Introspects local environment and prints a config block for the controller's `config.json` |
| `scripts/node.sh join` | Registration | Join the controller with a previously generated token |
| `scripts/node.sh status` | Operations | Check this node's registration status against the controller |
| `scripts/node.sh unjoin` | Operations | Remove this node from the controller registry |
| `scripts/node.sh harden-worker` | Security | Print firewall rules that restrict Ollama port 11434 to controller IP only |
| `scripts/heartbeat.sh` | Operations | Send a single heartbeat to the controller (invoked by systemd timer) |
| `scripts/inhibit.sh` | Operations | Enable/disable OS sleep inhibition while inference is running |
| `scripts/pull-models.sh` | Models | Pull Ollama models and register routes in controller LiteLLM (run on controller after worker joins) |
| `scripts/status.sh` | Operations | Health status of deployed Ollama/vLLM containers |
| `scripts/stop.sh` | Operations | Stop inference containers |
| `scripts/start.sh` | Operations | Start inference containers |

**Worker bootstrap flow (typical):**
```bash
# 1. On controller — generate a join token
bash scripts/configure.sh generate-join-token \
  --node-id <id> --profile inference-worker --display-name "<name>"

# 2. On worker — bootstrap (installs, joins, starts heartbeat timer)
bash scripts/bootstrap.sh \
  --controller "http://<controller-tailnet-ip>:8100" \
  --token "<token>" --node-id "<id>"

# 3. On controller — verify registration and update LiteLLM config
bash scripts/node.sh list --controller http://localhost:8100
# Then add worker Ollama endpoint to configs/litellm/proxy_config.yaml
bash scripts/pull-models.sh
```

---

## Pre-Deployment Checklist

- [ ] Tailscale installed and enrolled in Headscale on edge node
- [ ] Tailnet IP assigned and stable (use ACL tags if needed)
- [ ] Ollama port 11434 reachable from controller tailnet IP; blocked from everything else
- [ ] Join token generated on controller and available
- [ ] Bootstrap script run; node shows `online` within two heartbeat cycles (~140s)
- [ ] LiteLLM `proxy_config.yaml` updated with worker Ollama endpoint
- [ ] At least one model pulled: `podman exec ai-stack-infer-ollama ollama pull <model>`
- [ ] Promtail configured to ship to controller Loki
- [ ] Heartbeat timer enabled: `systemctl --user enable --now ai-stack-heartbeat.timer`
- [ ] GPU driver and CUDA toolkit installed if vLLM is planned
- [ ] Sleep inhibitor configured if this worker should not suspend during inference

---

## Instance Customization

Instance overlay documents provide:

| Setting | Instance override |
| --- | --- |
| Node ID and alias | e.g., `tc25`, `sol` |
| Tailnet IP | Assigned by Headscale |
| GPU device | CUDA device index or `cpu` |
| Model list | Which models this worker serves |
| Ollama bind address | LAN IP vs tailnet IP |
| Sleep inhibitor | Enabled/disabled |

See: `docs/instances/<node-id>.md` (create one per worker node)
