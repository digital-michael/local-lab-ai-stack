# Headscale — Security

## Access control

Headscale uses an ACL policy file (`/etc/headscale/acl.json`) to control
inter-node connectivity. By default all enrolled nodes can reach each other.
Restrict this with explicit `acls` and `tagOwners` rules.

Headscale API key (`hskey-api-*`) grants full admin access. Store as a Podman
secret; do not embed in config files tracked by git.

## Headplane

Headplane has no built-in authentication beyond the `cookie_secret`. It should:
- Only listen on the tailnet IP (`host: "100.64.0.5"` in config), never `0.0.0.0`
- Not be exposed through Caddy to the public internet
- Use a randomly generated `cookie_secret` of at least 32 bytes

## STUN port (UDP 3478)

STUN is required for direct peer-to-peer WireGuard connections. It is a minimal
protocol — it responds to binding requests with the caller's public IP. There is
no authentication and no sensitive data transmitted over STUN. Open UDP 3478
inbound on the firewall; it does not require additional hardening.

## Key material

| File | Location | Purpose |
|---|---|---|
| `noise_private.key` | `/var/lib/headscale/` | WireGuard noise key — never expose |
| `derp_server_private.key` | `/var/lib/headscale/` | DERP relay identity — never expose |
| `db.sqlite` | `/var/lib/headscale/` | Node registry, routes, ACL state |

Permissions: `chmod 600` on all key files; `root:root` ownership.
Back up `/var/lib/headscale/` before any Headscale upgrade.

## Network exposure

Headscale itself listens on `127.0.0.1:8080` — not publicly accessible.
Caddy proxies `headscale.photondatum.space:443` → `127.0.0.1:8080`.
Headscale never binds a public port directly.
