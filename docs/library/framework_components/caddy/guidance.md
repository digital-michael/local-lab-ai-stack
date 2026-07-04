# Caddy — Guidance

Caddy is the public edge reverse proxy on the edge role (photondatum.space). It
handles TLS termination, HTTP→HTTPS redirects, and `forward_auth` for Authentik
SSO enforcement. Traefik handles internal routing on controller nodes; these two
are not duplicates — they serve different layers.

## Role in the stack

- **Edge layer**: Caddy faces the public internet, terminates TLS for `*.photondatum.space`
- **Internal layer**: Traefik handles `*.stack.localhost` on controller nodes
- Caddy proxies CENTAURI services via the tailnet (e.g., `100.64.0.4:443`)

## Key directives

**Static file serving:**
```caddy
photondatum.space {
    root * /var/www/photondatum
    file_server
}
```

**Reverse proxy:**
```caddy
chat.photondatum.space {
    reverse_proxy 100.64.0.4:443 {
        header_up Host chat.photondatum.space
        transport http { tls_insecure_skip_verify }
    }
}
```

**Headscale (HTTP/1.1 required — DERP is incompatible with HTTP/2):**
```caddy
https://headscale.photondatum.space {
    tls { alpn http/1.1 }
    reverse_proxy 127.0.0.1:8080 {
        transport http { versions 1.1 }
    }
}
```

**Authentik forward_auth (future — when protected routes are added):**
```caddy
service.photondatum.space {
    forward_auth ai-stack-iam-authentik:9000 {
        uri /outpost.goauthentik.io/auth/caddy
        copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email
    }
    reverse_proxy <backend>
}
```

## Automatic TLS

Caddy obtains and renews Let's Encrypt certificates automatically for all
site blocks with valid public DNS records. No manual cert management needed.
TLS data is stored in `/var/lib/caddy/.local/share/caddy/`.

## Config reload vs restart

```bash
sudo systemctl reload caddy      # hot reload — no downtime
sudo systemctl restart caddy     # full restart — brief downtime
```

Prefer `reload` for Caddyfile changes. Restart only after binary upgrade.
