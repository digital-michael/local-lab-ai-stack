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

## 5 Backend-Only Services

These services have no user-facing web UI and are not routed through Traefik:

| Service | Access | Protection |
|---|---|---|
| PostgreSQL | Container network only + localhost:5432 | Password auth |
| Ollama | Container network only + localhost:11434 | None (localhost only) |
| Loki | Container network only + localhost:3100 | None (localhost only) |
| Promtail | Container network only (no published port) | Network isolation |
