# Traefik — Lessons Learned
**Last Updated:** 2026-03-08 UTC

## Purpose
Empirical findings from deploying Traefik in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [Certificate Store Belongs in Dynamic Config](#1-certificate-store-belongs-in-dynamic-config)
2. [Reserved Entrypoint Name: `traefik`](#2-reserved-entrypoint-name-traefik)
3. [Rootless Port Binding Below 1024](#3-rootless-port-binding-below-1024)

---

# 1 Certificate Store Belongs in Dynamic Config

**Version:** Traefik v3.x  
**Discovered:** 2026-03-08, Phase 7 first-boot

## What Happened
The initial `traefik.yaml` (static config) contained a `certificate.stores` block to define the default TLS certificate:

```yaml
certificate:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/tls/cert.pem
        keyFile: /etc/traefik/tls/key.pem
```

Traefik started without error but silently ignored the block. TLS requests fell back to the built-in self-signed certificate, not the operator-provided one.

## Root Cause
In Traefik v3, `tls.stores` is a **dynamic configuration** object. It must live in the file provider's dynamic directory (e.g. `dynamic/tls.yaml`), not in `traefik.yaml`. Placing it in the static config is a no-op with no warning.

## Fix
Removed the block from `traefik.yaml`. Created `configs/traefik/dynamic/tls.yaml`:

```yaml
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/tls/cert.pem
        keyFile: /etc/traefik/tls/key.pem
```

## Rule
> In Traefik v3, `tls.stores` and `tls.certificates` are dynamic config. `tls.options` (cipher suites, min version) is static config. Never mix them.

---

# 2 Reserved Entrypoint Name: `traefik`

**Version:** Traefik v3.x  
**Discovered:** 2026-03-08, Phase 7 first-boot

## What Happened
The static config defined a custom entrypoint named `internal` on `:8080` for the dashboard, ping, and metrics. Traefik failed to start with:

```
error while building entryPoint traefik: building listener: error opening listener:
listen tcp :8080: bind: address already in use
```

There was no entrypoint named `traefik` in the config at all.

## Root Cause
When `api.insecure: true` is set, Traefik v3 **automatically creates** an entrypoint named `traefik` on `:8080`. This is a reserved name that the API/dashboard subsystem claims at startup before any user-defined entrypoints are evaluated. The custom `internal` entrypoint also tried to bind `:8080`, causing the conflict.

## Fix
Renamed the custom entrypoint from `internal` to `traefik` in `traefik.yaml`. This aligns the explicit config with what the API subsystem expects and eliminates the duplicate binding.

```yaml
entryPoints:
  traefik:
    address: ":8080"
```

## Rule
> Do not define a custom entrypoint named `traefik`. When using `api.insecure: true`, name your management entrypoint `traefik` to be explicit, or omit the declaration and let Traefik create it automatically.

---

# 3 Rootless Port Binding Below 1024

**Version:** Podman 5.7, Linux kernel default  
**Discovered:** 2026-03-08, Phase 7 first-boot  
**See also:** `podman/lessons_learned.md §1`

## What Happened
Traefik's quadlet publishes ports 80 and 443. The `systemctl --user start traefik.service` command failed immediately with:

```
Error: rootlessport cannot expose privileged port 80, you can add
'net.ipv4.ip_unprivileged_port_start=80' to /etc/sysctl.conf (currently 1024)
```

## Root Cause
Linux defaults restrict ports below 1024 to root. Rootless Podman uses `rootlessport` to forward host ports to container ports, but `rootlessport` obeys the same kernel restriction.

## Fix
```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
sudo sh -c 'echo "net.ipv4.ip_unprivileged_port_start=80" > /etc/sysctl.d/99-unprivileged-ports.conf'
```

The `/etc/sysctl.d/` file makes the setting persistent across reboots.

## Rule
> Any rootless Podman deployment that publishes ports 80 or 443 requires `net.ipv4.ip_unprivileged_port_start=80` set at the OS level. This is a host prerequisite, not a container-level fix. Add it to the system validation checklist (`validate-system.sh`).
