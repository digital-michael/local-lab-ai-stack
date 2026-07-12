<!-- markdownlint-disable MD024 -->
# Traefik — Lessons Learned
**Last Updated:** 2026-07-10

## Purpose
Empirical findings from deploying Traefik in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [Certificate Store Belongs in Dynamic Config](#1-certificate-store-belongs-in-dynamic-config)
2. [Reserved Entrypoint Name: `traefik`](#2-reserved-entrypoint-name-traefik)
3. [Rootless Port Binding Below 1024](#3-rootless-port-binding-below-1024)
4. [File Provider Does Not Support Environment Variable Substitution](#4-file-provider-does-not-support-environment-variable-substitution)
5. [Injecting a Secret Header After SSO — gitignored Dynamic Config File](#5-injecting-a-secret-header-after-sso--gitignored-dynamic-config-file)
6. [SvelteKit `/_app` Background Polling Breaks Under forwardAuth — Bypass Router Required](#6-sveltekit-_app-background-polling-breaks-under-forwardauth--bypass-router-required)
7. [WebSocket Upgrades Cannot Follow forwardAuth 302 Redirects — Bypass Router Required](#7-websocket-upgrades-cannot-follow-forwardauth-302-redirects--bypass-router-required)
8. [Browser HTTP Cache Bypasses forwardAuth — Add `nocache` Middleware](#8-browser-http-cache-bypasses-forwardauth--add-nocache-middleware)

---

# 1 Certificate Store Belongs in Dynamic Config

**Version:** Traefik v3.x  
**Discovered:** 2026-03-08, Phase 7 first-boot

## What Happened
The initial `traefik.yaml` (static config) contained a `certificate.stores` block to define the default TLS certificate:

```yaml
certificate:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/tls/cert.pem
        keyFile: /etc/traefik/tls/key.pem
```

Traefik started without error but silently ignored the block. TLS requests fell back to the built-in self-signed certificate, not the operator-provided one.

## Root Cause
In Traefik v3, `tls.stores` is a **dynamic configuration** object. It must live in the file provider's dynamic directory (e.g. `dynamic/tls.yaml`), not in `traefik.yaml`. Placing it in the static config is a no-op with no warning.

## Fix
Removed the block from `traefik.yaml`. Created `configs/traefik/dynamic/tls.yaml`:

```yaml
tls:
  stores:
    default:
      defaultCertificate:
        certFile: /etc/traefik/tls/cert.pem
        keyFile: /etc/traefik/tls/key.pem
```

## Rule
> In Traefik v3, `tls.stores` and `tls.certificates` are dynamic config. `tls.options` (cipher suites, min version) is static config. Never mix them.

---

# 2 Reserved Entrypoint Name: `traefik`

**Version:** Traefik v3.x  
**Discovered:** 2026-03-08, Phase 7 first-boot

## What Happened
The static config defined a custom entrypoint named `internal` on `:8080` for the dashboard, ping, and metrics. Traefik failed to start with:

```
error while building entryPoint traefik: building listener: error opening listener:
listen tcp :8080: bind: address already in use
```

There was no entrypoint named `traefik` in the config at all.

## Root Cause
When `api.insecure: true` is set, Traefik v3 **automatically creates** an entrypoint named `traefik` on `:8080`. This is a reserved name that the API/dashboard subsystem claims at startup before any user-defined entrypoints are evaluated. The custom `internal` entrypoint also tried to bind `:8080`, causing the conflict.

## Fix
Renamed the custom entrypoint from `internal` to `traefik` in `traefik.yaml`. This aligns the explicit config with what the API subsystem expects and eliminates the duplicate binding.

```yaml
entryPoints:
  traefik:
    address: ":8080"
```

## Rule
> Do not define a custom entrypoint named `traefik`. When using `api.insecure: true`, name your management entrypoint `traefik` to be explicit, or omit the declaration and let Traefik create it automatically.

---

# 3 Rootless Port Binding Below 1024

**Version:** Podman 5.7, Linux kernel default  
**Discovered:** 2026-03-08, Phase 7 first-boot  
**See also:** `podman/lessons_learned.md §1`

## What Happened
Traefik's quadlet publishes ports 80 and 443. The `systemctl --user start traefik.service` command failed immediately with:

```
Error: rootlessport cannot expose privileged port 80, you can add
'net.ipv4.ip_unprivileged_port_start=80' to /etc/sysctl.conf (currently 1024)
```

## Root Cause
Linux defaults restrict ports below 1024 to root. Rootless Podman uses `rootlessport` to forward host ports to container ports, but `rootlessport` obeys the same kernel restriction.

## Fix
```bash
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=80
sudo sh -c 'echo "net.ipv4.ip_unprivileged_port_start=80" > /etc/sysctl.d/99-unprivileged-ports.conf'
```

The `/etc/sysctl.d/` file makes the setting persistent across reboots.

## Rule
> Any rootless Podman deployment that publishes ports 80 or 443 requires `net.ipv4.ip_unprivileged_port_start=80` set at the OS level. This is a host prerequisite, not a container-level fix. Add it to the system validation checklist (`validate-system.sh`).

---

# 4 File Provider Does Not Support Environment Variable Substitution

**Version:** Traefik v3.x  
**Discovered:** 2026-07-10, KI API key injection

## What Happened

When trying to avoid writing a secret to disk, the plan was to mount a Podman secret as an environment variable (`KI_API_KEY`) in the Traefik quadlet and reference it in the dynamic config file:

```yaml
http:
  middlewares:
    ki-api-key:
      headers:
        customRequestHeaders:
          Authorization: "Bearer {{ env "KI_API_KEY" }}"
```

This did not work — Traefik loaded the literal string `{{ env "KI_API_KEY" }}` as the header value.

## Root Cause

Traefik's **static config** (`traefik.yaml`) supports Go template syntax and environment variable expansion. The **file provider** (dynamic config files in `dynamic/`) does not. Dynamic config files are parsed as plain YAML/TOML with no template substitution.

## Fix

Write the resolved value directly into the dynamic config file (gitignored). See §5 for the pattern.

## Rule

> Do not use `{{ env "VAR" }}` or `$VAR` in Traefik dynamic config files — the file provider does not expand them. Only the static `traefik.yaml` supports env var substitution.

---

# 5 Injecting a Secret Header After SSO — gitignored Dynamic Config File

**Version:** Traefik v3.x  
**Discovered:** 2026-07-10, KI browser auth (dual-layer auth gap)

## What Happened

The knowledge-index app requires `Authorization: Bearer <api_key>` on all `/v1/*` and `/admin/v1/*` endpoints regardless of how the request arrives. After Authentik SSO passes (forwardAuth), the browser has an Authentik session cookie but no API key. The app returns 401.

## Pattern

Create a gitignored dynamic config file containing the resolved secret value. Traefik hot-reloads it. The middleware is ordered after forwardAuth so the key is only injected for authenticated requests:

```yaml
# ~/ai-stack/configs/traefik/dynamic/ki-auth.yaml  (gitignored — contains secret)
http:
  middlewares:
    ki-api-key:
      headers:
        customRequestHeaders:
          Authorization: "Bearer <resolved_api_key>"
```

Router middleware order in `services.yaml`:
```yaml
middlewares:
  - authentik    # forwardAuth — must pass first
  - ki-api-key   # inject key only after auth passes
  - secure-headers
```

Generate the file without echoing the secret to stdout:

```bash
KI_KEY=$(podman secret inspect knowledge_index_api_key --showsecret --format '{{.SecretData}}')
printf 'http:\n  middlewares:\n    ki-api-key:\n      headers:\n        customRequestHeaders:\n          Authorization: "Bearer %s"\n' \
    "$KI_KEY" > ~/ai-stack/configs/traefik/dynamic/ki-auth.yaml
```

Add the file to `.gitignore`:

```gitignore
configs/traefik/dynamic/ki-auth.yaml
```

## Rule

> When a backend requires a static bearer token and cannot be modified to trust SSO identity headers, use a gitignored Traefik dynamic config file to inject the token. Order the injection middleware after forwardAuth so only authenticated users receive the injected credential. Regenerate the file after rotating the secret.

---

## 6 SvelteKit `/_app` Background Polling Breaks Under forwardAuth — Bypass Router Required

**Version:** Traefik v3.x / OpenWebUI v0.8.x
**Discovered:** 2026-07-07, Authentik forwardAuth integration

### What Happened

After putting OpenWebUI behind Authentik forwardAuth, the application worked initially but randomly navigated to `https://agent.photondatum.space/error` with "Backend Required". The error appeared ~60 seconds after the Authentik proxy session expired.

### Root Cause

SvelteKit's runtime polls `/_app/version.json` in the background every ~60 seconds to detect app updates. This is a regular `fetch()` call made by JavaScript already running in the browser.

When the Authentik proxy session expires, forwardAuth returns `302` for every request — including this background poll. `fetch()` follows the `302` cross-origin (to `auth.photondatum.space`) → CORS preflight fails (Authentik doesn't emit CORS headers on the redirect response) → `fetch()` rejects → SvelteKit error boundary fires → URL changes to `/error`.

The pattern also repeats for any other background fetch from the SvelteKit app (not just `version.json`).

### Fix

Add a higher-priority Traefik router that matches `/_app` paths and omits the `authentik` middleware:

```yaml
openwebui-public-static:
  rule: "Host(`agent.photondatum.space`) && (PathPrefix(`/_app`) || PathPrefix(`/ws`))"
  entryPoints:
    - websecure
  service: openwebui
  middlewares:
    - secure-headers    # no authentik
  tls: {}
```

The longer rule (`PathPrefix`) wins over the shorter all-paths router, so `/_app` and `/ws` are served without forwardAuth. Authentik still protects all other paths. The `/_app` assets (hashed JS/CSS bundles and `version.json`) carry no secrets.

Traefik hot-reloads the dynamic config — no restart required.

### Rule

> Any SvelteKit (or similar SPA) application behind forwardAuth must have a bypass router for its static asset prefix (`/_app`). Without it, background JavaScript polling on session expiry triggers the error boundary instead of a clean login redirect. The bypass is safe — static assets are immutable hashed files that carry no secrets.

---

## 7 WebSocket Upgrades Cannot Follow forwardAuth 302 Redirects — Bypass Router Required

**Version:** Traefik v3.x / OpenWebUI v0.8.x
**Discovered:** 2026-07-07, debugging streaming chat failures

### What Happened

After enabling forwardAuth on `agent.photondatum.space`, streaming chat responses stopped working. Browser console showed WebSocket connection failures at `wss://agent.photondatum.space/ws/socket.io/`.

### Root Cause

The HTTP → WebSocket upgrade handshake (`GET /ws/... Upgrade: websocket`) is a one-shot request. If forwardAuth returns `302`, the browser does not follow the redirect — the upgrade fails silently and the WebSocket connection is never established.

**Diagnosis**: `curl 'https://agent.photondatum.space/ws/socket.io/?EIO=4&transport=polling'` returned `302` (from Authentik). After the bypass router fix, the same request returned `400` (from OpenWebUI — correctly rejecting an unauthenticated polling attempt).

### Fix

Add `/ws` to the static bypass router alongside `/_app`:

```yaml
rule: "Host(`agent.photondatum.space`) && (PathPrefix(`/_app`) || PathPrefix(`/ws`))"
```

OpenWebUI gates WebSocket connections with its own JWT. The forwardAuth session is not needed for the `/ws` path.

### Rule

> WebSocket upgrade paths must be excluded from forwardAuth routers. The WebSocket upgrade is not a redirectable request — a `302` silently kills the connection. Rely on the application's own token (JWT in query string or header) to authenticate WebSocket sessions.

---

## 8 Browser HTTP Cache Bypasses forwardAuth — Add `nocache` Middleware

**Version:** Traefik v3.x
**Discovered:** 2026-07-11, after akadmin email change invalidated proxy sessions

### What Happened

After an Authentik proxy session expired (24-hour validity), revisiting `agent.photondatum.space` showed "Backend Required" instead of redirecting to Authentik login. The browser's HTTP cache served the cached `index.html` without contacting Traefik, so forwardAuth was never consulted. The cached page loaded the SvelteKit app, which made API calls via the network — those reached Traefik and were `302`'d (no valid session). The cross-origin `302` caused a CORS error → SvelteKit error boundary → `/error`.

### Root Cause

forwardAuth runs on the Traefik router — it only intercepts requests that reach Traefik. If the browser caches the HTML response, future visits serve the cached file directly from the browser disk without a network request. The browser then makes API calls (which are not cached) and those do reach Traefik, but by then there is no valid Authentik session cookie to satisfy forwardAuth.

### Fix

Add a `nocache` Traefik middleware and apply it to every auth-gated router:

```yaml
# middlewares.yaml
nocache:
  headers:
    customResponseHeaders:
      Cache-Control: "no-store, no-cache, must-revalidate"
```

```yaml
# services.yaml — apply to auth-gated routers, NOT to static-asset bypass routers
openwebui-public:
  middlewares:
    - authentik
    - secure-headers
    - nocache
```

Do **not** apply `nocache` to the `/_app` bypass router. Those files are immutable hashed bundles — caching them is safe and desirable.

### Pattern

```text
Without nocache:
  visit /  →  browser cache hit  →  forwardAuth skipped  →  API calls reach Traefik
           →  302 (session expired, cross-origin)  →  CORS error  →  /error

With nocache:
  visit /  →  no cache  →  Traefik  →  forwardAuth  →  302 to Authentik login
           →  user re-authenticates  →  redirect back  →  valid session  →  app loads
```

### Rule

> Every Traefik router that uses forwardAuth must also apply `Cache-Control: no-store` to its responses. Without it, browser caching creates a window where the page loads without auth validation and then breaks when the cached page's API calls reach forwardAuth with an expired session.

### Retraction — Misdiagnosis (2026-07-11)

During an incident where all forwardAuth-gated services looped, `nocache` was suspected as the cause (hypothesis: some browsers suppress cookie storage from `Cache-Control: no-store` redirect responses). `nocache` was removed from `openwebui-public` and `openwebui` routers. The loop persisted.

The actual root cause was a malformed `access_token_validity` value in the Authentik ProxyProvider that crashed the embedded outpost on every token exchange, returning `302` to the original URL with no `Set-Cookie` header (see Authentik lessons §19). `nocache` had no effect on the loop. It was re-added after the root cause was identified and fixed.

The rule above stands — apply `nocache` to all forwardAuth-gated routers.
