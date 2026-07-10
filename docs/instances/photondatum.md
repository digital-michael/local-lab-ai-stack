# Instance: photondatum.space

**Role:** [Edge Role](../roles/edge-role.md)
**Hostname:** photondatum.space (Linode VPS)
**Tailnet IP:** 100.64.0.5
**Network mode:** combined (`ai-stack` — single shared network; lower-powered host)

---

## Identity

| Property | Value |
|---|---|
| Public domain | `photondatum.space` |
| Tailnet base domain | `tailnet.photondatum.space` |
| Headscale URL | `https://headscale.photondatum.space` |
| Authentik URL | `https://auth.photondatum.space` |
| Forgejo URL | `https://git.photondatum.space` |
| Headplane URL | `http://100.64.0.5:3001` (tailnet only) |

---

## DNS Records

| Hostname | Type | Target | Purpose |
|---|---|---|---|
| `photondatum.space` | A | VPS public IP | Root site |
| `mail.photondatum.space` | A | VPS public IP | Mail-related static page |
| `headscale.photondatum.space` | A | VPS public IP | Headscale coordination + DERP |
| `auth.photondatum.space` | A | VPS public IP | Authentik SSO |
| `git.photondatum.space` | A | VPS public IP | Forgejo git hosting |
| `agent.photondatum.space` | A | VPS public IP | OpenWebUI (AI agent interface) |
| `chat.photondatum.space` | A | VPS public IP | Reserved — future social chat |
| `dashboard.photondatum.space` | A | VPS public IP | CENTAURI stack homepage dashboard |
| `flowise.photondatum.space` | A | VPS public IP | Flowise AI workflow builder (bundle-admin) |

All `*.photondatum.space` subdomains point at this VPS — Caddy proxies
CENTAURI-hosted services through to `100.64.0.4:443` via tailnet.

---

## Network Mode Override

This instance uses **combined mode**: all containers share the single `ai-stack` network.

Reason: The Linode VPS has limited RAM (1–2 GB). Isolated Podman networks add
overhead per network namespace. Combined mode reduces that cost at the expense
of inter-group isolation — acceptable for a single-owner deployment.

```ini
# All container quadlets on this host use:
Network=ai-stack
```

---

## Group: `ai-stack-iam` — Instance Values

| Container | Port bind | Resource limits |
|---|---|---|
| `ai-stack-iam-authentik` | `127.0.0.1:9000:9000`, `127.0.0.1:9443:9443` | `--cpus=1 --memory=512m` |
| `ai-stack-iam-authentik-worker` | none | `--cpus=0.5 --memory=512m` |
| `ai-stack-iam-postgres` | `127.0.0.1:5432:5432` | `--cpus=0.5 --memory=256m` |
| `ai-stack-iam-redis` | `127.0.0.1:6379:6379` | `--cpus=0.25 --memory=128m` |

**Authentik outpost External URL:** `https://auth.photondatum.space`

**Social login sources configured:**

- GitHub (slug: `github`) — OAuth2, configured
- Google (slug: `google`) — OAuth2, configured
- GitLab (slug: `gitlab`) — OAuth2, configured
- Microsoft — skipped (requires Azure portal; add later if needed)
- BitBucket — not supported in this Authentik version

**Forgejo + Authentik OIDC:**
Forgejo is a native systemd service on this host (not a container). Authentik
acts as an OIDC source — Forgejo authenticates users against Authentik, not the
reverse (no forwardAuth on Forgejo).

Authentik OAuth2 provider `Forgejo (Git)` (pk=2):
- `client_id`: `0LAu1ulhUacuK0ApS73LCwjCsQxLhMJrEi98sjHv`
- `redirect_uri`: `https://git.photondatum.space/user/oauth2/Authentik/callback`
- Discovery URL: `https://auth.photondatum.space/application/o/forgejo/.well-known/openid-configuration`
- Policy: `access-forgejo` (bundle-developer, bundle-admin, superuser)

To complete the connection, add the auth source in Forgejo admin UI:
**`https://git.photondatum.space/-/admin/auths/new`**

| Field | Value |
|---|---|
| Authentication Type | OAuth2 |
| Authentication Name | `Authentik` |
| OAuth2 Provider | OpenID Connect |
| Client ID | `0LAu1ulhUacuK0ApS73LCwjCsQxLhMJrEi98sjHv` |
| Client Secret | Copy from Authentik admin → Applications → Forgejo (Git) → Edit |
| OpenID Connect URL | `https://auth.photondatum.space/application/o/forgejo/.well-known/openid-configuration` |

After adding the source, to restrict local logins to admin only, add to `/etc/forgejo/app.ini`:
```ini
[service]
ALLOW_ONLY_EXTERNAL_SELF_REGISTRATION = true
```

The planned `forgejo-guest` group (read-only, public repos, no forks) is a
Forgejo-side group permission setting — no Authentik changes needed for it.

---

## Group: `ai-stack-mesh` — Instance Values

| Service | Listen | Notes |
|---|---|---|
| `ai-stack-mesh-headscale` | `127.0.0.1:8080` (HTTP via Caddy) | STUN UDP 3478 direct |
| `ai-stack-mesh-headplane` | `100.64.0.5:3001` | Tailnet only; Forgejo conflict avoided by port 3001 |
| Tailscale daemon | systemd | Tailnet IP: `100.64.0.5` |

**DERP configuration:**
- `derp.server.enabled: true`
- `derp.server.region_id: 900`
- `derp.server.private_key_path: /var/lib/headscale/derp_server_private.key`
- `derp.paths: []` — do not load `derp.yaml` (region conflict)
- `server_url: https://headscale.photondatum.space`
- `dns.base_domain: tailnet.photondatum.space`

