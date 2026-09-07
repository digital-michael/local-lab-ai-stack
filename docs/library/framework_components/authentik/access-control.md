# Authentik Access Control — photondatum.space

This document describes the bundle-based access control model in place on
`auth.photondatum.space`, covering groups, applications, policies, and
user lifecycle (invitation, approval, provisioning).

---

## Access Model

Two axes of control:

| Axis | Mechanism | Who controls |
|---|---|---|
| **System level** | Application enabled/disabled in Authentik | akadmin — affects all users |
| **Subscription level** | User assigned to bundle groups | akadmin — controls per-user access |

System-level disable (e.g., maintenance, shutdown) is independent of user
bundle assignments — removing or disabling an application blocks all users
regardless of their group membership.

---

## Bundle Groups

| Group | Services included |
|---|---|
| `bundle-agent` | agent.photondatum.space, chat.photondatum.space (future) |
| `bundle-agent-mcp` | agent + mcp.photondatum.space |
| `bundle-developer` | agent + git.photondatum.space + knowledge-index |
| `bundle-admin` | all services including grafana, prometheus, homepage, litellm |
| `forgejo-guest` | git.photondatum.space (read-only public repos, no forks) |
| `agent-only` | agent.photondatum.space only — for external guests/testers invited via the `enrollment-agent-only` flow |

Users may be in multiple bundles. New invited users land in `bundle-agent`
by default; akadmin promotes as needed. `forgejo-guest` is for external
collaborators who need read-only repo access without full developer bundle access.
`agent-only` is for external users invited specifically to use the AI agent
interface — they have no access to other services.

---

## Registered Applications

| Application slug | Name | External URL | Allowed bundles |
|---|---|---|---|
| `agent` | Agent (OpenWebUI) | `https://agent.photondatum.space` | agent, agent-mcp, developer, admin, **agent-only** |
| `agent-lan` | Agent (OpenWebUI) LAN | `https://openwebui.stack.localhost` | same as `agent` (bound to `access-agent`) |
| `forgejo-oidc` | Forgejo (Git) | `https://git.photondatum.space` | developer, admin, forgejo-guest |
| `homepage` | Homepage Dashboard | `https://dashboard.photondatum.space` | admin |
| `homepage-lan` | Homepage Dashboard LAN | `https://dashboard.stack.localhost` | same as `homepage` (bound to `access-homepage`) |
| `knowledge-index` | Knowledge Index | `https://ki.photondatum.space` | developer, admin |
| `knowledge-index-lan` | Knowledge Index (LAN) | `https://ki.stack.localhost` | **none bound** — see note below |
| `grafana` | Grafana | `https://grafana.photondatum.space` | admin |
| `grafana-lan` | Grafana LAN | `https://grafana.stack.localhost` | same as `grafana` (bound to `access-grafana`) |
| `prometheus` | Prometheus | `https://prometheus.photondatum.space` | admin |
| `prometheus-lan` | Prometheus LAN | `https://prometheus.stack.localhost` | same as `prometheus` (bound to `access-prometheus`) |
| `mcp` | MCP | `https://ki.photondatum.space/mcp` (meta_launch_url) | agent-mcp, developer, admin |
| `flowise` | Flowise | `https://flowise.photondatum.space` | admin |
| `flowise-lan` | Flowise LAN | `https://flowise.stack.localhost` | same as `flowise` (bound to `access-flowise`) |
| `litellm` | LiteLLM | `https://litellm.photondatum.space` | admin |

