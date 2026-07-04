# Edge Role

## Purpose

The edge role runs on an always-on, publicly reachable host. It owns three
concerns: identity (who you are), mesh coordination (where nodes are), and
public ingress (what the outside world can reach). All traffic entering
`*.photondatum.space` flows through this role's Caddy instance. Authentik
on this role is the SSO authority for every other service in the stack,
including services running on controller nodes.

**This role must be up for any external access to work.** Controller services
degrade gracefully when this role is offline (they remain reachable on the
LAN/tailnet), but external SSO login fails.

---

## Target Hardware Profile

| Property | Minimum | Recommended |
|---|---|---|
| RAM | 1 GB | 2 GB |
| CPU | 1 vCPU | 2 vCPU |
| Storage | 20 GB | 40 GB |
| Network | Public IPv4 | Public IPv4 + IPv6 |
| Availability | Always-on | Always-on |

PostgreSQL + Redis + Authentik + Headscale together consume ~600–900 MB RAM
at idle. A 1 GB VPS is tight; 2 GB gives headroom for log spikes and future
group additions.

---

## Deployment Groups

### Group: `ai-stack-iam`

Identity and access management. Authentik is the SSO broker for the entire
stack — social login, local accounts, MFA, and OIDC delegation to all services.

**Network:** `ai-stack-iam`
**SystemD target:** `ai-stack-iam.target`

| Container | Image | Purpose |
|---|---|---|
| `ai-stack-iam-authentik` | `ghcr.io/goauthentik/server` | Authentik server (IdP, SSO, OIDC) |
| `ai-stack-iam-authentik-worker` | `ghcr.io/goauthentik/server` | Celery worker (background tasks, outpost sync) |
| `ai-stack-iam-postgres` | `docker.io/library/postgres:16` | Authentik database — not shared |
| `ai-stack-iam-redis` | `docker.io/library/redis:7` | Authentik task queue and cache |

**Volumes:**

| Volume | Mount | Purpose |
|---|---|---|
| `ai-stack-iam-postgres-data` | `/var/lib/postgresql/data` | Persistent database |
| `ai-stack-iam-redis-data` | `/data` | Persistent cache (optional — can be ephemeral) |
| `ai-stack-iam-authentik-media` | `/media` | Authentik static assets, custom branding |
| `ai-stack-iam-authentik-certs` | `/certs` | Authentik managed certificates |

**Startup order within group:**
1. `ai-stack-iam-postgres` + `ai-stack-iam-redis` (parallel)
2. `ai-stack-iam-authentik` (after postgres + redis healthy)
3. `ai-stack-iam-authentik-worker` (after authentik healthy)

**Social login sources (no new containers):**
Configure as OAuth2 sources in Authentik admin → Directory → Federation & Social login:
Google, Microsoft, Apple, GitHub, GitLab, BitBucket, Atlassian, RedHat (OpenShift),
plus any generic OIDC/OAuth2 endpoint. These are Authentik configuration entries,
not deployable containers.

**Outpost configuration:**
The Authentik embedded outpost handles `forward_auth` for Caddy. Set the outpost's
External URL to `https://auth.<domain>` — this is where browsers are redirected on
unauthenticated requests. If this value is wrong (e.g., still `auth.stack.localhost`),
external browsers cannot complete the SSO flow.

---

### Group: `ai-stack-mesh`

Overlay network coordination. Headscale manages the WireGuard mesh; Headplane
provides the admin UI. Tailscale runs as a systemd service on the host (not
containerized — it requires host network namespace access for WireGuard).

**Network:** `host` (Headscale and Headplane require host networking)
**SystemD target:** `ai-stack-mesh.target`

| Container | Image | Purpose |
|---|---|---|
| `ai-stack-mesh-headscale` | `ghcr.io/juanfont/headscale` | Coordination server + embedded DERP relay |
| `ai-stack-mesh-headplane` | `ghcr.io/tale/headplane` | Headscale web admin UI |

**Host services (not containerized):**
| Service | Manager | Notes |
|---|---|---|
| `tailscale` | systemd | WireGuard mesh agent; host network required |

**Volumes:**
| Volume | Mount | Purpose |
|---|---|---|
| (bind) `/var/lib/headscale` | `/var/lib/headscale` | Headscale DB, keys, state |
| (bind) `/etc/headscale` | `/etc/headscale` | Headscale config, ACL |