Verify: `curl http://127.0.0.1:8080/derp/probe` → `DERP ALIVE`

**Port conflict note:** Forgejo binds `0.0.0.0:3000`. Headplane must use port 3001
(configured in `/etc/headplane/config.yaml` — not a container; native install on this host).

---

## Group: `ai-stack-edge` — Instance Values: Caddy Routes

Live Caddyfile at `/etc/caddy/Caddyfile` on this host. Caddy is a native
systemd service (not a container) on this host.

```caddy
# Root site
photondatum.space {
    root * /var/www/photondatum
    file_server
}

# Mail static page
mail.photondatum.space {
    root * /var/www/photondatum
    file_server
}

# Headscale — requires HTTP/1.1 only (DERP uses WebSocket upgrade, not HTTP/2)
https://headscale.photondatum.space {
    tls { alpn http/1.1 }
    reverse_proxy 127.0.0.1:8080 {
        transport http { versions 1.1 }
    }
}

# Forgejo (native service, port 3000)
git.photondatum.space {
    reverse_proxy 127.0.0.1:3000
}

# Authentik
https://auth.photondatum.space {
    reverse_proxy 127.0.0.1:9000
}

# CENTAURI services — proxied via tailnet (100.64.0.4)
# These routes are only reachable when CENTAURI is online
https://agent.photondatum.space {
    reverse_proxy 100.64.0.4:443 {
        header_up Host agent.photondatum.space
        transport http { tls_insecure_skip_verify }
    }
    handle_errors {
        respond "AI Stack is currently offline. Services will resume when the controller comes back online." 503
    }
}

# Chat portal — reserved for future social chat (Mattermost)
chat.photondatum.space {
    root * /var/www/photondatum
    file_server
}

# Homepage dashboard — CENTAURI stack dashboard
https://dashboard.photondatum.space {
    reverse_proxy 100.64.0.4:443 {
        header_up Host dashboard.stack.localhost
        transport http { tls_insecure_skip_verify }
    }
}
```

Additional CENTAURI service routes follow the same pattern — proxy to
`100.64.0.4:443` with `header_up Host <service>.stack.localhost`:

```caddy
# Flowise — AI workflow builder (bundle-admin only, via Authentik forwardAuth)
https://flowise.photondatum.space {
    reverse_proxy 100.64.0.4:443 {
        header_up Host flowise.stack.localhost
        transport http { tls_insecure_skip_verify }
    }
}
```

---

## Firewall Requirements

| Port | Protocol | Direction | Reason |
|---|---|---|---|
| 80 | TCP | inbound | Caddy HTTP→HTTPS redirect |
| 443 | TCP | inbound | Caddy HTTPS |
| 3478 | UDP | inbound | Headscale STUN (Caddy cannot proxy UDP) |
| 21115 | TCP | inbound | RustDesk hbbs — NAT type test |
| 21116 | TCP+UDP | inbound | RustDesk hbbs — rendezvous + hole-punch |
| 21117 | TCP | inbound | RustDesk hbbr — relay |
| 21118 | TCP | inbound | RustDesk hbbs — WebSocket |
| 21119 | TCP | inbound | RustDesk hbbr — relay WebSocket |

Check: `sudo firewall-cmd --list-ports` or `sudo nft list ruleset`

---

## Services NOT Managed by the ai-stack Group System

### Native systemd (non-containerized)

| Service | Managed by | Location |
|---|---|---|
| Forgejo | systemd (native) | `/etc/systemd/system/forgejo.service` |
| Headplane | systemd (native) | `/etc/systemd/system/headplane.service` |
| Tailscale | systemd (native) | `/etc/systemd/system/tailscaled.service` |
| Caddy | systemd (native) | `/etc/systemd/system/caddy.service` |

Manage these via `systemctl` directly.

### RustDesk (podman-compose, 3pdx7a user)

RustDesk self-hosted server runs as two containers (`hbbs` + `hbbr`) managed by
`podman-compose`, not by ai-stack quadlets. It uses `network_mode: host` because
RustDesk uses non-HTTP ports that cannot route through Podman container networking.

| Property | Value |
|---|---|
| Version | `1.1.15` |
| Image | `docker.io/rustdesk/rustdesk-server:1.1.15` |
| Compose file | `configs/compose/rustdesk/docker-compose.yml` (repo) |
| Working dir | `/home/3pdx7a/rustdesk-server/` (VPS) |
| Managed by | `podman-compose@rustdesk-server.service` (user unit) |
| Web UI | None — standard image has no web UI |
| Auth | Keypair (`-k _`); public key stored in `./data/`, share with clients |

**Key-pair setup:** On first start, `hbbs` generates a keypair stored in
`./data/`. To display the public key: `podman exec rustdesk-hbbs cat /root/id_ed25519.pub`
Share this key with RustDesk clients under Settings → Network → Key.

**No Authentik protection possible** for relay endpoints (non-HTTP protocol).
Any future RustDesk web UI (third-party) should be placed behind Authentik
using `bundle-admin` or higher.

---

## Operational Notes

- Headplane config: `/etc/headplane/config.yaml` (port 3001, not 3000)
- Headscale config: `/etc/headscale/config.yaml`
- Headscale ACL: `/etc/headscale/acl.json`
- Forgejo data: `/var/lib/forgejo/`
- Caddy config reload (no restart needed): `sudo systemctl reload caddy`
- Headscale restart required (no reload): `sudo systemctl restart headscale`
