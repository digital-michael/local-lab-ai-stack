# Caddy — Lessons Learned

**Last Updated:** 2026-07-20

## Purpose

Empirical findings from operating Caddy in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations.

---

## Table of Contents

1. [Caddy Overwrites X-Forwarded-Host When Proxying forwardAuth](#1-caddy-overwrites-x-forwarded-host-when-proxying-forwardauth)
2. [`header_up Host` Must Match the Traefik Router Rule Hostname Exactly](#2-header_up-host-must-match-the-traefik-router-rule-hostname-exactly)
3. [No `dial_timeout` or Access Logging Left an "Offline" Incident Undiagnosable](#3-no-dial_timeout-or-access-logging-left-an-offline-incident-undiagnosable)

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

---

## 2 `header_up Host` Must Match the Traefik Router Rule Hostname Exactly

**Version:** Caddy 2.x, Traefik 3.x
**Discovered:** 2026-07-11, Flowise external access debugging

`https://flowise.photondatum.space` returned 404 from Traefik. The Caddy block
had `header_up Host flowise.stack.localhost` — but Traefik's `flowise-public`
router matches `Host('flowise.photondatum.space')`. No router matched the
wrong hostname, so Traefik returned 404. Fix: set `header_up Host` to the
public hostname that Traefik expects:

```caddy
https://flowise.photondatum.space {
    reverse_proxy 100.64.0.4:443 {
        header_up Host flowise.photondatum.space
        ...
    }
}
```

> For every Caddy block that proxies to CENTAURI Traefik, `header_up Host`
> must match the hostname in the corresponding Traefik router's `rule:` exactly.
> Traefik routes by `Host` header — if it doesn't match a router rule, the
> request returns 404 regardless of the original URL the browser used.

---

## 3 No `dial_timeout` or Access Logging Left an "Offline" Incident Undiagnosable

**Version:** Caddy 2.x
**Discovered:** 2026-07-20, investigating a reported delay on `agent.photondatum.space`

### What Happened

A user reported hitting `agent.photondatum.space` and getting the
`handle_errors` "AI Stack is currently offline" fallback for about two minutes,
even though CENTAURI was awake and `tailscale status` on the VPS showed it
reachable. By the time the report reached investigation, there was no way to
confirm what actually failed: `/etc/caddy/Caddyfile` had no `log` directive on
any site block, so Caddy emitted zero per-request access log lines — only its
own internal admin/TLS/ACME logs reached `journalctl -u caddy`. A month of
those internal logs contained no dial-failure entries for `100.64.0.4:443`
either, so the CENTAURI-proxied `reverse_proxy` blocks also had no explicit
`dial_timeout` — if a request ever does hang on a dead/asleep peer, nothing
bounds how long Caddy waits before falling through to `handle_errors`.

### Fix

Add `log` (per-request JSON access log, timestamp + duration + status + error)
and `transport http { dial_timeout 5s }` to every CENTAURI-proxied block:

```caddy
https://agent.photondatum.space {
    reverse_proxy 100.64.0.4:443 {
        header_up Host agent.photondatum.space
        transport http {
            tls_insecure_skip_verify
            dial_timeout 5s
        }
    }
    log
    handle_errors {
        respond "AI Stack is currently offline. Services will resume when the controller comes back online." 503
    }
}
```

Validate before reloading production: `caddy validate --config /etc/caddy/Caddyfile`.

### Rule

> A `handle_errors` fallback that silently swallows the underlying failure is
> not enough — without `log`, a real incident leaves no timestamped evidence on
> either side of the proxy, and without `dial_timeout`, a hung connection to a
> dead upstream has no bound. Add both to any `reverse_proxy` block whose
> upstream can legitimately go offline (a suspend/wake node, a worker that
> comes and goes), before the first incident, not after.

Active health checks (`health_uri`) were deliberately not added in this pass —
each backend app needs a verified no-auth probe path first (OpenWebUI has one:
`/_app/version.json`, bypasses forwardAuth), and a wrong path would falsely
mark a healthy CENTAURI down. Fast-follow once the other apps' probe paths are
confirmed.
