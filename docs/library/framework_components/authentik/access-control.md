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

## Groups

`bundle-agent`/`bundle-agent-mcp`/`bundle-developer`/`bundle-admin`/
`forgejo-guest` are all **retired as of 2026-10-02** — see the dated notes
below for the full capability/role/team rebuild. `forgejo-guest` was last
to go (deleted separately, after confirming zero members/children/FK
references — nothing used it in practice). Read-only Forgejo access is now
purely a `cap-forgejo-guest` capability, available to wire into any future
team, with no flat legacy group of its own anymore. Current real groups:

| Group | Services included |
|---|---|
| `team-default` | agent.photondatum.space only, curated single-model subset — the default landing group for the generic `invitation-enrollment` flow (replaces `bundle-agent`'s old role) |
| `team-guest` | agent.photondatum.space only — for external guests/testers invited via the `enrollment-agent-only` flow (renamed from `agent-only`, 2026-10-02) |
| `team-family` | agent.photondatum.space only — invited via `enrollment-family-group` (see `scripts/provision-user.sh`); renamed from `Family Group`, 2026-10-02 |
| `team-alpha` | agent.photondatum.space, mcp, forgejo-dev, knowledge-index (full developer scope via `role-developer`) — invited via `enrollment-alpha-group`; renamed from `Alpha Group`, 2026-10-02 |
| `team-cts` | full admin everywhere — new team, 2026-10-02 |

New invited users (the generic `invitation-enrollment` flow, not a
team-specific one) land in `team-default` by default; akadmin promotes as
needed. `team-guest`/`team-family`/
`team-alpha` are self-contained teams with their own dedicated invitation
flow, granted access to `agent` via a **direct Group PolicyBinding** on the
Application — see the Registered Applications note below. Provisioning a
new user into any of them (or a future team following the same pattern) is
what `scripts/provision-user.sh` automates end to end — pass the current
group name via `--team` (e.g. `--team "team-family"`).

> **2026-10-02 — capability/role/team hierarchy (D-046):** `bundle-*` and
> `forgejo-guest` above are flat groups checked **by literal name** inside
> each `access-<slug>` ExpressionPolicy (`ak_is_group_member(request.user,
> name="bundle-admin")`, etc.) — renaming any of them would break every
> policy that names them, so they're left alone for now. A parallel,
> **not yet wired into those policies**, capability/role/team hierarchy now
> also exists, built to stop repeating this flat-naming problem for every
> future team: `cap-*` groups (one atomic grant each — `cap-agent`,
> `cap-forgejo-dev`, `cap-forgejo-admin`, `cap-grafana`, etc.), composed into
> `role-*` groups (`role-member-free`, `role-member-paid`, `role-developer`,
> `role-guest`) via Authentik's native group **parents** (a `ManyToMany`
> through `GroupParentageNode` — membership is transitive: `user.all_groups()`
> and `ak_is_group_member()` both walk the full ancestor chain, confirmed
> directly via `manage.py shell`, not assumed from docs). `team-family`,
> `team-alpha`, and the brand-new `team-cts` (no `Alpha Group`-equivalent
> existed before) are wired to this new hierarchy as their parent(s) —
> `team-family`→`role-member-free`, `team-alpha`→`role-developer`,
> `team-cts`→`cap-superadmin`+`cap-forgejo-admin` directly (skipping a
> `role-admin` tier by choice). `cap-superadmin` carries `is_superuser=True`,
> which **is** recursive and **is** already checked generically by every
> `access-<slug>` policy (`request.user.is_superuser or
> ak_is_group_member(...)`) — so `team-cts` already has real, full admin
> access everywhere today, no policy changes needed.
>
> **2026-10-02, same day — policy rewrite completed:** all 8 `access-<slug>`
> ExpressionPolicies (`access-agent`, `access-flowise`, `access-forgejo`,
> `access-grafana`, `access-homepage`, `access-knowledge-index`,
> `access-mcp`, `access-prometheus`) were patched **additively** — the new
> `cap-*` check appended with `or` to the existing `bundle-*` checks, nothing
> removed — so every current real user's access is unchanged, and the new
> hierarchy is now fully real, not just wired. Effective access per team,
> confirmed via each group's live ancestor closure: `team-family`/
> `team-guest` → `cap-agent` only (moderate models); `team-alpha` →
> `cap-agent` (all models) + `cap-agent-mcp` + `cap-forgejo-dev` +
> `cap-knowledge-index` (full developer scope, via `role-developer`);
> `team-cts` → full admin everywhere (`cap-superadmin`'s `is_superuser` flag)
> plus `cap-forgejo-admin`/`cap-forgejo-dev` explicitly. `bundle-*`/
> `forgejo-guest` are still flat, still name-checked by their own original
> clauses in each policy — but as of the same day, also brought **into**
> the new hierarchy as children of the matching capability groups
> (`bundle-agent`→`cap-agent`, `bundle-agent-mcp`→`cap-agent-mcp`,
> `bundle-developer`→`cap-agent-mcp`+`cap-forgejo-dev`+`cap-knowledge-index`,
> `forgejo-guest`→`cap-forgejo-guest`), confirmed zero-risk first since all
> four had **zero real members** at the time. `bundle-admin` was left
> unparented — it already independently carries `is_superuser=True`, so
> parenting it to `cap-superadmin` would be pure redundancy.
>
> **2026-10-02, later the same day — full `bundle-*` retirement.** Michael
> asked to move `bundle-admin`'s real members (Michael + `akadmin`) to
> `cap-superadmin` and delete it — done, `is_superuser=True` confirmed intact
> for both via `cap-superadmin` directly afterward. Then asked to delete the
> other three (`bundle-agent`/`bundle-agent-mcp`/`bundle-developer`) since
> they were confirmed empty — **this cascaded and nulled out
> `invitation-user-write`'s `create_users_group`** (it pointed at
> `bundle-agent`), silently breaking the *generic* `invitation-enrollment`
> flow: every ordinary new-user invite would have landed in no group at all.
> Caught immediately by checking every `UserWriteStage`'s `create_users_group`
> right after the deletion, not after someone reported a broken invite. Fixed
> by creating a new `team-default` group (parent: `role-member-free`) and
> repointing `invitation-user-write` at it — the direct replacement for what
> `bundle-agent` used to represent. Also renamed the **OpenWebUI-side**
> groups to match every Authentik rename/replacement so far (`Family
> Group`→`team-family`, `Alpha Group`→`team-alpha`, `agent-only`→`team-guest`,
> `bundle-admin`→`cap-superadmin`) — these had been missed during the
> earlier renames, meaning `team-family`/`team-alpha`/`team-guest` members
> were already silently getting **zero** OpenWebUI model grants before this
> fix, since the sync matches by exact name. Deleted the now-orphaned
> `bundle-agent`/`bundle-agent-mcp`/`bundle-developer` OpenWebUI groups and
> their model grants (9 each, all unreachable once their Authentik
> originals were gone). `pull-models.sh`'s default "all access" grant list
> is now `cap-superadmin` + `team-alpha` (was `bundle-admin`/`bundle-developer`/
> `bundle-agent`/`bundle-agent-mcp`). `team-default`'s own OpenWebUI group
> was created with a single-model grant (`qwen2.5-1.5b`, Michael's choice —
> "the smaller qwen model").
>
> **2026-10-02, final cleanup.** All 8 `access-<slug>` policies' now-dead
> `ak_is_group_member(request.user, name="bundle-*")` clauses (every
> `bundle-*` name, not just `bundle-admin` — all four are equally deleted)
> were removed — safe since `request.user.is_superuser` already covers
> `cap-superadmin`/`team-cts` and every `cap-*` check already covers
> everyone else. `access-forgejo`'s `forgejo-guest` clause was kept — that
> group still exists, just parented now, not deleted. Every policy now
> reads as just `request.user.is_superuser or
> ak_is_group_member(request.user, name="cap-X")`.
>
> **2026-10-02, later still.** Michael asked whether `forgejo-guest` itself
> (the group, kept alive above) was safe to remove too. Checked first:
> zero members, zero children, no `UserWriteStage.create_users_group`
> pointed at it — genuinely unused, not just currently-empty. Deleted it,
> and removed `access-forgejo`'s now-dead `forgejo-guest` clause in the
> same step (so this cleanup round didn't reintroduce the exact dead-code
> pattern the previous round just fixed). Read-only Forgejo access is now
> purely the `cap-forgejo-guest` capability — no flat legacy group backing
> it, available to wire into a future team whenever one needs it. No
> legacy group name remains anywhere in live policy code or the group list.
> See `output/CENTAURI-playbook.md` §13 L-44 for the full build and the
> exact reasoning for each naming/wiring choice.

