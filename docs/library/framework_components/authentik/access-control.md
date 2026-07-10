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
| `bundle-admin` | all services including grafana, prometheus, homepage |

Users may be in multiple bundles. New invited users land in `bundle-agent`
by default; akadmin promotes as needed.

---

## Registered Applications

| Application slug | Name | External URL | Allowed bundles |
|---|---|---|---|
| `agent` | Agent (OpenWebUI) | `https://agent.photondatum.space` | agent, agent-mcp, developer, admin |
| `forgejo` | Forgejo (Git) | `https://git.photondatum.space` | developer, admin |
| `homepage` | Homepage Dashboard | `https://dashboard.photondatum.space` | admin |
| `knowledge-index` | Knowledge Index | `https://ki.stack.localhost` | developer, admin |
| `grafana` | Grafana | `https://grafana.stack.localhost` | admin |
| `prometheus` | Prometheus | `https://prometheus.stack.localhost` | admin |
| `mcp` | MCP | `https://mcp.photondatum.space` | agent-mcp, developer, admin |
| `flowise` | Flowise | `https://flowise.photondatum.space` | admin |

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

Flow slug: `invitation-enrollment`

| Stage | Name | Purpose |
|---|---|---|
| 0 | `invitation-invite-check` | Reject requests without a valid invite token |
| 10 | `invitation-user-fields` | Collect username, name, email, password |
| 20 | `invitation-user-write` | Create user as active + internal, assign `bundle-agent` |
| 30 | `invitation-user-login` | Log the user in immediately after registration |

`continue_flow_without_invitation = False` — the flow is unusable without a
valid invite link. Visiting `/if/flow/invitation-enrollment/` directly returns
an error.
