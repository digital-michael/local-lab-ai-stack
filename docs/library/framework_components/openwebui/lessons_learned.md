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
8. [Authentik Impersonation Leaves OpenWebUI's Own Session Stuck as the Impersonated User](#8-authentik-impersonation-leaves-openwebuis-own-session-stuck-as-the-impersonated-user)
9. [Logout Is a No-Op Under Trusted-Header Auth Unless You Also End the Authentik Session](#9-logout-is-a-no-op-under-trusted-header-auth-unless-you-also-end-the-authentik-session)
10. [Non-Admin Users See an Empty Model Dropdown — the `model` Table Being Empty Filters Out Everything](#10-non-admin-users-see-an-empty-model-dropdown--the-model-table-being-empty-filters-out-everything)
11. [Direct Connections Are Hardcoded to `/chat/completions` — Not a General BYOK Mechanism](#11-direct-connections-are-hardcoded-to-chatcompletions--not-a-general-byok-mechanism)

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

---

## 8 Authentik Impersonation Leaves OpenWebUI's Own Session Stuck as the Impersonated User

**Version:** Authentik 2026.5.7 / OpenWebUI v0.8.10
**Discovered:** 2026-09-14/15, debugging Maame-Yaa's pending-account report

### What Happened

akadmin used Authentik's **Impersonate** feature (Directory → Users → select user → Impersonate) to view `agent.photondatum.space` as Maame-Yaa while debugging her "Account Activation Pending" report. Authentik's event log showed the full lifecycle cleanly:

```
login                  akadmin@photondatum.space
impersonation_started  akadmin@photondatum.space → aatwumasi.myt@gmail.com
authorize_application  akadmin@photondatum.space → "Agent (OpenWebUI)"
impersonation_ended    akadmin@photondatum.space
```

But after `impersonation_ended`, akadmin kept seeing Maame's pending screen in that same browser — looking identical to Maame being locked out, and briefly read as "akadmin is now locked out too."

### Root Cause

`WEBUI_AUTH_TRUSTED_EMAIL_HEADER` auth (Lesson 1) is stateless from Authentik's side: each `/signin` POST reads whatever `X-authentik-email` Authentik forwards *at that moment* and OpenWebUI issues its own JWT cookie for that identity. While impersonating, Authentik forwards the impersonated user's email, so OpenWebUI correctly signs in as Maame and sets a `token` cookie for her in that browser.

Ending impersonation resets Authentik's *own* session back to akadmin, but it has no mechanism to reach into a downstream trusted-header app and invalidate the cookie that app already issued. OpenWebUI has no idea impersonation ever happened — it just has a valid, unexpired JWT for Maame sitting in that browser, and will keep using it until it's cleared or expires.

### Fix

In the browser used for impersonation: sign out of OpenWebUI specifically (profile menu → Sign Out), or clear site data for the app's public hostname, then reload — this drops the stale JWT and forces a fresh trusted-header signin against the real (now-reverted) Authentik session. A private/incognito window avoids the problem entirely since its cookie jar is discarded afterward.

### Rule

> Ending Authentik impersonation only resets Authentik's own session — any app using trusted-header/proxy SSO has already cached the impersonated identity in its own cookie and has no signal that impersonation ended. Always impersonate in a private/incognito window. If you must impersonate in your main browser, sign out of the downstream app explicitly afterward rather than assuming ending impersonation reverted it.

---

## 9 Logout Is a No-Op Under Trusted-Header Auth Unless You Also End the Authentik Session

**Version:** OpenWebUI v0.8.10 / Authentik 2026.5.7
**Discovered:** 2026-09-15, akadmin reported logout "not using Default Admin by default"

### What Happened

Clicking Logout while signed in as `akadmin` (the "authentik Default Admin" account) just refreshed the page and signed straight back in as `akadmin` — logout appeared to do nothing.

### Root Cause

OpenWebUI's Logout button only clears its own local `token` cookie. Per Lesson 1, `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` makes the frontend auto-trigger `POST /api/v1/auths/signin` on every page load, which succeeds as long as Authentik's own proxy session for the app is still valid. Logout never touches that Authentik session, so the very next auto-signin re-authenticates as the same identity. There is no unauthenticated state to land on, and no manual login form to interrupt it (`auth_trusted_header: true` removes it) — under pure trusted-header auth, "logout" can only ever mean "log out at the identity provider," not the app.

### Fix — first attempt (does not work on this stack)

Setting `WEBUI_AUTH_SIGNOUT_REDIRECT_URL` to the app's own Authentik outpost sign-out endpoint is the pattern Authentik's own docs recommend for forwardAuth-style proxy providers:

```json
"WEBUI_AUTH_SIGNOUT_REDIRECT_URL": "https://agent.photondatum.space/outpost.goauthentik.io/sign_out"
```

This looked right — confirmed in Open WebUI's own source (`routers/auths.py`) that trusted-header signout correctly returns `{"redirect_url": WEBUI_AUTH_SIGNOUT_REDIRECT_URL}` and the frontend does a real `location.href` navigation, not a client-side route. Every individual special outpost path (`/sign_out`, `/start`, `/callback`) also resolved correctly when curled directly and anonymously through the real public path. But clicking Logout for real (an authenticated session, not curl) showed a brief intermediate page, then a 404. The break is specific to the full authenticated round trip — real session → OAuth code exchange at `/callback` → final landing redirect — which requires a Traefik router that explicitly forwards `PathPrefix(/outpost.goauthentik.io)` on `agent.photondatum.space` to Authentik; this stack's Traefik has no such router and relies entirely on the forwardAuth check's own `X-Forwarded-Uri` inspection, which doesn't cover every leg of that round trip. Full investigation: `output/CENTAURI-playbook.md` §13 L-27 and `output/PhotonDatum-playbook.md` §10 L-10.

### Fix — working

Skip the per-app OAuth round trip entirely. Point the signout hook at Authentik's own generic invalidation flow instead, hosted directly on `auth.photondatum.space` with no app-hostname routing involved:

```json
"WEBUI_AUTH_SIGNOUT_REDIRECT_URL": "https://auth.photondatum.space/flows/-/default/invalidation/"
```

Verified end-to-end (`curl -sk -L`): clean `200` on a real Authentik page. This ends the underlying Authentik session directly, which is sufficient — the next visit to any forwardAuth-gated app requires fresh authentication.

### Rule

> Any app using trusted-header/proxy SSO needs its logout button rewired to hit the IdP's own session-end mechanism — clearing only the app's local cookie is invisible as long as the upstream proxy session is still valid. But prefer the IdP's **generic** logout/invalidation endpoint over a per-application OAuth-provider sign-out path if the latter requires a full authorize→callback round trip through infrastructure (here, Traefik) that wasn't built with that round trip in mind — the generic endpoint has far fewer moving parts to get wrong, and an anonymous `curl` test of the per-app path passing is not proof the authenticated round trip works.

---

## 10 Non-Admin Users See an Empty Model Dropdown — the `model` Table Being Empty Filters Out Everything

**Version:** OpenWebUI v0.8.10
**Discovered:** 2026-09-15, Maame-Yaa reported no models in "Select a model"

### What Happened

After Lesson 7's `DEFAULT_USER_ROLE` fix, Maame-Yaa could sign in and had `role=user`, but her model dropdown was completely empty — no Ollama models, no cloud models, nothing. Admin accounts (akadmin, the human admin) saw the full list fine.

### Root Cause

Traced directly from source (`utils/models.py::get_filtered_models`, `models/access_grants.py`). Every model visible in the chat UI comes from two independent sources merged together:
1. The live model list from the connection (LiteLLM's `/v1/models`) — no per-model metadata, no access control.
2. Optional per-model `model` table rows (created via Workspace → Models, or by admin action) — these attach `info` metadata to a base model.

`get_all_models()` only attaches `info` to a model if a matching `model` table row exists (`custom_models = Models.get_all_models()`, then `model["info"] = custom_model.model_dump()` for matching ids). `get_filtered_models()` then, for any account with `role == "user"` (or an admin with `BYPASS_ADMIN_ACCESS_CONTROL` explicitly disabled), drops every model whose `info` is missing **before it even checks access grants** — a model with no DB row can never pass, regardless of any `access_grant` row for it.

`BYPASS_ADMIN_ACCESS_CONTROL` defaults to `True`, which is why admin accounts were unaffected and this never surfaced before: they skip this filtering path entirely.

Our `model` table had **zero rows** — every one of our 15 chat models (10 Ollama, 1 vLLM, 4 cloud) was a pure connection pass-through with no DB record at all. Result: every non-admin account sees nothing, for every model, permanently, until this is addressed. Not specific to Maame or a provisioning gap on her account.

### Fix Considered and Rejected

`BYPASS_MODEL_ACCESS_CONTROL=True` (global env var) would have fixed the empty dropdown but also made all four **paid cloud models** (`claude-sonnet-4-5`, `gpt-4o`, `llama3-70b-8192`, `mistral-large-latest`) visible and usable by every user — critically, all billed to the *same shared* API keys as the admin's, since `openwebui_api_key = litellm_master_key` (documented invariant, `CENTAURI-playbook.md` §4.3) means OpenWebUI has no way to distinguish which human is calling LiteLLM. This was caught before being applied — see Lesson 11 for the real fix to the cloud-model side.

### Fix Applied

Create explicit `model` + `access_grant` rows for exactly the models that should be public — the self-hosted, free ones — leaving the cloud/paid ones with no rows at all (so they stay invisible to non-admins, which is the default/safe state):

```python
# Inside the openwebui container, against /app/backend/data/webui.db
# For each local (ollama/vllm) model id:
INSERT INTO model (id, user_id, base_model_id, name, params, meta, is_active, created_at, updated_at)
VALUES (<model_id>, <admin_user_id>, NULL, <model_id>, '{}', '{}', 1, <now>, <now>)

INSERT INTO access_grant (id, resource_type, resource_id, principal_type, principal_id, permission, created_at)
VALUES (<uuid>, 'model', <model_id>, 'user', '*', 'read', <now>)
```

`principal_id='*'` with `principal_type='user'` is the schema's public-read wildcard — matches what `access_control_to_grants()` generates automatically when a model is created via the normal API with `access_control=None`. No restart needed: `get_all_models()`/`get_filtered_models()` are live DB queries with no caching (`ENABLE_BASE_MODELS_CACHE` is off), so this takes effect on the user's very next page load.

### Rule

> A model with no `model` table row is invisible to every non-admin account, independent of any access grant — the `info` attachment gate runs first and unconditionally drops rowless models. Before troubleshooting a non-admin's empty model list as an ACL/permission problem, check whether the model even has a DB row at all (`SELECT COUNT(*) FROM model`). Never reach for `BYPASS_MODEL_ACCESS_CONTROL` as a quick fix without first checking whether any paid/cloud models share the same connection — it has no per-model granularity, it's all-or-nothing per user role.

---

## 11 Direct Connections Are Hardcoded to `/chat/completions` — Not a General BYOK Mechanism

**Version:** OpenWebUI v0.8.10 and v0.11.3 (checked both — unchanged)
**Discovered:** 2026-09-15, evaluating personal API keys for cloud models

### What Happened

To let individual users bring their own key for paid cloud models (instead of sharing the admin's LiteLLM-routed keys — see Lesson 10), OpenWebUI's "Direct Connections" feature (Settings → Connections, personal/per-user, gated by the admin-only `ENABLE_DIRECT_CONNECTIONS` toggle) looked like the right built-in mechanism. It's a genuinely separate, per-user code path — confirmed the connection config lives in the user's own `settings.directConnections` (synced server-side via `saveSettings`), completely isolated from the admin's shared `openai.api_configs` that feeds LiteLLM.

### Root Cause / Limitation

Read the actual frontend source (`chat/Settings/Connections/Connection.svelte`) in both v0.8.10 and the latest v0.11.3 — identical in both:
```
content={$i18n.t(`WebUI will make requests to "{{url}}/chat/completions"`, ...)}
```
Direct Connections always POSTs to `<your base url>/chat/completions`. It is **not** a generic BYOK mechanism — it only works for providers whose API is OpenAI-Chat-Completions-shaped at that literal path.

- **OpenAI** — works natively.
- **Groq** — works (`https://api.groq.com/openai/v1`, deliberately OpenAI-compatible).
- **Mistral** — works (`https://api.mistral.ai/v1`, deliberately OpenAI-compatible).
- **Anthropic/Claude** — does **not** work out of the box. Claude's native API is `/v1/messages` with a different request/response schema, not `/chat/completions`. It would only work through an Anthropic-side OpenAI-compatibility shim, if one is currently offered and working — unverified from here, needs an actual test with a real key before relying on it.

### Rule

> Before recommending OpenWebUI's Direct Connections as a personal-API-key solution for a specific provider, verify that provider's API is genuinely `/chat/completions`-shaped (OpenAI, Groq, Mistral, and most "OpenAI-compatible" providers are; Anthropic's native API is not). This limitation is unchanged between v0.8.10 and v0.11.3 — upgrading OpenWebUI will not resolve it. Anthropic/Claude access should stay routed through the shared admin LiteLLM connection (with its cost/access caveats from Lesson 10) until/unless Anthropic's own compatibility endpoint is confirmed working.
