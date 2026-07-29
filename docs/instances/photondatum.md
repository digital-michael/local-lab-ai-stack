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

All additional `*.photondatum.space` subdomains for CENTAURI services are also
pointed at this VPS — Caddy proxies them through to CENTAURI via tailnet.

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
| `ai-stack-iam-authentik-worker` | none | `--cpus=0.5 --memory=256m` |
| `ai-stack-iam-postgres` | `127.0.0.1:5432:5432` | `--cpus=0.5 --memory=256m` |
| `ai-stack-iam-redis` | `127.0.0.1:6379:6379` | `--cpus=0.25 --memory=128m` |

**Authentik outpost External URL:** `https://auth.photondatum.space`

**Social login sources to configure in Authentik admin:**
- GitHub (OAuth2)
- Google (OAuth2)
- Microsoft (OAuth2)
- GitLab (OAuth2)
- (others as needed — each is a config entry, not a new container)

**Forgejo + Authentik:**
Forgejo is a native systemd service on this host (not a container, not managed
by the ai-stack group system). Configure Authentik as an OIDC source in
Forgejo admin → Site Administration → Authentication Sources → Add OAuth2.
Forgejo keeps its own SQLite database; Authentik handles identity only.

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
https://chat.photondatum.space {
    reverse_proxy 100.64.0.4:443 {
        header_up Host chat.photondatum.space
        transport http { tls_insecure_skip_verify }
    }
    handle_errors {
        respond "AI Stack is currently offline" 503
    }
}
```

Additional CENTAURI service routes (flowise, grafana, etc.) follow the same
pattern as `chat.photondatum.space` — proxy to `100.64.0.4:443` with
`header_up Host <service>.photondatum.space`.

---

## Firewall Requirements

| Port | Protocol | Direction | Reason |
|---|---|---|---|
| 80 | TCP | inbound | Caddy HTTP→HTTPS redirect |
| 443 | TCP | inbound | Caddy HTTPS |
| 3478 | UDP | inbound | Headscale STUN (Caddy cannot proxy UDP) |

Check: `sudo firewall-cmd --list-ports` or `sudo nft list ruleset`

---

## Services NOT Managed by This Instance

| Service | Managed by | Location |
|---|---|---|
| Forgejo | systemd (native) | `/etc/systemd/system/forgejo.service` |
| Headplane | systemd (native) | `/etc/systemd/system/headplane.service` |
| Tailscale | systemd (native) | `/etc/systemd/system/tailscaled.service` |
| Caddy | systemd (native) | `/etc/systemd/system/caddy.service` |

These are not containerized on this host. Manage them via `systemctl` directly.

---

## Operational Notes

- Headplane config: `/etc/headplane/config.yaml` (port 3001, not 3000)
- Headscale config: `/etc/headscale/config.yaml`
- Headscale ACL: `/etc/headscale/acl.json`
- Forgejo data: `/var/lib/forgejo/`
- Caddy config reload (no restart needed): `sudo systemctl reload caddy`
- Headscale restart required (no reload): `sudo systemctl restart headscale`