> **Note — `forgejo-oidc`:** Forgejo uses an OAuth2Provider (OIDC), not a ProxyProvider. Caddy on the VPS serves `git.photondatum.space` directly with no forwardAuth middleware — Forgejo handles auth itself via the OIDC flow. A defunct ProxyProvider (pk=2, slug=`forgejo`) was removed during cleanup; only the OAuth2Provider (pk=9) remains. Do not add a ProxyProvider for Forgejo.
>
> **Note — `litellm`:** LiteLLM uses an OAuth2Provider (OIDC), not a ProxyProvider — and unlike the other services here, it has **no LAN ProxyProvider either**. The Traefik `litellm` (LAN) and `litellm-public` routers both have only `secure-headers` middleware — no Authentik forwardAuth on either — because LiteLLM's own OAuth handles auth regardless of which hostname is used. Adding forwardAuth would cause two Authentik round-trips per session. The OAuth2 provider does **not** need to be assigned to the Embedded Outpost (outpost is for ProxyProviders only).
>
> **Note — `*-lan` applications (`agent-lan`, `flowise-lan`, `homepage-lan`, `grafana-lan`, `prometheus-lan`, `knowledge-index-lan`):** Each of these six services has exactly one ProxyProvider whose `external_host` points at the **public** `*.photondatum.space` hostname. At some point each one's `external_host` was migrated from the LAN hostname to the public one with nothing left behind to serve the LAN path — since these backend container ports are bound to `127.0.0.1` only, that made `*.stack.localhost` the *only* way another LAN device could reach them, and it 404'd at Authentik (no provider matched). Fixed 2026-07-20 by creating a second "LAN" ProxyProvider + Application for each (`mode=forward_single`, `external_host=https://<service>.stack.localhost`, same `internal_host`), all enrolled in the Embedded Outpost alongside their public counterparts (required — see [Lesson §16](lessons_learned.md#16-new-proxyprovider-applications-are-not-auto-enrolled-in-the-embedded-outpost)). Five of the six were bound to the *same* access policy as their public counterpart (`access-agent`, `access-flowise`, `access-homepage`, `access-grafana`, `access-prometheus`) so LAN access requires the same group membership as public access. `knowledge-index-lan` predates this fix (2026-07-10) and was created with **no** policy binding at all — meaning it's open to any authenticated Authentik user regardless of bundle. That's an inconsistency with the pattern established here, not a deliberate design choice; worth revisiting.
>
> Flowise also had no LAN Traefik router at all until this fix — `configs/traefik/dynamic/services.yaml` only had `flowise-public`, so Homepage's `flowise.stack.localhost` tile link 404'd at Traefik itself (before ever reaching Authentik). Added a plain `flowise` router matching the pattern of the other LAN routers.

Each application has an `access-<slug>` ExpressionPolicy bound to it that
checks `ak_is_group_member` for the allowed bundles. Authentik enforces this
when Traefik calls the forwardAuth endpoint.

### Adding a new application

1. Create a ProxyProvider (forward_single or forward_domain)
2. Create an Application linked to the provider
3. Create an `access-<slug>` ExpressionPolicy:

   ```python
   return ak_is_group_member(request.user, name="bundle-X") or \
          ak_is_group_member(request.user, name="bundle-admin")
   ```

4. Bind the policy to the application (order=0)

### Disabling an application system-wide

In Authentik admin → Applications → select app → uncheck **Enabled** (or
delete the PolicyBinding). Re-enabling restores access for all users in the
allowed bundles without touching user records.

---

## User Lifecycle

### Social login (self-service)

1. User visits `https://auth.photondatum.space` and clicks a social provider
2. Authentik creates the account as **inactive** (pending approval)
3. akadmin sees the user in Directory → Users
4. akadmin activates the user and assigns bundle group(s)

### Admin-provisioned invitation (auto-approved)

1. akadmin → Directory → Invitations → Create invitation
2. Select flow: **`invitation-enrollment`**
3. Set expiry and single-use as appropriate
4. Send the generated link to the invitee
5. Invitee clicks link, fills in username/name/email/password
6. Account is created as **active**, assigned to `bundle-agent` automatically
7. akadmin promotes to additional bundles as needed

### Changing a user's bundle

akadmin → Directory → Users → select user → Groups tab → add/remove bundles.
Changes take effect on the next request (no session invalidation needed for
group-policy checks).

---

## Identification Stage

The `default-authentication-identification` stage has the following social
sources wired to it (appear as login buttons):

- GitHub (`github`)
- Google (`google`)
- GitLab (`gitlab`)

To add a new social source: create the source, assign `default-source-authentication`
and `default-source-enrollment` flows, then add it to the identification stage's
sources M2M via admin UI or Django ORM.

---

## Invitation Flow Details

Two invitation flows exist for different invitee types:

### Flow 1: `invitation-enrollment` — standard invite (username/password, lands in bundle-agent)

| Stage | Name | Purpose |
|---|---|---|
| 0 | `invitation-invite-check` | Reject requests without a valid invite token |
| 10 | `invitation-user-fields` | Collect username, name, email, password |
| 20 | `invitation-user-write` | Create user as active + internal, assign `bundle-agent` |
| 30 | `invitation-user-login` | Log the user in immediately after registration |

`continue_flow_without_invitation = False` — the flow is unusable without a
valid invite link. Visiting `/if/flow/invitation-enrollment/` directly returns
an error.

### Flow 2: `enrollment-agent-only` — external guest invite (social login, lands in agent-only)

For external users who should access `agent.photondatum.space` only. Uses social
login (Google/GitHub) instead of username/password — no credentials for the
invitee to manage.

| Stage | Name | Purpose |
|---|---|---|
| 0 | `invitation-agent-only` | Reject requests without a valid invite token (`continue_flow_without_invitation = False`) |
| 10 | `identification-agent-only` | Show Google/GitHub social login buttons (no password option) |
| 20 | `user-write-agent-only` | Create user and assign `agent-only` group automatically |

To invite an external guest:
1. Directory → Invitations → Create
2. Flow: `enrollment-agent-only`
3. Expiry: 7–30 days, single-use: Yes
4. Optionally set `{"email": "invitee@example.com"}` in Custom attributes
5. Copy the generated link and send it to the invitee manually — Authentik does not email it