---

## Registered Applications

> **2026-09-30 (D-045):** the `knowledge-index` application points at the removed Python Knowledge
> Index. It still exists in Authentik until an operator deletes it (or repoints it at the Go
> Knowledge Index). `knowledge-index-lan` was the other half of this note — resolved 2026-10-02 as
> part of the broader `*-lan` retirement below, not specifically because of D-045.

| Application slug | Name | External URL | Allowed bundles |
|---|---|---|---|
| `agent` | Agent (OpenWebUI) | `https://agent.photondatum.space` | agent, agent-mcp, developer, admin (via `access-agent` policy); **team-guest, team-family, team-alpha** (via direct Group bindings — see note) |
| `forgejo-oidc` | Forgejo (Git) | `https://git.photondatum.space` | admin (`is_superuser`), `cap-forgejo-guest`, `cap-forgejo-dev` (and anything composed from them — currently `team-alpha`/`team-cts` for dev-level, nothing yet for guest-level) |
| `homepage` | Homepage Dashboard | `https://dashboard.photondatum.space` | admin |
| `knowledge-index` | Knowledge Index | `https://ki.photondatum.space` | developer, admin |
| `grafana` | Grafana | `https://grafana.photondatum.space` | admin |
| `prometheus` | Prometheus | `https://prometheus.photondatum.space` | admin |
| `mcp` | MCP | `https://ki.photondatum.space/mcp` (meta_launch_url) | agent-mcp, developer, admin |
| `flowise` | Flowise | `https://flowise.photondatum.space` | admin |
| `litellm` | LiteLLM | `https://litellm.photondatum.space` | admin |

