# AI Stack — Security Policy

**Status:** Active
**Effective:** 2026-04-07
**Scope:** All services in the AI Stack deployment

---

## 1 Principle

Every service accessible over the network MUST require authentication.
No service endpoint — web UI, API, or dashboard — shall be reachable
without passing through at least one authentication gate.

---

## 2 Authentication Tiers

### Tier 1 — Perimeter (Traefik + Authentik SSO)

All Traefik-routed services MUST include the `authentik` forwardAuth middleware.

**Exceptions (must be individually justified):**
- **Authentik itself** — it IS the identity provider; cannot forwardAuth to itself.

There are **no other exceptions**. Machine-to-machine endpoints (MCP, API)
that cannot use browser-based SSO MUST use API key authentication at the
application level (see Tier 2).

### Tier 2 — Application-Level Auth (Defense in Depth)

Services with built-in authentication keep it enabled as a second gate:

| Service | Native Auth Type |
|---|---|
| OpenWebUI | Built-in user accounts |
| Flowise | Enterprise auth (email/password) |
| LiteLLM | API key (`LITELLM_MASTER_KEY`) |
| Qdrant | API key (`QDRANT__SERVICE__API_KEY`) |
| MinIO | Root user/password |
| Grafana | Admin user/password (or SSO passthrough) |
| Knowledge Index | API key (`API_KEY` secret) |

Services without native auth (Prometheus, Loki, Promtail) have SSO as
their **only** protection. These must never be exposed without Tier 1.

### Tier 3 — Network Binding

Services MUST NOT publish ports to the host unless they require direct
localhost access for operational reasons. This eliminates direct bypass
of the Traefik+Authentik authentication layer entirely.

**Services with published ports (documented exceptions):**

| Service | Port | Bind | Reason |
|---|---|---|---|
| Traefik | 80, 443 | `0.0.0.0` | Designated ingress — the whole point |
| Traefik | 8080 | `127.0.0.1` | Dashboard/API |
| PostgreSQL | 5432 | `127.0.0.1` | `psql` from host for debugging |
| Ollama | 11434 | `127.0.0.1` | `ollama` CLI, local tooling |

All other services have `"ports": []` in config.json and no `PublishPort`
in their quadlet files. They are reachable **only** via Traefik (which
enforces Tier 1) or from other containers on the `ai-stack-net` network.

---

## 3 Credential Management

- All service credentials are stored as Podman secrets.
- Credential values are captured at first deployment to a local file
  (`configs/credentials.local`) which is `.gitignore`d.
- The capture script (`scripts/capture-credentials.sh`) can regenerate
  this file at any time from the running stack.
- Default/weak passwords (e.g., Grafana `admin/admin`) must be rotated
  before any non-localhost exposure.

---

## 4 Compliance Checklist

For every new service added to the stack:

- [ ] Traefik router includes `authentik` middleware (or has documented exception)
- [ ] `PublishPort` binds to `127.0.0.1` (or has documented exception)
- [ ] If the service has native auth, it is enabled and configured
- [ ] Credentials are stored as Podman secrets (not plain env vars)
- [ ] Credentials are captured by `scripts/capture-credentials.sh`
- [ ] Component `security.md` in `docs/library/framework_components/` is updated

---

## 5 Operational Access Model — Configuration vs. Execution

### Principle

**The user who configures a system must not be the same user who owns what runs on it.**

Two distinct access roles must be defined for every deployment:

| Role | Purpose | Lifecycle | Owns containers? |
| --- | --- | --- | --- |
| **Setup user** (e.g. `llmagent`) | Install packages, enable system services, one-time configuration | Temporary — privileges revoked after deployment complete | **No** |
| **Execution owner** (e.g. `3pdx7a`) | Runs rootless Podman; owns all container state, volumes, secrets | Permanent — this is who the containers run as | **Yes** |

### Why this matters

Rootless Podman uses the **real UID** of the process — not the effective UID from `su` or `sudo`. If a setup user runs `su - execution-owner` and then invokes Podman, the kernel-level real UID remains that of the setup user. Podman will look for `/run/user/<setup-uid>`, the wrong subuid ranges, and the wrong user namespace — and fail or run in an incorrect security context.

The execution owner **must** be accessed via a proper login session (direct SSH, console login, or `systemd --user` with linger enabled). There is no shortcut.

### Setup user constraints

- Narrowly privileged: only `sudo dnf`, `sudo systemctl`, and explicit admin scripts — nothing broader
- Does not own any persistent state (no volumes, no Podman secrets, no container images)
- Nothing running in production depends on the setup user's account existing
- Privileges are revoked (or the account locked) once deployment is complete

### Execution owner constraints

- Has a proper login session (SSH key access)
- Owns all Podman container state under their home directory
- Has `subuid`/`subgid` ranges configured in `/etc/subuid` and `/etc/subgid`
- Linger enabled so containers survive logout: `loginctl enable-linger <user>`
- Has `sudo` access only with a **manual password prompt** — never NOPASSWD — so that container escape does not grant silent root escalation

### Instance mapping

| Host | Setup user | Execution owner |
| --- | --- | --- |
| photondatum.space | `llmagent` | `3pdx7a` |
| CENTAURI | TBD | TBD |
| Worker nodes | TBD | TBD |

---

## 6 Backend-Only Services

These services have no user-facing web UI and are not routed through Traefik:

| Service | Access | Protection |
|---|---|---|
| PostgreSQL | Container network only + localhost:5432 | Password auth |
| Ollama | Container network only + localhost:11434 | None (localhost only) |
| Loki | Container network only + localhost:3100 | None (localhost only) |
| Promtail | Container network only (no published port) | Network isolation |