**Critical Headscale config requirements:**
- `derp.server.enabled: true` — disabled by default; `/derp` returns HTML when off
- `derp.server.private_key_path` — required when enabled; Headscale fails to start without it
- `server_url` — must be actual domain (`https://headscale.<domain>`), not a placeholder
- `derp.paths: []` — required empty; a loaded `derp.yaml` with matching `region_id` causes conflict
- Verify relay: `curl http://127.0.0.1:8080/derp/probe` must return `DERP ALIVE`

**Port requirements:**
| Port | Protocol | Purpose |
|---|---|---|
| 443 | TCP | Headscale (proxied by Caddy) |
| 3478 | UDP | STUN — Caddy cannot proxy UDP; firewall must allow |

---

### Group: `ai-stack-edge`

Public ingress and static hosting. Caddy terminates TLS, handles HTTPS redirects,
and enforces `forward_auth` against Authentik for protected routes. Forgejo is
external to this stack (native systemd, not a container) but passes auth to
Authentik via OIDC.

**Network:** `host` (Caddy binds :80/:443)
**SystemD target:** `ai-stack-edge.target`

| Container | Image | Purpose |
|---|---|---|
| `ai-stack-edge-caddy` | `docker.io/library/caddy:2` | TLS termination, public reverse proxy, forward_auth |

**External services (not containerized, not managed by this role):**
| Service | Auth integration |
|---|---|
| Forgejo | OIDC source configured in Forgejo admin → Authentication Sources; delegates to `ai-stack-iam-authentik` |

**Caddy patterns:**
1. Static site: `root * /var/www/<site>` + `file_server`
2. Reverse proxy: `reverse_proxy <upstream>` — Caddy handles TLS automatically
3. Protected route: `forward_auth ai-stack-iam-authentik:9000 { ... }` before `reverse_proxy`
4. Headscale: requires `transport http { versions 1.1 }` and `tls { alpn http/1.1 }` due to HTTP/2 DERP incompatibility

---

## Network Topology

### Isolated mode (default)

Each group has its own Podman network. Services within a group communicate by
container name. Cross-group traffic (e.g., Caddy calling Authentik for `forward_auth`)
requires the calling container to join the target group's network or route via the host.

```
[internet] → ai-stack-edge-caddy (host net)
                │ forward_auth
                ▼
         ai-stack-iam-authentik (ai-stack-iam net)
```

Caddy on `host` network can reach Authentik on `ai-stack-iam` if the Authentik
container publishes its port to the host (e.g., `PublishPort=127.0.0.1:9000:9000`).
Alternatively, add Caddy to the `ai-stack-iam` network (multi-network container).

### Combined mode (instance override)

All groups share a single `ai-stack` network. All containers can reach each other
by container name. Suitable for resource-constrained hosts where network overhead
matters or where fewer moving parts is preferred.

Instance overlay sets `Network=ai-stack` on all containers instead of group-specific networks.

---

## Startup Order

```
1. ai-stack-iam-postgres    │ parallel
   ai-stack-iam-redis       │
2. ai-stack-iam-authentik
3. ai-stack-iam-authentik-worker
4. ai-stack-mesh-headscale  │ parallel (no iam dependency)
   ai-stack-mesh-headplane  │
5. ai-stack-edge-caddy      │ parallel (no iam dependency at boot;
                             │ forward_auth fails gracefully until iam is ready)
```

SystemD target for full role: `ai-stack-edge-role.target`
(Wants= all group targets above)

---

## Pre-Deployment Checklist

- [ ] Public IPv4 DNS A records: `headscale.<domain>`, `auth.<domain>`, `git.<domain>`, `*.photondatum.space`
- [ ] Firewall: TCP 80, 443 open inbound; UDP 3478 open inbound (STUN)
- [ ] Firewall: no conflicting service on UDP 3478 (`ss -ulnp | grep :3478`)
- [ ] Headscale `server_url` set to actual domain (not placeholder)
- [ ] Headscale `private_key_path` set under `derp.server`
- [ ] Authentik outpost External URL set to `https://auth.<domain>`
- [ ] PostgreSQL: dedicated instance, not shared with LLM stack
- [ ] Redis: accessible to both `ai-stack-iam-authentik` and `ai-stack-iam-authentik-worker`

---

## Instance Customization

Instance overlay documents (in `docs/instances/`) provide:

| Setting | Instance override |
|---|---|
| Domain names | `photondatum.space`, tailnet base domain |
| Node IP addresses | Tailnet IPs, public IPs |
| Network mode | isolated vs combined |
| Caddy routes | Per-instance vhosts and upstream targets |
| Headscale ACL | Per-deployment ACL policy |
| Authentik social sources | Which providers are configured |
| Resource limits | `--cpus`, `--memory` per container |

See: [docs/instances/photondatum.md](../instances/photondatum.md)
