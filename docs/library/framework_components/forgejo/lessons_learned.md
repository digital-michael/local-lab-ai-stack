# Forgejo — Lessons Learned
**Last Updated:** 2026-07-10

## Purpose
Empirical findings from deploying Forgejo as the self-hosted git service on photondatum.space. Records behaviour that diverged from documentation or assumptions.

---

## Table of Contents

1. [Admin URL Prefix Changed in Forgejo 15 — `/admin/` not `/-/admin/`](#1-admin-url-prefix-changed-in-forgejo-15--admin-not--admin)
2. [ROOT_URL Must Be Set to HTTPS or OIDC redirect_uri Uses http://](#2-root_url-must-be-set-to-https-or-oidc-redirect_uri-uses-http)
3. [OIDC Auth Source Must Request `email profile` Scopes Explicitly](#3-oidc-auth-source-must-request-email-profile-scopes-explicitly)
4. [First OIDC Login Requires link_account Flow — Pre-Create User to Simplify](#4-first-oidc-login-requires-link_account-flow--pre-create-user-to-simplify)

---

## 1 Admin URL Prefix Changed in Forgejo 15 — `/admin/` not `/-/admin/`

**Version:** Forgejo 15.0.3
**Discovered:** 2026-07-10, OIDC auth source setup

### What Happened

Navigating to `https://git.photondatum.space/-/admin/auths/new` returned 404. The path with the `/-/` prefix was assumed from Gitea/Forgejo documentation targeting earlier versions.

### Root Cause

Forgejo 15 changed (or never adopted) the `/-/` admin path prefix for some routes. The bare `/admin/` prefix is the canonical path.

### Fix

Use `/admin/auths/new` (no `/-/` prefix):

```
https://git.photondatum.space/admin/auths/new     ✓
https://git.photondatum.space/-/admin/auths/new   ✗ (404)
```

### Rule

> In Forgejo 15+, admin paths use `/admin/` not `/-/admin/`. If you get a 404 on an admin URL, drop the `/-/` prefix. Verify by checking `curl -o /dev/null -w "%{http_code}" http://127.0.0.1:3000/admin/<path>`.

---

## 2 ROOT_URL Must Be Set to HTTPS or OIDC redirect_uri Uses http://

**Version:** Forgejo 15.0.3
**Discovered:** 2026-07-10, Authentik OIDC wiring

### What Happened

When clicking "Sign in with Authentik" on the Forgejo login page, Authentik returned:

```
Redirect URI Error
The request fails due to a missing, invalid, or mismatching redirection URI (redirect_uri).
```

Authentik logs showed Forgejo sending:

```
redirect_uri=http://git.photondatum.space/user/oauth2/Authentik/callback
```

The registered redirect URI in Authentik was `https://...`.

### Root Cause

Forgejo constructs the OAuth2 `redirect_uri` from its configured `ROOT_URL`. If `ROOT_URL` is not set (or set to `http://`), Forgejo builds all callback URLs with `http://`, regardless of what scheme the browser sees. Caddy handles TLS termination, so Forgejo itself runs on plain HTTP internally — without `ROOT_URL`, it doesn't know it should present as HTTPS externally.

### Fix

**Immediate workaround:** Register both `http://` and `https://` redirect URIs in Authentik. Caddy's HTTP→HTTPS redirect preserves the OAuth2 `code` and `state` query parameters, so the flow completes correctly.

**Permanent fix** (requires editing `/etc/forgejo/app.ini` with sudo):

```ini
[server]
ROOT_URL = https://git.photondatum.space
```

Restart Forgejo after the change. Once set, only the `https://` URI needs to be registered in Authentik.

### Rule

> Always set `ROOT_URL` to the full public HTTPS URL before configuring any OAuth2/OIDC source. Without it, Forgejo sends `http://` redirect URIs that mismatch the registered `https://` URI in the identity provider.

---

## 3 OIDC Auth Source Must Request `email profile` Scopes Explicitly

**Version:** Forgejo 15.0.3
**Discovered:** 2026-07-10, Authentik OIDC wiring

### What Happened

After adding the Authentik OIDC auth source and attempting login, the flow completed but Forgejo showed a prompt for an "OpenID URI" — a legacy OpenID 2.0 field — instead of a username/email registration form. Authentik was not sending user identity claims.

### Root Cause

Forgejo's OpenID Connect auth source only requests `openid` by default. Without `email` and `profile` scopes, Authentik returns only the `sub` (subject) identifier — no `preferred_username`, `email`, or `name`. Forgejo falls back to an OpenID 2.0 flow when it receives an ID token with no identity claims.

### Fix

In Forgejo admin UI → Authentication Sources → edit the Authentik source → **Additional Scopes**:

```
email profile
```

### Rule

> Always set Additional Scopes to `email profile` when configuring an OpenID Connect auth source in Forgejo. The default `openid`-only scope returns no identity claims and triggers a legacy fallback flow.

---

## 4 First OIDC Login Requires link_account Flow — Pre-Create User to Simplify

**Version:** Forgejo 15.0.3
**Discovered:** 2026-07-10, Authentik OIDC wiring

### What Happened

After correctly configuring the OIDC auth source, the first login via Authentik redirected to `/user/link_account` offering to register a new account or link to an existing one. Attempting to register a new account through this flow failed silently and looped back to the same page. The new account did not appear in the database.

### Root Cause

The `link_account` registration flow is a secondary path with less validation feedback than the normal signup form. Silent failures (e.g., username conflicts, password policy violations) loop back to the form without error messages.

### Fix

Pre-create the Forgejo user account as admin before the first OIDC login, then use the "Link to existing account" path:

1. Log in as `forgejo-admin` → Site Administration → User Accounts → Create User
2. Set username, email, temporary password; uncheck "Require password change"
3. Log out, click "Sign in with Authentik", choose **Link to existing account**
4. Enter the credentials created in step 1

The OIDC identity is permanently linked to the Forgejo account. The local password is not needed again for day-to-day login.

### Rule

> For the first OIDC login in Forgejo, pre-create the user account via the admin panel and use "Link to existing account" rather than the `link_account` registration path. The registration sub-flow silently fails without error feedback.
