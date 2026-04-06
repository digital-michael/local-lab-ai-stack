# scripts/ — AI Stack Script Reference

**Last Updated:** 2026-04-06

Scripts are listed in **operational order**: environment setup → first deployment → running operations → reconfiguration → troubleshooting → shutdown and teardown. Worker node scripts follow.

Run any script with `--help` or `-h` for full usage details, options, and examples.

---

## Table of Contents

- [Environment Setup](#environment-setup) — `validate-system.sh` · `install.sh` · `generate-tls.sh`
- [First Deployment](#first-deployment) — `configure.sh` · `deploy.sh` · `pull-models.sh`
- [Running Operations](#running-operations) — `start.sh` · `status.sh` · `backup.sh` · `inhibit.sh`
- [Reconfiguration](#reconfiguration)
- [Troubleshooting](#troubleshooting) — `diagnose.sh`
- [Shutdown and Teardown](#shutdown-and-teardown) — `stop.sh` · `undeploy.sh`
- [Worker Node Scripts](#worker-node-scripts) — `node.sh` · `bootstrap.sh` · `heartbeat.sh` · `register-node.sh`
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
CRUD interface for `config.json`. Generates systemd quadlet files and Podman secrets from configuration. Primary subcommands: `generate-quadlets`, `generate-secrets`, `validate`, `build-library`, `sync-libraries`, `detect-hardware`, `security-audit`. The source of truth for any generated artifact in the stack.

### `deploy.sh`
Orchestrates full deployment. Calls `configure.sh` to generate quadlets and secrets, registers services with systemd, and starts them in dependency order. Detects controller vs. bare-metal (macOS) deploy mode automatically.

### `pull-models.sh`
Registers model routes from `configs/models.json` into LiteLLM via `POST /model/new`. Deletes and re-creates any existing entry with the same name so re-runs with updated parameters take effect cleanly. Run after `deploy.sh` to populate the model routing table.

---

## Running Operations

### `start.sh`
Starts all stack services via systemd user units. Checks that the stack is deployed (quadlet files present) before proceeding; offers to run `deploy.sh` if not.

### `status.sh`
Shows per-service health. Reads quadlet state from systemd and container health from Podman. Exit codes: `0` all active, `1` degraded (one or more not active), `2` not deployed.

### `backup.sh`
Backs up all persistent stack data to `$AI_STACK_DIR/backups/<timestamp>/`: PostgreSQL (`pg_dump`), Qdrant (REST snapshot), libraries directory, and configs (excluding TLS private keys). Retains the 7 most recent sets. Designed to run as a systemd timer or cron job.

### `inhibit.sh`
Sleep/hibernation inhibitor for worker nodes. Acquires a sleep lock (`caffeinate` on macOS, `systemd-inhibit` on Linux) while the stack is running. Opt-in via `"sleep_inhibit": true` in `config.json`. Controller nodes are always skipped.

---

## Reconfiguration

### `configure.sh` *(see above)*
Also used mid-lifecycle: `configure.sh detect-hardware` probes GPU/VRAM/RAM and recommends a node profile; `configure.sh validate` checks `config.json` for consistency; `configure.sh security-audit` runs the posture scan.

### `pull-models.sh` *(see above)*
Re-run after changing `configs/models.json` to update the LiteLLM model routing table without redeploying.

---

## Troubleshooting

### `diagnose.sh`
Per-service diagnostic walkthrough. `quick` mode (default): systemd state, container health, network existence, dependency reachability, model availability. `full` mode: adds integration probes, config validation, secret inventory, volume paths, resource pressure, and API readiness probes. Exit codes: `0` all pass, `1` warnings/failures, `2` stack not deployed.

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
Node lifecycle management. Subcommands: `deploy` (install knowledge-index container on this worker), `join` (register with controller using a one-time token), `unjoin` (deregister), `purge` (hard-delete offline nodes from the registry), `harden-worker` (firewall hardening for inference ports).

### `bootstrap.sh`
Zero-touch worker bootstrap. Designed to be piped from `curl` or `wget` on a fresh machine. Accepts `--controller <url> --token <token>` and performs the full join sequence: installs dependencies, clones config, calls `node.sh join`. SHA-256 verification supported via `--sha256`.

### `heartbeat.sh`
Sends a periodic heartbeat from a worker node to the controller's `/v1/nodes/{id}/heartbeat` endpoint. Reads connection state from `~/.config/ai-stack/`. Called by a systemd timer (every 30 s); can be run manually to verify connectivity.

### `register-node.sh`
Run on a remote node to introspect the local environment and print a config block for pasting into `configs/config.json nodes[]` and `models[]` on the controller. Makes no automatic writes — output is for human review (static config model, per D-020).

---

## Subdirectory Scripts

### `bare_metal/setup-macos.sh`
Sets up bare-metal Ollama on macOS (Apple Silicon) as an inference worker. Installs Ollama via Homebrew, detects hardware to select a quantized model, pulls it, and configures a LaunchAgent for auto-start on login.

### `podman/setup-worker.sh`
Sets up an inference-worker node on Linux using Podman. Detects hardware, generates `ollama` and `promtail` quadlets for the inference-worker profile, pulls the recommended quantized model, and enables the service.
