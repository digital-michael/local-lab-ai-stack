# OpenWebUI — Lessons Learned
**Last Updated:** 2026-07-11

## Purpose
Empirical findings from deploying OpenWebUI in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [`WEBUI_AUTH_TRUSTED_EMAIL_HEADER` — How Auto-Login Works](#1-webui_auth_trusted_email_header--how-auto-login-works)
2. [`Open WebUI Backend Required` at `/error` — What It Means](#2-open-webui-backend-required-at-error--what-it-means)
3. [Browser Cache Can Bypass forwardAuth — Fix with `nocache` Middleware](#3-browser-cache-can-bypass-forwardauth--fix-with-nocache-middleware)
4. [`WEBUI_AUTH_TRUSTED_EMAIL_HEADER` Requires the Header on Every `/signin` — Including the Auto-Triggered POST](#4-webui_auth_trusted_email_header-requires-the-header-on-every-signin--including-the-auto-triggered-post)
5. [SvelteKit `/_app/version.json` Background Poll Gets 302'd — Use Bypass Router](#5-sveltekit-_appversionjson-background-poll-gets-302d--use-bypass-router)
6. [WebSocket Upgrades Cannot Follow 302 Redirects — Use `/ws` Bypass Router](#6-websocket-upgrades-cannot-follow-302-redirects--use-ws-bypass-router)
7. [`enable_signup=false` Does Not Block Trusted-Header Auto-Provisioning](#7-enable_signupfalse-does-not-block-trusted-header-auto-provisioning)

---

## 1 `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` — How Auto-Login Works

**Version:** OpenWebUI v0.8.10
**Discovered:** 2026-07-10, Authentik SSO integration

### What Happened

Setting `WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-authentik-email` was expected to automatically log users in. We needed to understand the exact mechanism to debug failures.

### Mechanism

1. The `/api/config` endpoint returns `"features": {"auth_trusted_header": true}` when the env var is set.
2. The SvelteKit frontend reads this on mount of the `/auth` page and immediately calls `POST /api/v1/auths/signin` with an empty body `{"email": "", "password": ""}` (the body is ignored by the backend).
3. The POST goes through Traefik → forwardAuth (Authentik validates the proxy session) → Authentik injects `X-authentik-email: <email>` → OpenWebUI receives the request.
4. OpenWebUI's `/signin` endpoint, when `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` is set:
   - Requires the header to be present (returns 400 `INVALID_TRUSTED_HEADER` if missing)
   - Reads the email from the header (ignores `form_data.email` and `form_data.password`)
   - Finds or creates the user by that email
   - Returns a JWT in a `Set-Cookie: token=...` response
5. The frontend stores the JWT and navigates to the main app.

### Rule

> `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` delegates authentication entirely to the injected header. The frontend auto-triggers the sign-in POST — users never see the manual login form. The Authentik proxy session must be valid at sign-in time for Authentik to inject the header. If the header is missing (session expired, bypass router missing), the backend returns 400 and the auto-login fails.

---

## 2 `Open WebUI Backend Required` at `/error` — What It Means

**Version:** OpenWebUI v0.8.10 / SvelteKit
**Discovered:** 2026-07-10, debugging login failures

### What Happened

After changes to the Authentik configuration, navigating to `agent.photondatum.space` showed:

```
Open WebUI Backend Required
Oops! You're using an unsupported method (frontend only). Please serve the WebUI from the backend.
```

The URL in the address bar was `https://agent.photondatum.space/error`.

### Root Cause

The SvelteKit app's `/error` route (node 48 in the compiled bundle) is shown when SvelteKit encounters an unhandled exception during page load or navigation. The specific "Backend Required" message appears when the `$config` Svelte store is null at the time the error page component mounts.

**What causes `$config` to be null or a navigation to `/error`:**
- The browser served a cached `index.html` (HTTP cache or service worker). The cached page loaded, but API calls then got 302'd by forwardAuth (session expired) → cross-origin redirect → CORS error → `fetch()` throws → SvelteKit error boundary → `/error`.
- The auto-sign-in POST (`WEBUI_AUTH_TRUSTED_EMAIL_HEADER` flow) failed with a network/CORS error instead of a clean HTTP error code — SvelteKit does not catch this gracefully and triggers the error boundary.

### Diagnosis Checklist

1. Look at OpenWebUI container logs. Do you see `GET /api/config 200`? If yes, the backend is fine.
2. Do you see `POST /api/v1/auths/signin`? If no, the frontend never reached the auto-signin step → likely a cached-page issue.
3. The repeating login-page sequence (`/api/config` → `/api/v1/auths/` → `/api/v1/users/user/settings 401` → `/api/v1/auths/admin/details` repeating every ~4 s) indicates a redirect loop between `/`, `/auth`, and `/error`.

### Fix

1. **Immediate**: User clears site data for the app domain (cookies, cache, local storage). In Chrome: `chrome://settings/content/siteData` → search the domain → delete.
2. **Permanent**: Add `Cache-Control: no-store` via a Traefik `nocache` middleware on the main application router (not on the `/_app` static assets router). This prevents the browser from caching the HTML page, ensuring every visit goes through forwardAuth.

### Rule

> `agent.photondatum.space/error` showing "Backend Required" is not a backend error — the backend is healthy. It is a client-side error caused by stale browser cache or a failed auto-signin POST. Clear site data to recover. Add `Cache-Control: no-store` on the main router to prevent recurrence.

---

## 3 Browser Cache Can Bypass forwardAuth — Fix with `nocache` Middleware

**Version:** Traefik v3.x / OpenWebUI v0.8.x
**Discovered:** 2026-07-11, after akadmin email change invalidated proxy sessions

### What Happened

After an Authentik proxy session expired (24-hour validity), revisiting `agent.photondatum.space` showed "Backend Required" instead of prompting for Authentik login. The initial page load was served from the browser's HTTP cache, skipping Traefik and forwardAuth entirely. The cached HTML loaded the SvelteKit app, which then made API calls that reached Traefik — but those calls got 302'd by forwardAuth (no valid session cookie). The cross-origin 302 redirect triggered a CORS error, causing the SvelteKit error boundary to navigate to `/error`.

### Fix

Add a `nocache` Traefik middleware that sets `Cache-Control: no-store, no-cache, must-revalidate` and apply it to the auth-gated router:

```yaml
# middlewares.yaml
nocache:
  headers:
    customResponseHeaders:
      Cache-Control: "no-store, no-cache, must-revalidate"
```

```yaml
# services.yaml
openwebui-public:
  middlewares:
    - authentik
    - secure-headers
    - nocache     # prevents browser from caching the HTML page
```

Do **not** apply `nocache` to the `/_app` static assets bypass router — those files are immutable hashed bundles that are safe to cache.

### Rule

> Any Traefik router that uses forwardAuth to gate access must also apply `Cache-Control: no-store` to its responses. Without it, the browser caches the HTML and replays it on the next visit — bypassing forwardAuth and causing CORS failures when the session has since expired.

---

## 4 `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` Requires the Header on Every `/signin` — Including the Auto-Triggered POST

**Version:** OpenWebUI v0.8.10
**Discovered:** 2026-07-11

### What Happened

With `WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-authentik-email` set, the OpenWebUI `/signin` endpoint was changed to **require** the header on every call. If the frontend's auto-triggered `POST /api/v1/auths/signin` cannot send the header (because forwardAuth's session was expired at that moment), the backend returns `400 INVALID_TRUSTED_HEADER`. This is a hard error — the frontend has no fallback login form because `auth_trusted_header: true` disables the form entirely.

The result: when the Authentik proxy session expires:
1. The browser's cached page loads (bypassing forwardAuth)
2. The SvelteKit auto-signin POST gets 302'd or the header is missing → hard error
3. SvelteKit navigates to `/error` → "Backend Required"
4. The `/error` page redirects to `/` → repeat

**Mitigations:**
- `Cache-Control: no-store` on the main router (Lesson 3) — ensures the browser always goes through Traefik. On session expiry, the GET `/` is 302'd to Authentik login. User re-authenticates. When they return, the session is valid and auto-signin succeeds.

### Rule

> With `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` enabled, Authentik's proxy session must be valid for every visit — the manual login form is gone. Apply `Cache-Control: no-store` on the main router (Lesson 3) so session expiry results in a clean Authentik redirect rather than a CORS error loop.

---

## 5 SvelteKit `/_app/version.json` Background Poll Gets 302'd — Use Bypass Router

**Version:** OpenWebUI v0.8.x / Traefik v3.x
**Discovered:** 2026-07-07, initial Authentik integration

### What Happened

OpenWebUI's SvelteKit frontend polls `/_app/version.json` every ~60 seconds to detect app updates. When the Authentik proxy session expires, forwardAuth 302s this poll. `fetch()` follows the 302 cross-origin → CORS preflight → Authentik returns 302 (not proper CORS) → `fetch()` throws → SvelteKit error boundary → URL changes to `/error`.

### Fix

Add a Traefik bypass router with higher priority (longer match rule) for `/_app` paths that skips the `authentik` middleware:

```yaml
openwebui-public-static:
  rule: "Host(`agent.photondatum.space`) && (PathPrefix(`/_app`) || PathPrefix(`/ws`))"
  service: openwebui
  middlewares:
    - secure-headers   # no authentik middleware
```

The `/_app` assets are hashed and immutable — safe to serve without auth. OpenWebUI's own JWT gates the application logic; the static assets are not secrets.

### Rule

> Any SvelteKit app served behind forwardAuth needs a bypass router for `PathPrefix(/_app)`. Without it, background `version.json` polling on session expiry triggers the error boundary.

---

## 6 WebSocket Upgrades Cannot Follow 302 Redirects — Use `/ws` Bypass Router

**Version:** OpenWebUI v0.8.x / Traefik v3.x
**Discovered:** 2026-07-07

### What Happened

OpenWebUI uses Socket.IO for streaming chat responses on `/ws/socket.io/`. When this path was gated by forwardAuth, WebSocket handshake upgrades received 302 responses (Authentik redirect). WebSocket connections cannot follow HTTP redirects — the upgrade silently fails and the client side shows connection errors in the console.

**Diagnosis**: `curl 'https://agent.photondatum.space/ws/socket.io/?EIO=4&transport=polling'` returned 302 (from Authentik, not from OpenWebUI). After bypass router fix it returned 400 (from OpenWebUI — correctly rejecting an unauthenticated polling request).

### Fix

Add `/ws` to the bypass router alongside `/_app`:

```yaml
rule: "Host(`agent.photondatum.space`) && (PathPrefix(`/_app`) || PathPrefix(`/ws`))"
```

OpenWebUI gates WebSocket connections with its own JWT, so the forwardAuth session is not needed for the `/ws` path.

### Rule

> WebSocket upgrade paths must be excluded from forwardAuth. WebSocket connections cannot follow 302 redirects — the handshake silently fails. The app's own JWT (sent in the WebSocket connection URL or headers) provides the auth gate for `/ws`.

---

## 7 `enable_signup=false` Does Not Block Trusted-Header Auto-Provisioning

**Version:** OpenWebUI v0.8.10
**Discovered:** 2026-07-10

### What Happened

OpenWebUI had `enable_signup=false` to prevent self-registration. When `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` was added, new users whose email was not already in the database were still auto-created on first visit.

### Root Cause

In the `/signin` endpoint, when `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` is set, the code path calls `signup_handler()` directly (not the normal signup endpoint). `enable_signup` is not checked in this code path — the trusted header is treated as an authoritative identity assertion that bypasses the signup restriction.

### Rule

> `enable_signup=false` only blocks the self-registration UI form and the `/signup` endpoint. Users introduced via `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` are always provisioned, regardless of `enable_signup`. This is intentional: access control is delegated to Authentik's group policies — if Authentik lets a user through, OpenWebUI trusts it.
