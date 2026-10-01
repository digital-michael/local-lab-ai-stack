# Provisioning New OpenWebUI Users
**Last Updated:** 2026-09-16
**Audience:** akadmin / bundle-admin operators provisioning a new person onto `agent.photondatum.space`

## Purpose

Step-by-step admin guide for adding a new OpenWebUI user, start to finish. Access is
gated in two independent places — Authentik (who gets in the door) and OpenWebUI itself
(what they see once inside) — and this guide covers both, in order, so nothing gets
missed.

As of 2026-09-15, most of the OpenWebUI side is **automatic** for a newly invited user
(see [Background](#background) below) — this guide is mostly a checklist to confirm that
held true for this particular person, not a set of manual fixes you need to apply by hand.

---

## Table of Contents

1. [Background — What's Automatic Now](#1-background--whats-automatic-now)
2. [Step 1 — Invite the User in Authentik](#step-1--invite-the-user-in-authentik)
3. [Step 2 — User Signs In](#step-2--user-signs-in)
4. [Step 3 — Verify Provisioning](#step-3--verify-provisioning)
5. [Step 4 — Point Them to the External-Models How-To](#step-4--point-them-to-the-external-models-how-to)
6. [Troubleshooting — If Something Didn't Auto-Provision](#troubleshooting--if-something-didnt-auto-provision)
7. [Reference](#reference)

---

## 1 Background — What's Automatic Now

OpenWebUI trusts whoever Authentik's `bundle-agent` (or broader) group policy lets
through — that's the real access gate. Two things that used to require a manual fix
per new user are now handled automatically by config, as of this session's fixes:

| Used to require | Now happens automatically because |
|---|---|
| Admin manually setting role from "pending" to "user" in OpenWebUI's Admin Panel | `DEFAULT_USER_ROLE=user` is set on the `openwebui` service — new trusted-header signups land active, not pending |
| Nothing — new users saw an empty model dropdown regardless | The 11 free/self-hosted models (10 Ollama + vLLM) are published with a public (`principal_id='*'`) access grant — any new account sees them immediately, no per-user step needed |

**What is still manual, by design:** paid cloud models (OpenAI, Groq, Mistral, Claude)
are never auto-granted to new users — see [Step 4](#step-4--point-them-to-the-external-models-how-to).

---

## Step 1 — Invite the User in Authentik

Full detail: [`authentik/access-control.md` § User Lifecycle](../authentik/access-control.md#user-lifecycle).
Two paths, pick one:

**Admin-provisioned invitation (recommended — lands active immediately):**
1. akadmin → Directory → Invitations → Create invitation
2. Flow: `invitation-enrollment`
3. Set expiry and single-use as appropriate
4. Send the generated link to the invitee
5. They fill in username/name/email/password → account is created **active**, assigned to `bundle-agent` automatically

**Self-service social login (lands inactive, needs your approval):**
1. User visits `https://auth.photondatum.space` and clicks a social provider (GitHub/Google/GitLab)
2. Authentik creates the account as **inactive**
3. akadmin → Directory → Users → find them → activate → assign `bundle-agent` (or the appropriate bundle)

If they need more than chat access (developer tools, admin dashboards, etc.), assign the
matching bundle instead of or in addition to `bundle-agent` — see the bundle table in
`access-control.md`.

---

## Step 2 — User Signs In

Have them visit `https://agent.photondatum.space`. Authentik's forwardAuth handles the
rest — no separate OpenWebUI login form exists (trusted-header SSO). They should land
directly in the chat interface on first visit.

---

## Step 3 — Verify Provisioning

Run this from CENTAURI, ideally right after they've told you they've signed in:

```bash
bash scripts/users.sh
```

Confirm:
- Their name/email appears in the list
- **Role is `user`**, not `pending` — if it shows `pending`, see [Troubleshooting](#troubleshooting--if-something-didnt-auto-provision)
- `last_active_at` is recent, confirming the sign-in actually completed

You do **not** need to check model visibility manually — the 11 local models are already
public to every `user`-role account by default (see [Background](#1-background--whats-automatic-now)).
If you want to double-check anyway:

```bash
podman exec openwebui python3 -c "
import sqlite3
conn = sqlite3.connect('/app/backend/data/webui.db')
print('published models:', conn.execute('SELECT COUNT(*) FROM model').fetchone()[0])
"
```
Should read `11` (or higher, if more local models have been added and published since).

---

## Step 4 — Point Them to the External-Models How-To

Cloud/paid models are **never** auto-granted, on purpose — they're billed to whoever's
key is behind them, and OpenWebUI has no way to meter usage per user on a shared key.
If the new person wants OpenAI, Groq, or Mistral, send them:

**[`external-models-howto.md`](external-models-howto.md)** — a self-service tutorial for
adding their own personal API key. No admin action required on your end for those three.

**Claude is the exception** — it isn't self-service (see that doc's note on why) and
isn't currently available to non-admin accounts at all. If someone needs Claude access,
that's a judgment call for you, not something this guide automates — decide whether to
extend the shared LiteLLM route to them or point them elsewhere.

---

## Troubleshooting — If Something Didn't Auto-Provision

| Symptom | Likely cause | Fix |
|---|---|---|
| `scripts/users.sh` shows `role=pending` | `DEFAULT_USER_ROLE` env var missing/reverted on the live `openwebui` container, or a stale DB-persisted value | Check `podman exec openwebui env \| grep DEFAULT_USER_ROLE`; one-time fix: Admin Panel → Users → set role to `User`. See lessons_learned.md [Lesson 7](lessons_learned.md#7-enable_signupfalse-does-not-block-trusted-header-auto-provisioning) and `CENTAURI-playbook.md` §13 L-25 |
| User sees "Account Activation Pending Contact Admin for WebUI Access" | Same as above | Same fix — this is OpenWebUI's own pending-role screen, not an Authentik error |
| User signs in but model dropdown is empty | The `model` table lost its published rows (shouldn't happen from normal operation, but check after a fresh volume restore or DB migration) | `CENTAURI-playbook.md` §11 "Non-admin OpenWebUI user sees an empty 'Select a model' dropdown" has the exact re-publish script |
| User can't reach `agent.photondatum.space` at all | Authentik-side — not assigned to a bundle, or bundle policy issue | `authentik/access-control.md`, not an OpenWebUI problem |

---

## Reference

- [`authentik/access-control.md`](../authentik/access-control.md) — invitation flows, bundle groups, application policies
- [`lessons_learned.md`](lessons_learned.md) — Lessons 1, 7, 8, 9, 10 cover the auth/provisioning mechanics referenced above in depth
- `output/CENTAURI-playbook.md` §13 (L-25–L-29) and §11 — operational troubleshooting entries with copy-paste commands
- [`external-models-howto.md`](external-models-howto.md) — hand this to the user once they're provisioned
