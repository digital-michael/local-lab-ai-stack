# Caddy — Security

## TLS

Caddy manages Let's Encrypt certificates automatically. Certificates renew 30 days
before expiry. Check expiry: `sudo caddy certificate list` or review Caddy logs.

## forward_auth for Authentik

When protecting routes with Authentik `forward_auth`, copy only the headers you need.
Do not copy `Authorization` unless the backend explicitly requires it.

```caddy
forward_auth ai-stack-iam-authentik:9000 {
    uri /outpost.goauthentik.io/auth/caddy
    copy_headers X-Authentik-Username X-Authentik-Groups X-Authentik-Email
}
```

The outpost External URL in Authentik admin must be `https://auth.photondatum.space` —
if it is set to a LAN-only address, external browsers cannot complete the SSO redirect.

## tls_insecure_skip_verify

Only used when proxying to Traefik on CENTAURI, which uses a self-signed certificate.
This is acceptable for LAN/tailnet traffic where the network itself is trusted (WireGuard).
Do not use `tls_insecure_skip_verify` for any public-internet upstream.

## Headers

Add a `header` block to downstream responses to prevent clickjacking and info leakage:
```caddy
header {
    X-Frame-Options DENY
    X-Content-Type-Options nosniff
    Referrer-Policy strict-origin-when-cross-origin
    -Server
}
```

## Port exposure

Caddy binds `:80` and `:443` publicly. No other service should bind these ports.
Firewall rule: allow TCP 80 and 443 inbound; all other ports should be closed to
the public internet except UDP 3478 (Headscale STUN).
