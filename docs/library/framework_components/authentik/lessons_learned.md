<!-- markdownlint-disable MD024 -->
# Authentik — Lessons Learned
**Last Updated:** 2026-07-11

## Purpose
Empirical findings from deploying Authentik in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [Empty Default CMD — Must Pass `server` Explicitly](#1-empty-default-cmd--must-pass-server-explicitly)
2. [Social Login Users Created as `external` Type](#2-social-login-users-created-as-external-type)
3. [OAuth Sources Must Be Added to the Identification Stage](#3-oauth-sources-must-be-added-to-the-identification-stage)
4. [Proxy Providers Require Both `authentication_flow` and `authorization_flow`](#4-proxy-providers-require-both-authentication_flow-and-authorization_flow)
5. [Embedded Outpost Startup Lag After Container Restart](#5-embedded-outpost-startup-lag-after-container-restart)
6. [Superusers Must Be Explicitly Allowed in Expression Policies](#6-superusers-must-be-explicitly-allowed-in-expression-policies)
7. [API Tokens Expire by Default — Use `expiring=False` for Setup](#7-api-tokens-expire-by-default--use-expiringfalse-for-setup)
8. [BitBucket OAuth Removed in Authentik 2025.x](#8-bitbucket-oauth-removed-in-authentik-2025x)
9. [DJANGO_SETTINGS_MODULE Must Be Set Explicitly in Programmatic Scripts](#9-django_settings_module-must-be-set-explicitly-in-programmatic-scripts)
10. [Authentik Worker OOM on Startup — Needs 512m, Not 256m](#10-authentik-worker-oom-on-startup--needs-512m-not-256m)
11. [Proxy Provider `external_host` Must Match the Host Header Caddy Sends](#11-proxy-provider-external_host-must-match-the-host-header-caddy-sends)
12. [Stale Authentik on Controller Node Causes forwardAuth Interference](#12-stale-authentik-on-controller-node-causes-forwardauth-interference)
13. [Proxy Provider Has No Client Secret — Use Separate OAuth2Provider for OIDC Clients](#13-proxy-provider-has-no-client-secret--use-separate-oauth2provider-for-oidc-clients)
14. [Admin Account Email Must Be Distinct From Personal Account Email](#14-admin-account-email-must-be-distinct-from-personal-account-email)
15. [Changing ProxyProvider `external_host` Does Not Auto-Update OAuth2 `redirect_uris`](#15-changing-proxyprovider-external_host-does-not-auto-update-oauth2-redirect_uris)
16. [New ProxyProvider Applications Are Not Auto-Enrolled in the Embedded Outpost](#16-new-proxyprovider-applications-are-not-auto-enrolled-in-the-embedded-outpost)
17. [Changing a User's Email Invalidates All Proxy Session Cookies](#17-changing-a-users-email-invalidates-all-proxy-session-cookies)
18. [`access_token_validity` on ProxyProvider Must Be Set Explicitly — Defaults to 1 Hour](#18-access_token_validity-on-proxyprovider-must-be-set-explicitly--defaults-to-1-hour)
19. [Malformed `access_token_validity` Causes Infinite Redirect Loop — Diagnose via Event Log](#19-malformed-access_token_validity-causes-infinite-redirect-loop--diagnose-via-event-log)

---

## 1 Empty Default CMD — Must Pass `server` Explicitly

**Version:** Authentik 2024.x (`ghcr.io/goauthentik/server`)  
**Discovered:** 2026-03-08, Phase 7 first-boot  
**See also:** `podman/lessons_learned.md`

### What Happened
The Authentik container started, printed management help text, then exited immediately with status 0. No server process launched and no ports were bound. The `podman ps` output showed the container as `Exited (0)` seconds after start.

The help text shown was the `ak` management CLI usage:

```
Usage: ak [OPTIONS] COMMAND [ARGS]...

  authentik management CLI

Options:
  ...
Commands:
  server     Start the authentik server
  worker     Start the authentik worker
  ...
```

### Root Cause
The Authentik image uses a multi-stage entrypoint:

```
ENTRYPOINT ["dumb-init", "--", "ak"]
CMD []
```

The `ENTRYPOINT` invokes `ak` via `dumb-init`. The `CMD` is **empty**. When Podman starts the container with no additional command, `ak` receives no arguments and defaults to printing its usage help, then exits clean.

This is different from images that default `CMD` to a sensible verb (e.g. `["server"]`). The Authentik image requires the operator to explicitly choose the sub-command.

### Fix
Two changes were required:

**1. Added `command` field to `configs/config.json`** for the authentik service:

```json
"authentik": {
  ...
  "command": "server"
}
```

**2. Updated `scripts/configure.sh`** to emit `Exec=` when the `command` field is present:

```bash
cmd_override=$(jq -r --arg s "$svc" '.services[$s].command // empty' "$CONFIG_FILE")
[[ -n "$cmd_override" ]] && echo "Exec=$cmd_override"
```

This appends `Exec=server` to the generated `.container` quadlet, which Podman passes as the container command after the ENTRYPOINT.

The worker process (used for background tasks) requires a separate container instance with `Exec=worker`. The stack currently runs the server only.

### Rule

> Check `docker inspect <image>` for `Cmd` before deploying. If `Cmd` is empty and the image uses a multi-command CLI entrypoint (like `ak`), you **must** supply the sub-command explicitly via `Exec=` in the quadlet or `command:` in the compose spec.

---

## 2 Social Login Users Created as `external` Type

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-08, social login wiring

### What Happened

After configuring GitHub as a social login source and signing in, the login succeeded but Authentik showed:

```
Interface can only be accessed by internal users.
```

The user was created in the database with `type=external`.

### Root Cause

Authentik's default source enrollment write stage (`default-source-enrollment-write`) creates users as `type=external`. External users cannot access the main Authentik interface or downstream services.

### Fix

Two changes required:

**1. Promote existing user:**

```python
from authentik.core.models import User, UserTypes
u = User.objects.get(username="digital-michael")
u.type = UserTypes.INTERNAL
u.save()
```

**2. Fix enrollment stage for future signups:**

```python
from authentik.stages.user_write.models import UserWriteStage
stage = UserWriteStage.objects.get(name="default-source-enrollment-write")
stage.user_type = UserTypes.INTERNAL
stage.save()
```

Only fix `default-source-enrollment-write` — do not change `default-password-change-write` or `default-user-settings-write`.

### Rule

> After configuring social login sources, always verify `default-source-enrollment-write` has `user_type = INTERNAL`. The default creates external users who are silently blocked from service access.

---

## 3 OAuth Sources Must Be Added to the Identification Stage

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-08, social login wiring

### What Happened

GitHub, Google, and GitLab sources were created and assigned `authentication_flow` and `enrollment_flow`, but no login buttons appeared on the Authentik login page. Only the username/password field was shown.

### Root Cause

OAuth sources are not surfaced on the login page automatically. The `default-authentication-identification` stage has an explicit M2M `sources` field. Only sources listed there appear as login buttons.

### Fix

```python
from authentik.stages.identification.models import IdentificationStage
from authentik.sources.oauth.models import OAuthSource

stage = IdentificationStage.objects.get(name="default-authentication-identification")
for slug in ["github", "google", "gitlab"]:
    stage.sources.add(OAuthSource.objects.get(slug=slug))
stage.save()
```

### Rule

> Creating an OAuth source and assigning flows is not enough. You must also add the source to the identification stage's `sources` M2M. No restart required — takes effect immediately.

---

## 4 Proxy Providers Require Both `authentication_flow` and `authorization_flow`

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-08, forwardAuth wiring

### What Happened

Proxy providers were created and assigned to the embedded outpost, but the outpost returned 404 for all forwardAuth requests matching registered external hosts.

### Root Cause

The ORM `get_or_create` call did not set `authorization_flow`, leaving it `None`. The embedded outpost Go binary requires both:

- `authentication_flow` — where to send unauthenticated users for login
- `authorization_flow` — the OAuth2 consent/authorization step (use implicit consent for internal services)

Without `authorization_flow`, the outpost cannot complete the auth flow and returns 404.

### Fix

```python
from authentik.providers.proxy.models import ProxyProvider, ProxyMode
from authentik.flows.models import Flow

auth_flow = Flow.objects.get(slug="default-authentication-flow")
authz_flow = Flow.objects.get(slug="default-provider-authorization-implicit-consent")

for p in ProxyProvider.objects.all():
    p.authentication_flow = auth_flow
    p.authorization_flow = authz_flow
    p.mode = ProxyMode.FORWARD_SINGLE
    p.save()
```

Use `forward_single` mode for all Traefik forwardAuth providers. `forward_domain` is for Authentik acting as the proxy itself, not for forwardAuth delegation.

### Rule

> Proxy providers need both `authentication_flow` and `authorization_flow`. Use `default-provider-authorization-implicit-consent` for internal services. Always use `forward_single` mode with Traefik forwardAuth.

---

## 5 Embedded Outpost Startup Lag After Container Restart

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-08, forwardAuth wiring

### What Happened

After restarting the Authentik container, `/-/health/ready/` returned 200 but forwardAuth requests to `/outpost.goauthentik.io/auth/traefik` still returned 404 for ~15–20 seconds.

### Root Cause

The embedded outpost is a Go binary running inside the Authentik container alongside the Python ASGI server. After the Python server reports ready, the Go binary still needs to:

1. Connect to Authentik's WebSocket API
2. Fetch outpost config (`/api/v3/outposts/instances/`)
3. Fetch proxy provider list (`/api/v3/outposts/proxy/`)
4. Register its HTTP handlers for `/outpost.goauthentik.io/*`

Only after step 4 does forwardAuth work. Health checks pass at step 0.

### Fix

Wait for the Go binary to report its startup log entry before testing:

```
{"event":"Starting authentik outpost","level":"info","logger":"authentik.outpost"}
```

Or simply wait 20–30 seconds after the health check passes before testing forwardAuth endpoints.

### Rule

> `/-/health/ready/` passing does not mean forwardAuth is ready. After a restart, wait 20–30 seconds before testing `/outpost.goauthentik.io/auth/traefik`. Early tests return 404 even when the container is healthy.

---

## 6 Superusers Must Be Explicitly Allowed in Expression Policies

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-08, access control wiring

### What Happened

After binding group-membership expression policies to applications, `akadmin` (Authentik superuser) was denied access with:

```
Policy binding returned result 'False'
```

### Root Cause

`akadmin` is not a member of any bundle group. Expression policies that only check `ak_is_group_member(...)` will deny superusers along with everyone else who lacks group membership.

### Fix

Prefix every access policy expression with a superuser bypass:

```python
return request.user.is_superuser or ak_is_group_member(request.user, name="bundle-X") or ...
```

### Rule

> Always include `request.user.is_superuser` as the first condition in access expression policies. Authentik superusers are infrastructure accounts and must never be blocked by application-level policies.

---

## 7 API Tokens Expire by Default — Use `expiring=False` for Setup

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-08, programmatic setup

### What Happened

API tokens created via the Django ORM with default settings expired within minutes, causing `403 Token invalid/expired` errors during multi-step setup scripts.

### Root Cause

`Token` objects have `expiring=True` by default in Authentik. The default TTL is short. For interactive setup sessions spanning multiple commands, tokens expire between steps.

### Fix

```python
from authentik.core.models import Token, TokenIntents, User
u = User.objects.get(username="akadmin")
t = Token.objects.create(
    identifier="setup-token",
    user=u,
    intent=TokenIntents.INTENT_API,
    expiring=False,
)
```

Always delete the token when setup is complete:

```python
Token.objects.filter(identifier="setup-token").delete()
```

### Rule

> Create setup tokens with `expiring=False`. Delete them immediately when setup is complete. Expiring tokens silently break multi-step scripts mid-run.

---

## 8 BitBucket OAuth Removed in Authentik 2025.x

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-08, social login wiring

### What Happened

Attempting to create a BitBucket OAuth source via the API returned:

```json
{"provider_type": ['"bitbucket" is not a valid choice.']}
```

### Root Cause

BitBucket was removed from Authentik's built-in OAuth provider list in a newer release. It no longer appears in `/api/v3/sources/oauth/source_types/`.

BitBucket's OAuth 2.0 is also not fully OIDC-compliant, making it unsuitable as a generic `openidconnect` source.

### Rule

> BitBucket is not supported as a social login source in Authentik 2025.x. Use GitHub, Google, or GitLab instead. Do not attempt to configure it as an `openidconnect` source — the flows are incompatible.

---

## 9 DJANGO_SETTINGS_MODULE Must Be Set Explicitly in Programmatic Scripts

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, Flowise/Forgejo OIDC setup

### What Happened

Running `python -c "import django; django.setup(); ..."` inside the Authentik container raised:

```
django.core.exceptions.ImproperlyConfigured:
  Requested setting INSTALLED_APPS, but settings are not configured.
  You must either define the environment variable DJANGO_SETTINGS_MODULE
  or call django.conf.settings.configure() before accessing settings.
```

Earlier sessions used `python manage.py shell` which set the env var automatically. Direct `python -c` does not.

### Root Cause

`/manage.py` sets `DJANGO_SETTINGS_MODULE=authentik.root.settings` at the top of the file. When you invoke `manage.py shell`, this runs. When you invoke `python -c` directly, the env var is never set.

### Fix

Always begin every script with:

```python
import os, django
os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'authentik.root.settings')
django.setup()
```

### Rule

> Never omit `os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'authentik.root.settings')` before `django.setup()` in scripts run via `python` directly (not `manage.py shell`).

---

## 10 Authentik Worker OOM on Startup — Needs 512m, Not 256m

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, VPS IAM health check

### What Happened

`ai-stack-iam-authentik-worker` had `NRestarts=1816` on the VPS. The worker started, ran database migrations on first boot, peaked at 257MB RSS + 195MB swap, and was OOM-killed. This repeated in a tight loop.

### Root Cause

The initial resource limit was `--memory=256m`. Migration spikes during startup exceed this by ~1MB. Podman's OOM killer terminates the container immediately after the spike. The service restarts and repeats, never stabilising.

### Fix

```
PodmanArgs=--cpus=0.5 --memory=512m
```

### Rule

> Set `--memory=512m` for the Authentik worker. `256m` is insufficient on first boot when database migrations run. The spike is temporary but fatal under tight limits.

---

## 11 Proxy Provider `external_host` Must Match the Host Header Caddy Sends

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, Flowise forwardAuth wiring

### What Happened

The Flowise proxy provider was configured with `external_host=https://flowise.photondatum.space` (the public URL). Authentik's embedded outpost returned 404 for all forwardAuth requests from Traefik on CENTAURI.

### Root Cause

The Caddy reverse proxy block uses `header_up Host flowise.stack.localhost` to forward requests to CENTAURI Traefik. Traefik's forwardAuth request to Authentik includes `X-Forwarded-Host: flowise.stack.localhost`. The Authentik outpost matches this header against registered `external_host` values — if none match, it returns 404.

The outpost matches `X-Forwarded-Host` (what arrives at Traefik), not the original browser `Host` (the public URL).

### Fix

```python
provider.external_host = 'https://flowise.stack.localhost'
```

### Rule

> Set `external_host` to the value Traefik sees — i.e., the `header_up Host` value Caddy sends into CENTAURI, not the public `*.photondatum.space` URL. Trace: browser Host → Caddy `header_up Host` → Traefik `X-Forwarded-Host` → Authentik outpost match.

---

## 12 Stale Authentik on Controller Node Causes forwardAuth Interference

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, post-migration diagnostics

### What Happened

After migrating Authentik from CENTAURI to the VPS edge node, `agent.photondatum.space` returned 500 with 14-second timeouts. Traefik logs showed the old Authentik outpost on CENTAURI hammering `auth.stack.localhost/ws/client/` with 404s — it was trying to reconnect to itself.

### Root Cause

The Authentik container was not stopped on CENTAURI after the VPS migration. The stale Authentik outpost (embedded in the CENTAURI container) periodically tried to establish its WebSocket channel. When Traefik's forwardAuth eventually routed a request to the VPS Authentik, the response was correct — but the interference from the stale outpost created timing and routing conflicts producing 500 errors.

### Fix

On CENTAURI, after confirming Authentik is running on the edge node:

```bash
systemctl --user stop authentik
systemctl --user disable authentik
```

### Rule

> When migrating Authentik from the controller to the edge node, immediately stop and disable the controller's Authentik service. Do not leave it running — even if Traefik's `forwardAuth` middleware is already pointed at the edge node, the stale outpost's WebSocket reconnect loop will interfere with auth responses.

---

## 13 Proxy Provider Has No Client Secret — Use Separate OAuth2Provider for OIDC Clients

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, Forgejo OIDC wiring

### What Happened

When attempting to configure Forgejo to use Authentik as an OIDC source, the existing "Forgejo (Git)" provider in Authentik showed "Update Proxy Provider" in the admin UI with no Client Secret field. The OIDC redirect URIs were also set to outpost callback URLs, not Forgejo's own callback.

### Root Cause

The provider was a `ProxyProvider` (set up for forwardAuth), not an `OAuth2Provider`. Proxy providers use Authentik's internal OAuth2 flow for the outpost — they do not expose a client secret to third-party applications. The redirect URIs (`/outpost.goauthentik.io/callback`) are internal to the outpost, not for use by external OIDC clients.

### Fix

Create a separate `OAuth2Provider` for Forgejo to authenticate against:

```python
from authentik.providers.oauth2.models import OAuth2Provider, RedirectURI, RedirectURIMatchingMode, ScopeMapping, ClientTypes

provider = OAuth2Provider.objects.create(
    name='Forgejo OIDC',
    authentication_flow=auth_flow,
    authorization_flow=authz_flow,
    client_type=ClientTypes.CONFIDENTIAL,
)
provider.redirect_uris = [
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.STRICT,
        url='https://git.photondatum.space/user/oauth2/Authentik/callback',
    )
]
provider.property_mappings.set(ScopeMapping.objects.filter(scope_name__in=['openid', 'email', 'profile']))
provider.save()
```

Then retrieve the client secret from Authentik admin UI → Providers → (new provider) → Edit.

### Rule

> Proxy providers are for Authentik acting as a reverse-proxy forwardAuth gate. For third-party apps that authenticate *against* Authentik using OIDC (e.g., Forgejo, Grafana), create a separate `OAuth2Provider`. Never attempt to reuse a proxy provider as an OIDC source — it has no client secret and wrong redirect URIs.

---

## 14 Admin Account Email Must Be Distinct From Personal Account Email

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, account setup

### What Happened

Both `akadmin` and `digital-michael` were configured with the same email (`michaelbiggerstaff7@gmail.com`). This created ambiguity: social login via that email could potentially match either account, and administrative operations were unclear about which identity they affected.

### Fix

```python
u = User.objects.get(username='akadmin')
u.email = 'akadmin@photondatum.space'
u.save()
```

### Rule

> `akadmin` is an infrastructure account — give it a non-real, non-shared email (`akadmin@<domain>`). It should never be linked to a social login source. Personal user accounts use real email addresses and social login. The two must never share an email.

---

## 15 Changing ProxyProvider `external_host` Does Not Auto-Update OAuth2 `redirect_uris`

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, exposing knowledge-index via ki.photondatum.space

### What Happened

After changing a ProxyProvider's `external_host` from `https://ki.stack.localhost` to `https://ki.photondatum.space`, the Authentik login flow returned "Redirect URI Error — missing, invalid, or mismatching redirection URI". The `redirect_uris` field still contained the old `ki.stack.localhost` values.

### Root Cause

`ProxyProvider.redirect_uris` is stored separately from `external_host`. Saving the provider via the Django ORM (`provider.external_host = '...'; provider.save()`) updates the field but does not trigger the signal that regenerates `redirect_uris` from the new `external_host`.

### Fix

Explicitly set `redirect_uris` after changing `external_host`:

```python
from authentik.providers.oauth2.models import RedirectURI, RedirectURIMatchingMode

provider.external_host = 'https://ki.photondatum.space'
provider.redirect_uris = [
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.STRICT,
        url='https://ki.photondatum.space/outpost.goauthentik.io/callback?X-authentik-auth-callback=true'
    ),
    RedirectURI(
        matching_mode=RedirectURIMatchingMode.STRICT,
        url='https://ki.photondatum.space?X-authentik-auth-callback=true'
    ),
]
provider.save()
```

Alternatively, edit the provider in the Authentik admin UI — the UI regenerates `redirect_uris` from `external_host` on save.

### Rule

> When changing a ProxyProvider's `external_host` programmatically, always update `redirect_uris` in the same operation. The ORM `save()` does not auto-regenerate them. The UI save does.

---

## 16 New ProxyProvider Applications Are Not Auto-Enrolled in the Embedded Outpost

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, adding ki.stack.localhost LAN provider

### What Happened

After creating a new `Application` + `ProxyProvider` (`knowledge-index-lan`, `external_host=https://ki.stack.localhost`) to add LAN support alongside the existing public provider, the embedded outpost still returned 404 for `ki.stack.localhost`. The outpost had no knowledge of the new provider even after waiting several minutes.

### Root Cause

Authentik's embedded outpost maintains an **explicit list of providers** it serves. Creating an `Application` with a `ProxyProvider` does not automatically enroll that provider in any outpost — even the embedded one. The outpost's provider list must be updated manually.

### Fix

```python
from authentik.outposts.models import Outpost
from authentik.providers.proxy.models import ProxyProvider

outpost = Outpost.objects.get(name='authentik Embedded Outpost')
new_provider = ProxyProvider.objects.get(name='knowledge-index-lan')
outpost.providers.add(new_provider)
outpost.save()
```

The outpost picks up the change within ~30 seconds (no restart required).

### Rule

> After creating a ProxyProvider + Application, **always** add the provider to the target outpost (`outpost.providers.add(provider)`). The embedded outpost does not auto-discover new providers. Without this step, the outpost returns 404 for the new hostname indefinitely.

---

## 17 Changing a User's Email Invalidates All Proxy Session Cookies

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, akadmin email update

### What Happened

After changing `akadmin`'s email from `akadmin@photondatum.space` to `michaelbiggerstaff7@gmail.com` (to align it with the OpenWebUI admin account for `WEBUI_AUTH_TRUSTED_EMAIL_HEADER`), all existing proxy session cookies for `agent.photondatum.space` were invalidated. On the next visit, the browser served the cached HTML page (bypassing forwardAuth), loaded the SvelteKit app, then hit API endpoints — those were 302'd because the session cookie was now invalid. The cross-origin 302 triggered a CORS error → SvelteKit `/error` → "Backend Required".

### Root Cause

Authentik proxy session tokens contain the authenticated user's identity claims, including their email. When the email changes, existing sessions referencing the old email are invalidated server-side. The browser still holds the old cookie, but Authentik rejects it.

### Fix

After changing a user's email:

1. Inform affected users that they need to clear site data for all forwardAuth-protected apps and re-authenticate.
2. In Authentik admin → Flows & Stages → Tokens, revoke any outstanding tokens for that user if needed.
3. Apply `Cache-Control: no-store` on forwardAuth-gated routers (see Traefik lessons §8 / OpenWebUI lessons §3) so that cached HTML pages do not cause CORS loops when the session is invalidated.

### Rule

> Changing a user's email in Authentik immediately invalidates their proxy session cookies. Users must re-authenticate. This is expected but easy to overlook — especially for the `akadmin` account which may be used intermittently. Document email changes and notify affected sessions before making the change.

---

## 18 `access_token_validity` on ProxyProvider Must Be Set Explicitly — Defaults to 1 Hour

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-10, debugging session expiry

### What Happened

After deploying forwardAuth with ProxyProviders for `agent.photondatum.space` and `flowise.photondatum.space`, users were logged out every hour. The Authentik proxy session cookie expired, triggering a re-authentication round-trip. This was disruptive for long-running chat sessions in OpenWebUI.

### Root Cause

The default `access_token_validity` on a freshly created `ProxyProvider` is `timedelta(hours=1)`. This is the lifetime of the proxy session cookie set by the embedded outpost's callback. Once expired, forwardAuth returns 302 on the next request.

### Fix

Update the ProxyProvider via the Authentik Django shell:

```python
from authentik.providers.proxy.models import ProxyProvider
from datetime import timedelta

for name in ['agent', 'flowise']:
    p = ProxyProvider.objects.get(name__icontains=name)
    p.access_token_validity = timedelta(hours=24)
    p.save()
    print(p.name, p.access_token_validity)
```

### Rule

> After creating a ProxyProvider, explicitly set `access_token_validity` to match your session policy (e.g. `hours=24` for daily re-auth). The default 1-hour expiry is almost always too short for browser-based applications and will cause frequent re-authentication interruptions.

### Caveat — Django ORM assignment corrupts the field (2026-07-11)

**Do not** assign a Python `timedelta` object via the Django shell:

```python
p.access_token_validity = timedelta(hours=24)  # WRONG — stores "1 day, 0:00:00"
```

Authentik 2025.x stores `access_token_validity` as a plain string in `key=value` format. Setting it to a `timedelta` object causes Django to persist the object's `str()` representation (`1 day, 0:00:00`), which contains no `=` separator. On the next token exchange, `timedelta_from_string()` crashes with `ValueError: not enough values to unpack`. This produces an infinite redirect loop (see §19).

**Correct shell fix:**

```python
from authentik.providers.proxy.models import ProxyProvider
for p in ProxyProvider.objects.all():
    p.access_token_validity = "hours=24"
    p.save()
```

Or use the admin UI: **Applications → Providers → [Provider] → Edit → Access Token Validity** → enter `hours=24`.

---

## 19 Malformed `access_token_validity` Causes Infinite Redirect Loop — Diagnose via Event Log

**Version:** Authentik 2025.2.4
**Discovered:** 2026-07-11, post-migration forwardAuth debugging
**See also:** §18 (access_token_validity format), Traefik lessons §8

### What Happened

All forwardAuth-gated services (`agent.photondatum.space`, `flowise.photondatum.space`) entered an infinite redirect loop. OAuth flows completed — fresh authorization codes appeared in Traefik logs — but sessions were never established and the browser returned `ERR_TOO_MANY_REDIRECTS`.

### Root Cause

The `access_token_validity` field on both ProxyProviders had been set to `timedelta(hours=24)` via the Django ORM (see §18 caveat). Django persisted `1 day, 0:00:00` as the field value. During every token exchange, `timedelta_from_string()` crashed:

```
File "/authentik/lib/utils/time.py", line 38, in timedelta_from_string
    key, value = duration_pair.split("=")
ValueError: not enough values to unpack (expected 2, got 1)
```

The embedded outpost caught the exception, returned `302 → original URL` **without a `Set-Cookie` header**, and the proxy session was never created. On the next request, forwardAuth found no session and started a new OAuth flow. Because the user's Authentik session was valid, authorization was granted instantly and a new code issued — repeating the loop indefinitely.

### Symptoms

- Traefik access log: `OriginStatus:0` on **every** request including `/outpost.goauthentik.io/callback` (backend never reached)
- The same `sid` value appears in consecutive callback state JWTs (state cookie never replaced by session cookie)
- All forwardAuth-gated services fail simultaneously
- `ERR_TOO_MANY_REDIRECTS` in browser; incognito and cleared cookies make no difference

### Diagnosis

**Authentik admin → Events → Logs** shows the pattern repeating in lockstep:

```
Application authorized   akadmin   <browser IP>   (code issued)
General system exception  AnonymousUser  127.0.0.1  (outpost crashes)
Application authorized   akadmin   <browser IP>   (code issued again)
General system exception  AnonymousUser  127.0.0.1  (outpost crashes again)
```

The `127.0.0.1` client IP identifies the **embedded outpost** (runs inside the Authentik server process). Click the exception entry — the traceback will name the exact failing line and field.

### Fix

Edit each ProxyProvider in the Authentik admin UI:

1. **Applications → Providers → [Provider Name] → Edit**
2. **Access Token Validity** field → change to `hours=24`
3. **Save**

Repeat for every affected provider. No restart needed.

### Rule

> When all forwardAuth-gated services loop simultaneously and `ERR_TOO_MANY_REDIRECTS` persists across cleared cookies and incognito windows, check the Authentik event log first. Alternating "Application authorized" + "General system exception (127.0.0.1)" pairs always mean the embedded outpost is crashing during token exchange — not an outpost assignment, network, or browser issue.
