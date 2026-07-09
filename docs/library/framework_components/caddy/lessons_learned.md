# Caddy — Lessons Learned

**Last Updated:** 2026-07-09

## Purpose

Empirical findings from operating Caddy in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations.

---

## Table of Contents

1. [Caddy Overwrites X-Forwarded-Host When Proxying forwardAuth](#1-caddy-overwrites-x-forwarded-host-when-proxying-forwardauth)

---

## 1 Caddy Overwrites X-Forwarded-Host When Proxying forwardAuth

**Version:** Caddy 2.x
**Discovered:** 2026-07-09, Authentik forwardAuth wiring

### What Happened

Traefik on CENTAURI calls Authentik's forwardAuth endpoint at
`https://auth.photondatum.space/outpost.goauthentik.io/auth/traefik`. Traefik
includes `X-Forwarded-Host: agent.photondatum.space` to tell Authentik which
service the user is trying to reach.

Caddy on the VPS proxies this request to the local Authentik container. Despite
the `X-Forwarded-Host` header being present in the incoming request, Authentik
returned 404 ("Not Found") for all forwardAuth checks — even for hosts
registered as proxy providers.

Testing the same request directly against Authentik on port 9000 (bypassing
Caddy) returned the expected 302 redirect to login.

### Root Cause

Caddy's `reverse_proxy` directive rewrites `X-Forwarded-Host` to its own
incoming `Host` value (`auth.photondatum.space`) when forwarding requests
upstream. The Authentik embedded outpost uses `X-Forwarded-Host` to match the
request to a registered proxy provider. With the header overwritten, no
provider matched and the outpost returned 404.

### Fix

Add an explicit `header_up` directive to the Authentik Caddy block to pass
the original `X-Forwarded-Host` value through:

```caddy
https://auth.photondatum.space {
    reverse_proxy 127.0.0.1:9000 {
        header_up X-Forwarded-Host {http.request.header.X-Forwarded-Host}
    }
}
```

`{http.request.header.X-Forwarded-Host}` evaluates to the value of the
`X-Forwarded-Host` header received by Caddy from the upstream caller (Traefik).
If the header is absent, the value is empty and Caddy sends no header —
acceptable since direct browser requests to `auth.photondatum.space` do not
include `X-Forwarded-Host`.

### Rule

> When Caddy sits between an upstream forwardAuth caller (Traefik) and
> Authentik, always add `header_up X-Forwarded-Host {http.request.header.X-Forwarded-Host}`
> to the Authentik proxy block. Without it, Caddy overwrites the header and
> the Authentik outpost cannot identify which application is being accessed.
