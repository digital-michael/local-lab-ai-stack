# Worker Role

## Purpose

The worker role extends inference capacity. A worker node runs Ollama (and
optionally vLLM) and is registered statically in the controller's
`configs/nodes/` (the knowledge-index heartbeat registry was removed 2026-09-30,
D-045). LiteLLM on the controller routes model requests to registered workers. Workers can be added or removed without changing any
controller configuration beyond the LiteLLM model route list.

Workers are not always-on. They can be idle machines that come online when
inference demand is high, or dedicated GPU machines that stay on continuously.

---

## Operational Access Model

> **This is a hard architectural rule. Read before beginning any deployment.**
>
> Two distinct users govern every deployment. They must never be the same account.
>
> | Role | Purpose | Lifecycle |
> | --- | --- | --- |
> | **Setup / configuration** | Install packages, enable services | Temporary — revoke after deployment |
> | **Execution owner** | Runs rootless Podman; owns all container state | Permanent |
>
> Rootless Podman uses the **real UID** of the invoking process. Running Podman via `su` from
> another session always fails or operates in the wrong security context.
>
> See [security-policy.md §5](../security-policy.md) for the full access model and instance
> user mapping. See [podman/lessons_learned.md §7](../library/framework_components/podman/lessons_learned.md)
> for the technical root cause.

---

## Dependencies

### Role dependencies (must be deployed first)

| Role | Required by | What fails without it |
| --- | --- | --- |
| Edge role — mesh group | Tailscale agent | Cannot enroll in Headscale; tailnet connectivity unavailable |
| Controller role | All worker function | No LiteLLM endpoint to register with; no model routing |

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

**Planned extension — task-execution endpoint (`mcp-local`):**
`mcp-local`, developed in the same `cortex` project as `cortex-stack`, is currently an
experimental, stdio-only MCP tool server (Claude Code/VS Code integration). Part of what
it's experimenting with is a non-local execution mode — letting tasks delegated by
`cortex-stack`'s task-delegation layer (see controller-role.md) execute directly on
whichever worker holds the target model, rather than only on the controller. Not yet
implemented — workers today expose only inference capacity (Ollama/vLLM), no
tool-execution surface. See
`~/Documents/Entities/Photon Datum/cortex/docs/mcp-local.md` for the design.

---

## Worker Registration

> **Changed 2026-09-30 (D-045):** the dynamic join/heartbeat registry lived in the Python
> Knowledge Index and was removed with it (`generate-join-token`, `bootstrap.sh`,
> `heartbeat.sh`, `node.sh join`). Workers are registered statically for now.

**Describe the worker (on the worker node):** `bash scripts/register-node.sh` prints a
config block; review it and add it to the controller's `configs/nodes/<alias>.json`
(static config model, D-020/D-026). Presence comes from the tailnet (headscale).

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

> Retired with the registry on 2026-09-30 (D-045). Kept as a reference for a future
> registry; `node.sh list` now reports headscale online/offline only.

| State | Condition | Recovery |
| --- | --- | --- |
| `online` | Heartbeat received within last 90s | Normal |
| `caution` | Last heartbeat 90–150s ago | Send 2 beats within 70s |
| `failed` | Last heartbeat > 150s ago | Send 2 beats within 70s |
| `offline` | Absent > 24h | Generate new join token from controller |

**Planned extension — `dispatch-enabled` flag:** online/offline state answers whether a
worker is *reachable*, not whether it should *receive delegated tasks*. Cortex
Federated's `dispatch` domain (see controller-role.md's `ai-stack-know` planned
extension) needs a second, independent flag per node — a worker can be `online` for
inference but not dispatch-enabled (e.g. reserved for direct use, or not yet trusted for
delegated execution). Not yet implemented; not part of the current heartbeat payload.

Check node status from controller:

```bash
bash scripts/node.sh list --headscale-url <url> --headscale-key <key>
```

---

## Scripts Reference

| Script | Phase | Purpose |
| --- | --- | --- |
| `scripts/install.sh` | Setup | Install Podman and create storage layout on the worker host |
| `scripts/validate-system.sh` | Setup | Validate Podman version, GPU availability, storage prerequisites |
| `scripts/register-node.sh` | Registration | Introspects local environment and prints a config block for the controller's `config.json` |
| `scripts/node.sh harden-worker` | Security | Print firewall rules that restrict Ollama port 11434 to controller IP only |
| `scripts/inhibit.sh` | Operations | Enable/disable OS sleep inhibition while inference is running |
| `scripts/pull-models.sh` | Models | Pull Ollama models and register routes in controller LiteLLM (run on controller after worker joins) |
| `scripts/status.sh` | Operations | Health status of deployed Ollama/vLLM containers |
| `scripts/stop.sh` | Operations | Stop inference containers |
| `scripts/start.sh` | Operations | Start inference containers |

**Worker bootstrap flow (typical):**

```bash
# 1. On worker — describe the node; add the printed block to configs/nodes/<alias>.json on the controller
bash scripts/register-node.sh

# 2. On controller — confirm the worker is on the tailnet and update LiteLLM config
bash scripts/node.sh list --headscale-url <url> --headscale-key <key>
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
