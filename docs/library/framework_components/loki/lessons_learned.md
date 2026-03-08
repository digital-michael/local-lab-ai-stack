# Loki — Lessons Learned
**Last Updated:** 2026-03-08 UTC

## Purpose
Empirical findings from deploying Loki in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [Retention Requires `delete_request_store`](#1-retention-requires-delete_request_store)
2. [Non-Root UID Requires Host Directory Ownership Fix](#2-non-root-uid-requires-host-directory-ownership-fix)

---

# 1 Retention Requires `delete_request_store`

**Version:** Loki v3.x  
**Discovered:** 2026-03-08, Phase 7 first-boot

## What Happened
The initial `local-config.yaml` had retention enabled:

```yaml
limits_config:
  retention_period: 168h

compactor:
  working_directory: /loki/compactor
  retention_enabled: true
```

Loki exited immediately on startup with:

```
CONFIG ERROR: invalid compactor config: compactor.delete-request-store should be
configured when retention is enabled
```

## Root Cause
Loki v3 requires an explicit `delete_request_store` when `retention_enabled: true`. This tells the compactor where to persist delete request state. It was not required in Loki v2 and the error message was absent from common quickstart guides at the time.

## Fix
Added `delete_request_store: filesystem` to the compactor block:

```yaml
compactor:
  working_directory: /loki/compactor
  retention_enabled: true
  delete_request_store: filesystem
```

## Rule
> In Loki v3, any config that enables `compactor.retention_enabled: true` **must** also set `compactor.delete_request_store`. Use `filesystem` for single-node deployments using the `tsdb` store.

---

# 2 Non-Root UID Requires Host Directory Ownership Fix

**Version:** Loki v3.x, Podman 5.7 rootless  
**Discovered:** 2026-03-08, Phase 7 first-boot  
**See also:** `podman/lessons_learned.md §2`

## What Happened
Loki started but immediately exited:

```
error running loki: mkdir /loki/rules: permission denied
```

The `/loki` directory was a bind mount from `$AI_STACK_DIR/logs/loki/`, owned by the host user (UID 1000). Loki runs as **UID 10001** inside the container.

## Root Cause
In rootless Podman, the host directory is accessed through a user namespace mapping. The container process (UID 10001) does not have write access to a directory owned by the host user (UID 1000) unless the host directory's ownership is explicitly mapped.

## Fix
Use `podman unshare` to set ownership in the host-mapped namespace before starting the container:

```bash
podman unshare chown -R 10001:10001 ~/ai-stack/logs/loki
```

`podman unshare` runs the command inside the same user namespace that containers use, so UID 10001 maps correctly to the subuid range on the host.

## Rule
> Before first start, run `podman unshare chown -R <uid>:<gid> <host-path>` for every bind-mount data directory of a container that runs as a non-root UID. Check the container's UID with `podman image inspect --format '{{.Config.User}}' <image>`. Loki = 10001, Grafana = 472.
