# Podman — Lessons Learned
**Last Updated:** 2026-03-21 UTC

## Purpose
Empirical findings from operating Podman in rootless mode with systemd quadlets. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [Rootless Port Binding Below 1024 Requires Sysctl](#1-rootless-port-binding-below-1024-requires-sysctl)
2. [Non-Root Container UIDs Require `podman unshare chown` on Bind-Mount Directories](#2-non-root-container-uids-require-podman-unshare-chown-on-bind-mount-directories)
3. [Quadlet-Generated Units Cannot Be `enable`d — Use `start`](#3-quadlet-generated-units-cannot-be-enabled--use-start)
4. [Env Var Overrides Must Be Exported to Subprocess — Not Just Written to a Temp File](#4-env-var-overrides-must-be-exported-to-subprocess--not-just-written-to-a-temp-file)

---

# 1 Rootless Port Binding Below 1024 Requires Sysctl

**Version:** Podman 5.7, Linux kernel 6.x  
**Discovered:** 2026-03-08, Phase 7 first-boot  
**See also:** `traefik/lessons_learned.md §3`

## What Happened
Traefik failed to start with:

```
error while booting up: error while building entrypoint: error preparing server: error opening listener: listen tcp :80: bind: permission denied
```

The quadlet was generating a valid `.container` file and the service unit loaded correctly. The port 80 binding itself was the failure point.

## Root Cause
By default, Linux restricts unprivileged processes (those without `CAP_NET_BIND_SERVICE`) from binding to ports below **1024**. The kernel parameter `net.ipv4.ip_unprivileged_port_start` controls this threshold. Its default value is `1024`.

Rootless Podman runs without elevated capabilities. Containers started by a rootless Podman instance therefore also cannot bind privileged ports unless the sysctl threshold is lowered.

## Fix
Lower the threshold to 80 at runtime and persist it across reboots:

```bash
# Apply immediately
sudo sysctl net.ipv4.ip_unprivileged_port_start=80

# Persist across reboots
echo 'net.ipv4.ip_unprivileged_port_start=80' | sudo tee /etc/sysctl.d/99-unprivileged-ports.conf
sudo sysctl --system
```

This allows any process on the host to bind ports ≥ 80 without additional capabilities, which is acceptable on a single-user workstation. For shared or multi-user servers, consider a narrower approach (e.g., `CAP_NET_BIND_SERVICE` on the Podman binary) instead.

## Rule
> On rootless Podman hosts where any container binds ports 80 or 443, set `net.ipv4.ip_unprivileged_port_start=80` and persist it to `/etc/sysctl.d/`. Document this as a system prerequisite in `install.sh`.

---

# 2 Non-Root Container UIDs Require `podman unshare chown` on Bind-Mount Directories

**Version:** Podman 5.7, rootless mode  
**Discovered:** 2026-03-08, Phase 7 first-boot  
**See also:** `loki/lessons_learned.md §2`

## What Happened
Both Loki and Grafana exited on first start with `permission denied` errors when trying to write to their bind-mounted data directories. The directories existed and were owned by the host user (UID 1000), but the containers ran as different UIDs:

| Service | Container UID |
|---------|--------------|
| Loki    | 10001        |
| Grafana | 472          |

## Root Cause
Rootless Podman uses a **user namespace** (via `/etc/subuid` and `/etc/subgid`) to map container UIDs to host UIDs. Inside the container, UID 10001 appears normal. On the host, it maps to a sub-UID in the user's allocation range (e.g. `1000100001`).

When a container process tries to access a host directory owned by UID 1000, the kernel sees the processes's effective UID as something in the sub-UID range — not UID 1000. The access check fails.

Changing the directory ownership directly on the host to `10001:10001` does not help: the kernel's view of that UID is the host user's sub-UID, not `10001`.

## Fix
Use `podman unshare` to run `chown` inside the same user namespace that containers use. Inside this namespace, UID 10001 maps correctly:

```bash
# Loki data directory
podman unshare chown -R 10001:10001 ~/ai-stack/logs/loki

# Grafana data directory
podman unshare chown -R 472:472 ~/ai-stack/grafana
```

After these commands, a `ls -ln ~/ai-stack/logs/loki` on the host will show a large UID (the sub-UID range), which is correct and expected.

## Rule
> Before first start, run `podman unshare chown -R <uid>:<gid> <host-path>` for every bind-mount directory of any container that runs as a non-root UID. Determine the UID with:
> ```bash
> podman image inspect --format '{{.Config.User}}' <image>
> ```
> Add all required `podman unshare` calls to the deployment script's setup phase so they run automatically on install.

---

# 3 Quadlet-Generated Units Cannot Be `enable`d — Use `start`

**Version:** Podman 5.8.1, systemd 256  
**Discovered:** 2026-03-21, Phase 9c setup-worker.sh execution

## What Happened
`systemctl --user enable --now ollama.service` failed with:

```
Failed to enable unit: Unit /run/user/1000/systemd/generator/ollama.service is transient or generated
```

The `.container` quadlet file was valid and present in `~/.config/containers/systemd/`. The service appeared correctly after `daemon-reload`.

## Root Cause
Systemd generates unit files from `.container` quadlets at runtime and places them in the transient generator directory `/run/user/<uid>/systemd/generator/`. This path is read-only and ephemeral — `systemctl enable` works by writing a symlink under `~/.config/systemd/user/`, which it cannot do for units originating from the generator.

Quadlets written with `[Install] WantedBy=default.target` in the `.container` file are **automatically enabled** at `daemon-reload` time via the generator mechanism — no explicit `enable` call is needed or possible.

## Fix
Replace `systemctl --user enable --now <service>` with plain `systemctl --user start <service>`. The generator already handles auto-start on login via the `WantedBy` directive.

```bash
# Wrong — fails on quadlet-generated units
systemctl --user enable --now ollama.service

# Correct
systemctl --user daemon-reload
systemctl --user start ollama.service
```

## Rule
> Never use `systemctl --user enable` on a quadlet-generated service. After `daemon-reload`, use `start` to bring it up immediately. Auto-start on login is already handled by `WantedBy=default.target` in the `.container` file.

---

# 4 Env Var Overrides Must Be Exported to Subprocess — Not Just Written to a Temp File

**Version:** bash, configure.sh pattern  
**Discovered:** 2026-03-21, Phase 9c setup-worker.sh execution

## What Happened
`setup-worker.sh` wrote a modified `config.json` to a temp path (`$TMPCONFIG`) with `node_profile` set to `inference-worker`, then called `bash configure.sh generate-quadlets` — which ignored the temp file and read the original `CONFIG_FILE` path, generating all controller-profile containers instead of just `ollama + promtail`.

## Root Cause
`configure.sh` resolves its config path via:
```bash
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"
```
The temp file was created but `CONFIG_FILE` in the calling script was never updated or exported to the subprocess environment. The child process read its own default.

## Fix
Pass the override inline on the subprocess invocation:
```bash
# Wrong — temp file created, but child sees original CONFIG_FILE
bash "$CONFIGURE" generate-quadlets

# Correct — env var propagated to child process
CONFIG_FILE="$TMPCONFIG" bash "$CONFIGURE" generate-quadlets
```

## Rule
> When a helper script reads a variable with `${VAR:-default}`, the only reliable way to override it from a calling script is to set it in the subprocess environment: `KEY=value bash script.sh`. Writing to a local variable or a file is not sufficient.
