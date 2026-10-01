# scripts/ — AI Stack Script Reference

**Last Updated:** 2026-04-06

Scripts are listed in **operational order**: environment setup → first deployment → running operations → reconfiguration → troubleshooting → shutdown and teardown. Worker node scripts follow.

Run any script with `--help` or `-h` for full usage details, options, and examples.

---

## Table of Contents

- [Environment Setup](#environment-setup) — `validate-system.sh` · `install.sh` · `generate-tls.sh`
- [First Deployment](#first-deployment) — `configure.sh` · `deploy.sh` · `pull-models.sh`
- [Running Operations](#running-operations) — `start.sh` · `status.sh` · `loads.sh` · `backup.sh` · `cleanup.sh` · `inhibit.sh`
- [Reconfiguration](#reconfiguration)
- [Troubleshooting](#troubleshooting) — `diagnose.sh` · `model-inventory.sh` · `smoketest-openwebui.py` · `check-provisioning.py`
- [Shutdown and Teardown](#shutdown-and-teardown) — `stop.sh` · `undeploy.sh`
- [Worker Node Scripts](#worker-node-scripts) — `node.sh` · `register-node.sh`
- [Subdirectory Scripts](#subdirectory-scripts) — `bare_metal/setup-macos.sh` · `podman/setup-worker.sh`

---

## Environment Setup

### `validate-system.sh`
Pre-flight check. Verifies Podman installation, optional GPU availability, and storage directory existence. Run before `install.sh` on a new host.

### `install.sh`
One-time system setup. Installs system dependencies (`podman`, `git`, `python3`) and creates the storage directory layout under `$AI_STACK_DIR` (default: `~/ai-stack`). Run once per host before first deployment.

### `generate-tls.sh`
Generates a local self-signed CA and server certificate for Traefik. Produces `ca.crt`, `ca.key`, `server.crt`, `server.key`, and `server.pem` under `$AI_STACK_DIR/configs/tls/`. Run once before first deployment on the controller node.

---

## First Deployment

### `configure.sh`
CRUD interface for `config.json`. Generates systemd quadlet files and Podman secrets from configuration. Primary subcommands: `generate-quadlets`, `generate-secrets`, `validate`, `build-library`, `detect-hardware`, `security-audit`. The source of truth for any generated artifact in the stack.

### `deploy.sh`
Orchestrates full deployment. Calls `configure.sh` to generate quadlets and secrets, registers services with systemd, and starts them in dependency order. Detects controller vs. bare-metal (macOS) deploy mode automatically.

### `pull-models.sh`
Registers model routes from `configs/models.json` into LiteLLM via `POST /model/new`. Deletes and re-creates any existing entry with the same name so re-runs with updated parameters take effect cleanly. Run after `deploy.sh` to populate the model routing table. Also tags each route with a merged `model_info.tags` list (see `output/CENTAURI-playbook.md` §13 L-31/L-32/L-34/L-35) combining the `strong-1`-style node classification (looked up fresh on every run from each model's `litellm_params.api_base` host against `configs/nodes/*.json`'s own `node_tier`/`node_rank` fields) with Ollama's live supported-modes capabilities (completion/tools/thinking/vision/etc., via `/api/show` — skipped for vLLM/cloud backends, which have no equivalent source, and for remote nodes that are unreachable at registration time, rather than guessed). Both are baked into registration itself, so the delete+recreate above can't silently wipe a tag applied as an afterward, separate step (L-32 found that happening the hard way) — re-running this script is how you refresh a model's mode tags after re-pulling it with different capabilities. The same merged tags are also synced into OpenWebUI's own `model.meta.tags` (upserting the `model`/`access_grant` rows as needed, skipped gracefully if the `openwebui` container isn't running), since LiteLLM's `model_info` is admin/API-only — invisible to regular users otherwise. Cloud models (no `api_base`, so no tier either) and per-node alias routes (`ollama/<model>@<node>`, used by the Layer 5 distributed tests) are deliberately left untagged and unsynced, matching L-31's original scope. Finally, signs in to OpenWebUI as its admin user (via the same trusted-header mechanism its SSO uses) purely to call `/api/models?refresh=true` — OpenWebUI caches its merged base-model list in-process with no TTL (`models.base_models_cache`), so without this, anything this run added, removed, or renamed stays invisible until someone manually clicks Refresh in Admin Panel > Settings > Models or the container restarts (L-37). Best-effort: any failure in this last step is a warning, not a script failure.

---

## Running Operations

### `start.sh`
Starts all stack services via systemd user units. Checks that the stack is deployed (quadlet files present) before proceeding; offers to run `deploy.sh` if not.

### `status.sh`
Shows per-service health. Reads quadlet state from systemd and container health from Podman. Exit codes: `0` all active, `1` degraded (one or more not active), `2` not deployed.

### `loads.sh`
Shows current CPU load per component (podman `stats` for containerized services, `ps`-aggregated for bare-metal ones like a macOS Ollama install), with currently-loaded AI models nested under their serving component as `<hostname>/<model>`, sorted by CPU% descending, each showing parameter count and on-disk file size straight from Ollama's own metadata (vLLM's plain `/v1/models` has none, so those rows show `-` rather than a guess). Attributes each loaded Ollama model its own CPU% (and GPU% when `nvidia-smi` is present) by matching its runner subprocess's blob path against the weights-layer digest read from that model's manifest file on disk (`/api/ps`'s own "digest" field is the *manifest's* digest, a different hash that never matches the blob path, so it can't be used for this) — no guessing when attribution isn't possible, the model's row just shows `-` and the component row still has the real total. A single vLLM instance is attributed to its one served model directly. Each model row also shows which OpenWebUI user (real name/email from Authentik SSO, not a Linux account) most recently got an assistant turn from it, as `user (now)` / `user (12m ago)` — an honest age rather than going blank the moment a conversation pauses — empty only if no one has within `ACTIVE_LOOKBACK_SECONDS` (default 6h). Read from OpenWebUI's own `webui.db`, since LiteLLM's request logs never see real per-person identity in this stack (every request logs as `"default_user_id"`). `-v`/`--all` also lists Ollama models that are pulled but not currently loaded (`/api/tags`), marked `[not loaded]` with no CPU/GPU/user data since nothing is running for them. Also nests LiteLLM's full registered model catalog (`/model/info` — local ollama/vllm routes and cloud providers alike) under its own `litellm` component row, each showing how long since its last successful request (`/spend/logs/v2`, needs the `litellm_master_key` Podman secret; skipped gracefully if unavailable). This is a genuinely separate signal from the OpenWebUI one above it — OpenWebUI can talk to Ollama directly for local models, bypassing LiteLLM entirely, so a model can show recent OpenWebUI activity while LiteLLM shows `last used: -` for that same model; that's real stack behavior, not a bug. Also reports swap usage and a live swap I/O rate from `/proc/vmstat`, flagging `[THRASHING]` when a machine is actively swapping under memory pressure rather than just sitting on old idle pages. `--json` emits structured output. Local host only — see `model-inventory.sh` for fleet-wide model placement.

### `backup.sh`
Backs up all persistent stack data to `$AI_STACK_DIR/backups/<timestamp>/`: PostgreSQL (`pg_dump`), Qdrant (REST snapshot), libraries directory, and configs (excluding TLS private keys). Retains the 7 most recent sets. Designed to run as a systemd timer or cron job.

### `cleanup.sh`
Placeholder for future maintenance needs — currently just `images` (`podman image prune`, dangling ai-stack images only), `images-all` (`podman image prune -a`, all unused ai-stack images incl. tagged), and `postgres` (`VACUUM ANALYZE` every database in the cluster). Image pruning is filtered to this stack's own images via its `com.docker.compose.project=ai-stack` label, so it won't touch unrelated podman workloads on the same host. `report` shows disk usage and postgres dead-tuple counts without changing anything. `--dry-run` available on every command.

### `inhibit.sh`
Sleep/hibernation inhibitor for worker nodes. Acquires a sleep lock (`caffeinate` on macOS, `systemd-inhibit` on Linux) while the stack is running. Opt-in via `"sleep_inhibit": true` in `config.json`. Controller nodes are always skipped.

---

## Reconfiguration

### `configure.sh` *(see above)*
Also used mid-lifecycle: `configure.sh detect-hardware` probes GPU/VRAM/RAM and recommends a node profile; `configure.sh validate` checks `config.json` for consistency; `configure.sh security-audit` runs the posture scan.

### `pull-models.sh` *(see above)*
Re-run after changing `configs/models.json` to update the LiteLLM model routing table without redeploying.

## Troubleshooting

### `diagnose.sh`
Per-service diagnostic walkthrough. `quick` mode (default): systemd state, container health, network existence, dependency reachability, model availability. `full` mode: adds integration probes, config validation, secret inventory, volume paths, resource pressure, and API readiness probes. Exit codes: `0` all pass, `1` warnings/failures, `2` stack not deployed.

### `model-inventory.sh`
Per-node model inventory. For the controller and every node in `configs/nodes/*.json`: live-probes reachability (Ollama `/api/tags`; vLLM `/v1/models` on the controller) and cross-references against LiteLLM's actually-registered routes (via its authenticated `/model/info` API — `litellm_params` is encrypted at rest, so raw SQL can't read `api_base`). Flags models available-but-unregistered and registered-but-not-available (stale routes). Cloud/API-hosted models (openai/groq/anthropic/mistral) are reported separately — registration + secret-provisioned status only, no live provider calls. `-v`/`--verbose` adds per-model disk size, parameter count, and a `PULLED` date (all from Ollama's `/api/tags`, no extra call — `PULLED` is Ollama's own `modified_at`, i.e. when *this host* downloaded the model, not an upstream release/publication date, which Ollama's API exposes nowhere), plus a single merged `TAGS` column read straight from LiteLLM's `model_info.tags` — no live probing of its own, so nothing extra to wait on for remote nodes. That list combines the `strong-1`-style `node_tier`/`node_rank` classification with supported-modes labels (completion/tools/thinking/vision/etc., alphabetically sorted by `pull-models.sh` itself so the column is always in a consistent order); both are written into `model_info.tags` by `pull-models.sh` on every run (see `output/CENTAURI-playbook.md` §13 L-31/L-32/L-34/L-35/L-36), so `-` means genuinely untagged — a cloud model or a per-node alias route, both deliberately excluded from the scheme, not a side effect of a recent re-registration. `--json` keeps `classification` and `modes` as separate fields (unlike the merged text column) for easier machine consumption. Also prints the controller's Ollama server version and its local model-repository directory with total and free space on that filesystem, once under its own section (filesystem-level info, so controller-only — nothing in Ollama's API exposes a remote node's storage path or free space). `--color` dims unregistered/unavailable/stale entries in red.

### `smoketest-openwebui.py`
Post-change smoke test for OpenWebUI — container health, version endpoint, trusted-header SSO signin, model list, existing chat history, the Authentik signout redirect, and a container-log error scan since last start. Reads expected values (port, trusted-header names, signout redirect URL) from `config.json` rather than hardcoding them, so it keeps working across version upgrades instead of needing to be rewritten per version. Refuses to sign in as an email with no existing account, since trusted-header auth auto-provisions a real user as a side effect otherwise (see openwebui `lessons_learned.md` #7). Run `scripts/users.sh` first if the run involves a restart. Stdlib-only, no dependencies beyond `python3` and `podman`. Exit codes: `0` all checks passed, `1` one or more failed, `2` environment/config problem.

### `check-provisioning.py`
Cross-checks every real user across Authentik (`auth.photondatum.space`, via its REST API using the existing `homepage_authentik_token` podman secret) and OpenWebUI (this host, via `webui.db`) and reports anyone not fully provisioned: Authentik account inactive (the self-service social-login gap — see `authentik/access-control.md` § User Lifecycle), zero Authentik groups, missing OpenWebUI account, OpenWebUI role stuck at `pending`, or zero OpenWebUI groups. Deliberately generic on the group checks — flags zero group memberships on either side, not membership in any specific named group; which group(s) new users should actually land in is a policy question to tighten later (see `openwebui/provisioning-guide.md`). Excludes Authentik service/outpost accounts automatically. Read-only — reports gaps, does not activate accounts or assign groups. `--email` checks a single person; `--json` for structured output. Stdlib-only. Exit codes: `0` everyone fully provisioned, `1` one or more gaps found, `2` environment/credential problem.

---

## Shutdown and Teardown

### `stop.sh`
Stops all stack services via systemd user units in reverse dependency order (dependents before dependencies).

### `undeploy.sh`
Tears down the deployment. Modes: `--services` (stop + remove quadlet files), `--data` (implies `--services`; wipes `$AI_STACK_DIR` data dirs), `--hard` / `--purge` (services + data + network + Podman secrets).

---

## Worker Node Scripts

These run **on the worker node**, not the controller.

### `node.sh`
Node operations. Subcommands: `list` (nodes from headscale), `remote` (run a command on a worker over SSH), `harden-worker` (firewall hardening for inference ports). The controller node registry (`join`/`unjoin`/`purge`, `bootstrap.sh`, `heartbeat.sh`) lived in the Python Knowledge Index and was removed with it on 2026-09-30 (D-045).

### `register-node.sh`
Run on a remote node to introspect the local environment and print a config block for pasting into `configs/config.json nodes[]` and `models[]` on the controller. Makes no automatic writes — output is for human review (static config model, per D-020).

---

## Subdirectory Scripts

### `bare_metal/setup-macos.sh`
Sets up bare-metal Ollama on macOS (Apple Silicon) as an inference worker. Installs Ollama via Homebrew, detects hardware to select a quantized model, pulls it, and configures a LaunchAgent for auto-start on login.

### `podman/setup-worker.sh`
Sets up an inference-worker node on Linux using Podman. Detects hardware, generates `ollama` and `promtail` quadlets for the inference-worker profile, pulls the recommended quantized model, and enables the service.