> **Note — `agent`'s direct Group bindings (`team-guest`, `team-family`, `team-alpha`):** the `agent` Application has three `PolicyBinding`s targeting a specific Group directly (not a Policy) alongside its one `access-agent` Expression Policy binding — `policy_engine_mode: any` means any bound check passing is sufficient, so these three groups get through without being listed in `access-agent`'s own expression. This is the right mechanism for a self-contained team that should only ever reach `agent` and nothing else: no policy expression to keep in sync as teams are added, just one more binding per team, which is exactly what creating a team's dedicated invitation flow needs anyway (see Invitation Flow Details below and `scripts/provision-user.sh`).
>
> **Note — `forgejo-oidc`:** Forgejo uses an OAuth2Provider (OIDC), not a ProxyProvider. Caddy on the VPS serves `git.photondatum.space` directly with no forwardAuth middleware — Forgejo handles auth itself via the OIDC flow. A defunct ProxyProvider (pk=2, slug=`forgejo`) was removed during cleanup; only the OAuth2Provider (pk=9) remains. Do not add a ProxyProvider for Forgejo.
>
> **Note — `litellm`:** LiteLLM uses an OAuth2Provider (OIDC), not a ProxyProvider — and unlike the other services here, it has **no LAN ProxyProvider either**. The Traefik `litellm` (LAN) and `litellm-public` routers both have only `secure-headers` middleware — no Authentik forwardAuth on either — because LiteLLM's own OAuth handles auth regardless of which hostname is used. Adding forwardAuth would cause two Authentik round-trips per session. The OAuth2 provider does **not** need to be assigned to the Embedded Outpost (outpost is for ProxyProviders only).
>
> **`*-lan` applications — retired 2026-10-02.** `agent-lan`, `flowise-lan`, `homepage-lan`, `grafana-lan`, `prometheus-lan`, `knowledge-index-lan` (and their ProxyProviders) existed to let a LAN device reach a service via `*.stack.localhost` without going out through the public internet and back in. Michael determined nothing actually needed that path (always used the public `*.photondatum.space` hostnames even from the LAN) and asked them removed — if a real need shows up later, the plan is to evaluate a Headscale-based solution instead of rebuilding this. Deleted all 6 Applications + paired ProxyProviders via the API, then removed the now-dead Traefik routers that pointed at them (`openwebui`, `grafana`, `prometheus`, `homepage`, `flowise`, plus the `openwebui-static` companion bypass router) from `configs/traefik/dynamic/services.yaml` — confirmed via Traefik's own `/api/http/routers` that the hot-reload picked up the change with no restart needed. `knowledge-index-lan` never had a matching Traefik router at all (consistent with its earlier-noted no-policy-binding inconsistency — it was already the odd one out), so nothing additional to clean up there. `qdrant`/`minio-console`'s own `*.stack.localhost` routers were explicitly left alone — out of scope, never had a corresponding Authentik Application in the first place.
>
> (Historical footnote, now moot: the `flowise` LAN router removed above had itself only existed since 2026-07-20, added back then to fix Homepage's `flowise.stack.localhost` tile 404ing at Traefik before ever reaching Authentik — that whole LAN path is gone now, tile and all, and would need revisiting together if LAN access is ever rebuilt.)

Each application has an `access-<slug>` ExpressionPolicy bound to it that
checks `ak_is_group_member` for the allowed bundles. Authentik enforces this
when Traefik calls the forwardAuth endpoint.

### Adding a new application

1. Create a ProxyProvider (forward_single or forward_domain)
2. Create an Application linked to the provider
3. Create an `access-<slug>` ExpressionPolicy:

   ```python
   return request.user.is_superuser or \
          ak_is_group_member(request.user, name="cap-X")
   ```

   (`request.user.is_superuser` alone covers `cap-superadmin`/`team-cts` —
   no need to name them explicitly. Create the new `cap-X` capability group
   first if one doesn't already exist for this service.)

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
6. Account is created as **active**, assigned to `team-default` automatically
7. akadmin promotes to additional bundles as needed

For a team with its own dedicated flow (`team-guest`, `team-family`, `team-alpha` — see
Invitation Flow Details below), `scripts/provision-user.sh --email <email> --team <name>` does
steps 1–4 automatically and prints the link; step 6 then lands the account directly in that
team's group, no step 7 needed.

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

### Flow 1: `invitation-enrollment` — standard invite (username/password, lands in team-default)

| Stage | Name | Purpose |
|---|---|---|
| 0 | `invitation-invite-check` | Reject requests without a valid invite token |
| 10 | `invitation-user-fields` | Collect username, name, email, password |
| 20 | `invitation-user-write` | Create user as active + internal, assign `team-default` (repointed from `bundle-agent`, 2026-10-02 — see dated note above) |
| 30 | `invitation-user-login` | Log the user in immediately after registration |

`continue_flow_without_invitation = False` — the flow is unusable without a
valid invite link. Visiting `/if/flow/invitation-enrollment/` directly returns
an error.

### Flow 2: `enrollment-agent-only` — external guest invite (social login, lands in team-guest)

For external users who should access `agent.photondatum.space` only. Uses social
login (Google/GitHub) instead of username/password — no credentials for the
invitee to manage.

| Stage | Name | Purpose |
|---|---|---|
| 0 | `invitation-agent-only` | Reject requests without a valid invite token (`continue_flow_without_invitation = False`) |
| 10 | `identification-agent-only` | Show Google/GitHub social login buttons (no password option) |
| 20 | `user-write-agent-only` | Create user and assign `team-guest` group automatically |

To invite an external guest:
1. Directory → Invitations → Create
2. Flow: `enrollment-agent-only`
3. Expiry: 7–30 days, single-use: Yes
4. Optionally set `{"email": "invitee@example.com"}` in Custom attributes
5. Copy the generated link and send it to the invitee manually — Authentik does not email it

### Flows 3 & 4: `enrollment-family-group` / `enrollment-alpha-group` — team invites (2026-10-01)

Same structure as Flow 2 (both groups already existed in Authentik before these flows were
added — these just gave them a working invitation path), one pair of flow+stages per team:

| Stage | Name | Purpose |
|---|---|---|
| 0 | `invitation-family-group` / `invitation-alpha-group` | Reject requests without a valid invite token |
| 10 | `identification-family-group` / `identification-alpha-group` | Social login (same 3 sources as the default identification stage) |
| 20 | `user-write-family-group` / `user-write-alpha-group` | Create user and assign `team-family` / `team-alpha` automatically |

No `invitation-user-login` stage (matching Flow 2, not Flow 1) — same as team-guest, not
auto-logged-in after enrollment.

Use `scripts/provision-user.sh --email <email> --team "team-family"` (or `"team-alpha"`)
instead of the manual Directory → Invitations steps above — it discovers the right flow
automatically (by finding every UserWriteStage with `create_users_group` set whose flow starts
with an Invitation stage, so a future team built the same way needs no script changes) and
prints the invite link. See `output/CENTAURI-playbook.md` §13 L-40 for the full build.
