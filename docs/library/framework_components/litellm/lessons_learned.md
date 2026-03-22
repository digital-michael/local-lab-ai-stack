# LiteLLM — Lessons Learned
**Last Updated:** 2026-03-21 UTC (Phase 9c)

## Purpose
Empirical findings from operating LiteLLM as a routing proxy in the ai-stack. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [LITELLM_MASTER_KEY Is a Podman Secret — Cannot Be Read with `jq` from config.json](#1-litellm_master_key-is-a-podman-secret--cannot-be-read-with-jq-from-configjson)
2. [Unit File Changed Warning Requires `daemon-reload` Before `restart`](#2-unit-file-changed-warning-requires-daemon-reload-before-restart)

---

# 1 LITELLM_MASTER_KEY Is a Podman Secret — Cannot Be Read with `jq` from config.json

**Version:** LiteLLM 1.x, Podman 5.8.1  
**Discovered:** 2026-03-21, Phase 9c controller verification

## What Happened
The curl verification command used:
```bash
-H "Authorization: Bearer $(jq -r '.services.litellm.environment.LITELLM_MASTER_KEY' configs/config.json)"
```
LiteLLM returned a 401: `"Authentication Error, Malformed API Key passed in. Ensure Key has 'Bearer' prefix."` The `Bearer ` prefix was present but the key value was empty — `jq` returned nothing because `LITELLM_MASTER_KEY` does not appear in the `environment` block of `config.json`.

## Root Cause
`LITELLM_MASTER_KEY` is injected into the litellm container as a **Podman secret** (via the `secrets:` block in `config.json`), not as an env var in the `environment:` block. Secrets are stored in Podman's secret store and mounted at `/run/secrets/<name>` inside the container at runtime. They are never written to `config.json` in plaintext.

`jq` on `config.json` therefore returns an empty string, which becomes `Bearer ` with no key — a malformed header.

## Fix
Read the secret via a throwaway alpine container (the same pattern used by `testing/helpers.bash::read_secret()`):
```bash
LITELLM_KEY=$(podman run --rm --secret litellm_master_key \
  docker.io/library/alpine:latest \
  sh -c "cat /run/secrets/litellm_master_key")
```
For scripted use, source `testing/helpers.bash` and call `read_secret "litellm_master_key"` directly.

## Rule
> Never attempt to read a Podman secret value via `config.json`. Secrets are stored out-of-band in Podman's secret store and are not present in any config file. Use the `read_secret()` helper in `testing/helpers.bash` as the authoritative pattern for programmatic secret retrieval.

---

# 2 Unit File Changed Warning Requires `daemon-reload` Before `restart`

**Version:** LiteLLM, systemd quadlet, Podman 5.8.1  
**Discovered:** 2026-03-21, Phase 9c controller LiteLLM update

## What Happened
After running `bash scripts/configure.sh generate-litellm-config`, a `systemctl --user restart litellm.service` was issued immediately. Systemd printed:

```
Warning: The unit file, source configuration file or drop-ins of litellm.service changed on disk.
Run 'systemctl --user daemon-reload' to reload units.
```

The service reported `active` but the new model routes may not have been picked up because the running unit was stale.

## Root Cause
`generate-litellm-config` writes an updated `configs/models.json` and may regenerate the litellm quadlet `.container` file (e.g. if the config volume mount path changed). Systemd detects that the unit file on disk differs from what it has in memory and warns that `daemon-reload` is required. Without it, `restart` operates on the old in-memory unit definition.

## Fix
Always `daemon-reload` before restarting any service whose unit file may have changed:
```bash
bash scripts/configure.sh generate-litellm-config
bash scripts/pull-models.sh
systemctl --user daemon-reload
systemctl --user restart litellm.service
sleep 3
systemctl --user is-active litellm.service
```

## Rule
> Any time `configure.sh` or another generator script runs, issue `systemctl --user daemon-reload` before the subsequent `restart`. Make this the standard sequence in runbooks and scripts: generate → pull-models → daemon-reload → restart → health check.
