# Authentik — Lessons Learned
**Last Updated:** 2026-03-08 UTC

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
