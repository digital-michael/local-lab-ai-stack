# Authentik — Lessons Learned
**Last Updated:** 2026-03-08 UTC

## Purpose
Empirical findings from deploying Authentik in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [Empty Default CMD — Must Pass `server` Explicitly](#1-empty-default-cmd--must-pass-server-explicitly)

---

# 1 Empty Default CMD — Must Pass `server` Explicitly

**Version:** Authentik 2024.x (`ghcr.io/goauthentik/server`)  
**Discovered:** 2026-03-08, Phase 7 first-boot  
**See also:** `podman/lessons_learned.md`

## What Happened
The Authentik container started, printed management help text, then exited immediately with status 0. No server process launched and no ports were bound. The `podman ps` output showed the container as `Exited (0)` seconds after start.

The help text shown was the `ak` management CLI usage:

```
Usage: ak [OPTIONS] COMMAND [ARGS]...

  authentik management CLI

Options:
  ...
Commands:
  server     Start the authentik server
  worker     Start the authentik worker
  ...
```

## Root Cause
The Authentik image uses a multi-stage entrypoint:

```
ENTRYPOINT ["dumb-init", "--", "ak"]
CMD []
```

The `ENTRYPOINT` invokes `ak` via `dumb-init`. The `CMD` is **empty**. When Podman starts the container with no additional command, `ak` receives no arguments and defaults to printing its usage help, then exits clean.

This is different from images that default `CMD` to a sensible verb (e.g. `["server"]`). The Authentik image requires the operator to explicitly choose the sub-command.

## Fix
Two changes were required:

**1. Added `command` field to `configs/config.json`** for the authentik service:

```json
"authentik": {
  ...
  "command": "server"
}
```

**2. Updated `scripts/configure.sh`** to emit `Exec=` when the `command` field is present:

```bash
cmd_override=$(jq -r --arg s "$svc" '.services[$s].command // empty' "$CONFIG_FILE")
[[ -n "$cmd_override" ]] && echo "Exec=$cmd_override"
```

This appends `Exec=server` to the generated `.container` quadlet, which Podman passes as the container command after the ENTRYPOINT.

The worker process (used for background tasks) requires a separate container instance with `Exec=worker`. The stack currently runs the server only.

## Rule
> Check `docker inspect <image>` for `Cmd` before deploying. If `Cmd` is empty and the image uses a multi-command CLI entrypoint (like `ak`), you **must** supply the sub-command explicitly via `Exec=` in the quadlet or `command:` in the compose spec.
