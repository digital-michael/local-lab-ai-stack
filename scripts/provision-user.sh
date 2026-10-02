#!/usr/bin/env bash
# scripts/provision-user.sh
#
# Creates a single-use Authentik invitation for a new OpenWebUI
# (agent.photondatum.space) user, pre-bound to exactly one team.
#
# "Team" here means an existing Authentik Group that already has its own
# dedicated invitation-capable enrollment flow — one whose first stage is an
# Invitation stage and whose User Write stage has create_users_group set to
# that team's group. That combination is what makes "already configured by
# first login" literally true: Authentik's own UserWriteStage puts the new
# account straight into the right group as part of account creation itself,
# no separate admin step afterward. Teams are discovered live from Authentik
# on every run (GET /api/v3/stages/user_write/) — nothing hardcoded — so a
# future team becomes selectable the moment its flow exists, with zero
# changes needed here. See docs/library/framework_components/authentik/
# access-control.md and output/CENTAURI-playbook.md §13 L-40.
#
# Authentik has no email-sending stage configured in this instance (checked
# directly — zero exist), so this script cannot email the invitation itself;
# it prints the generated single-use link for you to send however you like,
# matching the existing documented workflow in
# docs/library/framework_components/openwebui/provisioning-guide.md.
#
# Also ensures a matching OpenWebUI Group exists (by team name, empty — no
# model grants) so the team's model-visibility plumbing is ready whenever
# that's decided later; this is independent of Authentik's group of the same
# name and isn't populated with members automatically (OpenWebUI's own user
# row doesn't exist until the person's first successful signin, so there's
# nothing to add as a member yet at invitation time).
#
# --send emails the invite link immediately after creating it, via a real
# SMTP relay — a Podman secret (JSON: host/port/username/password/from/
# use_tls), name given by --smtp-secret (default: photondatum_smtp). Default
# behavior with no --send is unchanged: print the link, send nothing. Every
# invitation this script creates gets its invitee email and a "sent" flag
# recorded in Authentik's own Invitation.fixed_data field (otherwise empty
# and unused) — that's what --see-queue reads back later.
#
# Every email sent (--send or a later --see-queue send) is Bcc'd to the
# secret's own "from" address by default (invites@photondatum.space), as a
# durable audit log of invites sent — the invitee never sees this header.
# Override with an "audit_bcc" key in the SMTP secret, or "" to disable.
#
# --see-queue (used instead of --email, not together with it) lists every
# invitation this script has created that's still unexpired and not yet
# marked sent, then loops on three options: delete one item (by number,
# immediate — deletes the real Authentik Invitation, not staged), send
# everything still left, or abort with no changes. The "come back and
# actually send these later" half of the same --send mechanism, for
# anything created without --send in the first place.
#
# Usage:
#   scripts/provision-user.sh --email new.person@example.com [--team "Family Group"] [--send]
#   scripts/provision-user.sh --email new.person@example.com        # lists teams, prompts for one
#   scripts/provision-user.sh --see-queue                           # lists pending, prompts to send all
#
# Options:
#   --email EMAIL          The invitee's email address. Required unless --see-queue.
#   --team NAME            Team to provision into. If omitted, lists the
#                          live-discovered teams and prompts for exactly one.
#   --send                 Email the invite link immediately via SMTP
#                          (default: leave unsent, just print the link).
#   --see-queue            List pending (unsent, unexpired) invitations and
#                          loop: delete an item by number, send all, or
#                          abort. Used instead of --email, not together
#                          with it.
#   --expires-days N       Invitation validity in days (default: 7)
#   --authentik-url URL    Authentik base URL (default: https://auth.photondatum.space)
#   --token-secret NAME    Podman secret holding the Authentik API token
#                          (default: homepage_authentik_token)
#   --smtp-secret NAME     Podman secret holding SMTP credentials, as JSON
#                          (default: photondatum_smtp)
#   --json                 Emit a structured JSON result instead of text
#                          (--see-queue --json lists only, never prompts/sends)
#   -h, --help             Show this message
#
# Exit codes:
#   0   Invitation created (or queue listed/handled) successfully
#   1   Invalid input (bad email, unknown --team, both/neither --email and --see-queue)
#   2   Environment/connectivity problem (podman, Authentik unreachable, no
#       teams discoverable, or --send/queue-send requested but SMTP failed)
#
# This is additive only — it never deletes or modifies an existing user,
# invitation, group, or flow (--see-queue's "send" only PATCHes an
# invitation's own fixed_data.sent flag, never its email/team/expiry).
# Re-running for the same email just creates another invitation.

set -euo pipefail

AUTHENTIK_URL="${AUTHENTIK_URL:-https://auth.photondatum.space}"
TOKEN_SECRET="${TOKEN_SECRET:-homepage_authentik_token}"
SMTP_SECRET="${SMTP_SECRET:-photondatum_smtp}"
OPENWEBUI_CONTAINER="${OPENWEBUI_CONTAINER:-openwebui}"
EXPIRES_DAYS="${EXPIRES_DAYS:-7}"
EMAIL=""
TEAM=""
SEND=0
SEE_QUEUE=0
OUTPUT_FORMAT="text"

usage() {
    cat <<'EOF'
Usage: provision-user.sh --email EMAIL [options]
       provision-user.sh --see-queue [--json]

Purpose:
  Create a single-use Authentik invitation for a new OpenWebUI user,
  pre-bound to one team (an Authentik Group with its own dedicated
  invitation-capable enrollment flow, discovered live). Prints the
  resulting link for you to send by default; --send emails it
  immediately instead, via a real SMTP relay (Podman secret, JSON).
  Also ensures a matching (empty) OpenWebUI Group exists for future
  model-visibility grants.

  --see-queue (instead of --email) lists invitations this tool created
  that are still unexpired and not yet marked sent, then loops: delete
  an item by number, send everything still left, or abort.

Options:
  --email EMAIL          The invitee's email address. Required unless --see-queue.
  --team NAME            Team to provision into. If omitted, lists the
                         live-discovered teams and prompts for exactly one.
  --send                 Email the invite link immediately via SMTP
                         (default: leave unsent, just print the link).
                         Bcc'd to the secret's "from" address by default
                         as an audit log (see "audit_bcc" below).
  --see-queue            List pending invitations; loop: delete an item
                         by number, send all, or abort. Used instead of
                         --email.
  --expires-days N       Invitation validity in days (default: 7)
  --authentik-url URL    Authentik base URL (default: https://auth.photondatum.space)
  --token-secret NAME    Podman secret holding the Authentik API token
                         (default: homepage_authentik_token)
  --smtp-secret NAME     Podman secret holding SMTP credentials, as JSON
                         (default: photondatum_smtp)
  --json                 Emit a structured JSON result instead of text
                         (--see-queue --json lists only, never prompts/sends)
  -h, --help             Show this message

Exit codes:
  0   Invitation created (or queue listed/handled) successfully
  1   Invalid input (bad email, unknown --team, both/neither --email and --see-queue)
  2   Environment/connectivity problem (including --send/queue-send SMTP failure)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)         EMAIL="${2:?--email requires a value}"; shift 2 ;;
        --team)          TEAM="${2:?--team requires a value}"; shift 2 ;;
        --send)          SEND=1; shift ;;
        --see-queue)     SEE_QUEUE=1; shift ;;
        --expires-days)  EXPIRES_DAYS="${2:?--expires-days requires a value}"; shift 2 ;;
        --authentik-url) AUTHENTIK_URL="${2:?--authentik-url requires a value}"; shift 2 ;;
        --token-secret)  TOKEN_SECRET="${2:?--token-secret requires a value}"; shift 2 ;;
        --smtp-secret)   SMTP_SECRET="${2:?--smtp-secret requires a value}"; shift 2 ;;
        --json)          OUTPUT_FORMAT="json"; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

for cmd in curl jq podman python3; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 2
    fi
done

if [[ "$SEE_QUEUE" == "1" && -n "$EMAIL" ]]; then
    echo "ERROR: --see-queue and --email are mutually exclusive — use one or the other" >&2
    exit 1
fi
if [[ "$SEE_QUEUE" == "0" && -z "$EMAIL" ]]; then
    echo "ERROR: --email is required (or use --see-queue)" >&2
    usage >&2
    exit 1
fi
if [[ -n "$EMAIL" && ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "ERROR: '$EMAIL' doesn't look like a valid email address" >&2
    exit 1
fi

TOKEN="$(podman secret inspect "$TOKEN_SECRET" --showsecret --format '{{.SecretData}}' 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
    echo "ERROR: could not read Authentik API token from Podman secret '$TOKEN_SECRET'" >&2
    exit 2
fi

export AUTHENTIK_URL TOKEN EMAIL TEAM EXPIRES_DAYS OUTPUT_FORMAT OPENWEBUI_CONTAINER
export SEND SEE_QUEUE SMTP_SECRET

# Written to a temp file rather than piped in via <<'PYEOF' directly: a
# heredoc replaces the invoked command's stdin with the heredoc's own text,
# which would make input() below hit EOF immediately instead of ever
# reaching the real terminal (or whatever's actually piped into this script).
PY_SCRIPT="$(mktemp)"
trap 'rm -f "$PY_SCRIPT"' EXIT
cat > "$PY_SCRIPT" <<'PYEOF'
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

AUTHENTIK_URL = os.environ["AUTHENTIK_URL"].rstrip("/")
TOKEN = os.environ["TOKEN"]
EMAIL = os.environ["EMAIL"]
TEAM = os.environ.get("TEAM", "")
EXPIRES_DAYS = float(os.environ["EXPIRES_DAYS"])
OUTPUT_FORMAT = os.environ["OUTPUT_FORMAT"]
OPENWEBUI_CONTAINER = os.environ["OPENWEBUI_CONTAINER"]
SEND = os.environ.get("SEND") == "1"
SEE_QUEUE = os.environ.get("SEE_QUEUE") == "1"
SMTP_SECRET = os.environ["SMTP_SECRET"]


def ak(path, method="GET", body=None):
    url = f"{AUTHENTIK_URL}{path}"
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        print(f"ERROR: Authentik API {method} {path} failed: HTTP {e.code} {e.read().decode()[:300]}", file=sys.stderr)
        sys.exit(2)
    except urllib.error.URLError as e:
        print(f"ERROR: could not reach Authentik at {AUTHENTIK_URL}: {e.reason}", file=sys.stderr)
        sys.exit(2)


def ak_paginated(path):
    results = []
    page = 1
    while True:
        data = ak(f"{path}{'&' if '?' in path else '?'}page_size=100&page={page}")
        results.extend(data.get("results", []))
        pagination = data.get("pagination", {})
        if page >= pagination.get("total_pages", 1):
            break
        page += 1
    return results


# ---------------------------------------------------------------------------
# Discover teams: every UserWriteStage with create_users_group set, whose
# owning flow's first stage (order 0) is an Invitation stage. That's the
# exact, complete signature of "an admin-provisioned invite that lands the
# new account straight into group X" — nothing hardcoded, so a newly built
# team flow is selectable immediately, with zero changes to this script.
# ---------------------------------------------------------------------------
def discover_teams():
    teams = {}
    for stage in ak_paginated("/api/v3/stages/user_write/?"):
        group_pk = stage.get("create_users_group")
        flows = stage.get("flow_set") or []
        if not group_pk or not flows:
            continue
        flow = flows[0]
        bindings = ak_paginated(f"/api/v3/flows/bindings/?target={flow['pk']}&ordering=order&")
        first = next((b for b in bindings if b.get("order") == 0), None)
        first_stage = (first or {}).get("stage_obj") or {}
        if first_stage.get("component") != "ak-stage-invitation-form":
            continue
        group = ak(f"/api/v3/core/groups/{group_pk}/")
        teams[group["name"]] = {"flow_pk": flow["pk"], "flow_slug": flow["slug"]}
    return teams


# ---------------------------------------------------------------------------
# SMTP sending. Authentik has no email stage configured in this instance
# (checked directly — zero exist), so actually emailing anything is this
# script's own job, not Authentik's. Credentials come from a Podman secret
# (JSON: host, port, username, password, from, optional use_tls — default
# true) rather than config.json, matching this stack's existing convention
# of keeping real credentials out of tracked config entirely.
# ---------------------------------------------------------------------------
def resolve_smtp_credentials():
    r = subprocess.run(
        ["podman", "secret", "inspect", SMTP_SECRET, "--showsecret", "--format", "{{.SecretData}}"],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"ERROR: could not read SMTP credentials from Podman secret '{SMTP_SECRET}' — "
              f"create it first, e.g.:\n"
              f"  echo '{{\"host\":\"...\",\"port\":587,\"username\":\"...\",\"password\":\"...\",\"from\":\"...\"}}' "
              f"| podman secret create {SMTP_SECRET} -", file=sys.stderr)
        return None
    try:
        return json.loads(r.stdout)
    except json.JSONDecodeError as e:
        print(f"ERROR: Podman secret '{SMTP_SECRET}' isn't valid JSON: {e}", file=sys.stderr)
        return None


def send_invite_email(to_email, team, invite_url, expires):
    creds = resolve_smtp_credentials()
    if creds is None:
        return False
    import smtplib
    from email.message import EmailMessage

    msg = EmailMessage()
    msg["Subject"] = f"You're invited to join {team} on agent.photondatum.space"
    msg["From"] = creds["from"]
    msg["To"] = to_email
    # Audit-log copy: Bcc defaults to the same mailbox we send from
    # (invites@photondatum.space), so every invite leaves a durable trail
    # there. smtplib.send_message() resolves Bcc into the real recipient
    # list but strips the header before the wire send, so the invitee never
    # sees it. Override via an "audit_bcc" key in the SMTP secret, or set it
    # to "" to disable.
    audit_bcc = creds.get("audit_bcc", creds["from"])
    if audit_bcc:
        msg["Bcc"] = audit_bcc
    msg.set_content(
        f"You've been invited to join '{team}' on agent.photondatum.space.\n\n"
        f"Use this link to create your account (expires {expires}):\n{invite_url}\n\n"
        f"This link is single-use — if it's already been used, ask whoever invited you for a new one."
    )
    try:
        with smtplib.SMTP(creds["host"], int(creds.get("port", 587)), timeout=15) as s:
            if creds.get("use_tls", True):
                s.starttls()
            if creds.get("username"):
                s.login(creds["username"], creds["password"])
            s.send_message(msg)
        return True
    except Exception as e:
        print(f"ERROR: failed to send via SMTP ({creds.get('host')}): {e}", file=sys.stderr)
        return False


# ---------------------------------------------------------------------------
# --see-queue: every invitation this tool created (identified by having a
# fixed_data.email key at all — Authentik's own invitations otherwise never
# set fixed_data) that isn't expired and isn't already marked sent.
# ---------------------------------------------------------------------------
def discover_pending_invitations(teams_by_flow_pk):
    now = datetime.now(timezone.utc)
    pending = []
    for inv in ak_paginated("/api/v3/stages/invitation/invitations/?"):
        fixed = inv.get("fixed_data") or {}
        if "email" not in fixed or fixed.get("sent"):
            continue
        expires = inv.get("expires")
        if expires:
            try:
                if datetime.fromisoformat(expires.replace("Z", "+00:00")) < now:
                    continue
            except ValueError:
                pass
        flow_pk = inv.get("flow")
        team_name = teams_by_flow_pk.get(flow_pk, "(unknown team)")
        pending.append({
            "pk": inv["pk"],
            "email": fixed["email"],
            "team": team_name,
            "expires": expires,
            "flow_slug": (inv.get("flow_obj") or {}).get("slug", ""),
        })
    return pending


teams = discover_teams()
if not teams:
    print("ERROR: no team-capable invitation flows found in Authentik — nothing to provision into.", file=sys.stderr)
    sys.exit(2)

if SEE_QUEUE:
    teams_by_flow_pk = {v["flow_pk"]: k for k, v in teams.items()}
    pending = discover_pending_invitations(teams_by_flow_pk)

    if OUTPUT_FORMAT == "json":
        print(json.dumps(pending, indent=2))
        sys.exit(0)

    if not pending:
        print("No pending (unsent, unexpired) invitations.")
        sys.exit(0)

    # Loop: delete zero or more items first (each one real and immediate —
    # not staged for later), then either send everything still left or abort
    # with no further changes. Re-shows the list after every delete so it's
    # always clear what "send all" is actually about to act on.
    while True:
        print(f"\nPending invitations ({len(pending)}):")
        for i, p in enumerate(pending, 1):
            print(f"  {i}) {p['email']:<35} team={p['team']:<15} expires={p['expires']}")

        choice = input("\n[S]end all, [D]<#> delete one (e.g. D2), [A]bort: ").strip().lower()

        if choice in ("a", "abort", ""):
            print("Aborted — no changes made.")
            sys.exit(0)
        if choice in ("s", "send", "send all"):
            break

        m = re.match(r"^d\s*(\d+)$", choice)
        if not m:
            print(f"'{choice}' not understood — use S, D<#> (e.g. D2), or A.")
            continue
        idx = int(m.group(1))
        if not (1 <= idx <= len(pending)):
            print(f"'{idx}' is not a valid item number.")
            continue
        target = pending.pop(idx - 1)
        ak(f"/api/v3/stages/invitation/invitations/{target['pk']}/", method="DELETE")
        print(f"Deleted invitation for {target['email']}.")
        if not pending:
            print("No pending invitations left.")
            sys.exit(0)

    sent, failed = 0, 0
    for p in pending:
        invite_url = f"{AUTHENTIK_URL}/if/flow/{p['flow_slug']}/?itoken={p['pk']}"
        if send_invite_email(p["email"], p["team"], invite_url, p["expires"]):
            ak(f"/api/v3/stages/invitation/invitations/{p['pk']}/", method="PATCH",
               body={"fixed_data": {"email": p["email"], "sent": True}})
            print(f"  sent: {p['email']}")
            sent += 1
        else:
            print(f"  FAILED: {p['email']}")
            failed += 1
    print(f"\n{sent} sent, {failed} failed.")
    sys.exit(2 if failed else 0)

if TEAM:
    match = next((name for name in teams if name.lower() == TEAM.lower()), None)
    if not match:
        print(f"ERROR: '{TEAM}' is not a known team. Available: {', '.join(sorted(teams))}", file=sys.stderr)
        sys.exit(1)
    TEAM = match
else:
    names = sorted(teams)
    print("Available teams:")
    for i, name in enumerate(names, 1):
        print(f"  {i}) {name}")
    choice = input(f"Select a team [1-{len(names)}]: ").strip()
    try:
        idx = int(choice)
        if not (1 <= idx <= len(names)):
            raise ValueError
    except ValueError:
        print(f"ERROR: '{choice}' is not a valid selection.", file=sys.stderr)
        sys.exit(1)
    TEAM = names[idx - 1]

flow_pk = teams[TEAM]["flow_pk"]
flow_slug = teams[TEAM]["flow_slug"]

# Light heads-up only, not a blocker: an existing Authentik account for this
# email means the invitation will just sign them back in as themselves —
# UserWriteStage's create_when_required mode only assigns the team group at
# *account creation*, so it won't retroactively add an existing user to a
# new team.
existing = ak_paginated(f"/api/v3/core/users/?email={urllib.parse.quote(EMAIL)}&")
if existing:
    print(f"NOTE: an Authentik account already exists for {EMAIL} — this invitation will not add them to '{TEAM}' if they already have an account; it'll just sign them in as themselves.", file=sys.stderr)

# ---------------------------------------------------------------------------
# Create the invitation
# ---------------------------------------------------------------------------
expires = (datetime.now(timezone.utc) + timedelta(days=EXPIRES_DAYS)).strftime("%Y-%m-%dT%H:%M:%SZ")
invitation = ak(
    "/api/v3/stages/invitation/invitations/", method="POST",
    body={
        "name": re.sub(r"[^a-z0-9_-]+", "-", f"{TEAM}-{EMAIL}-{int(time.time())}".lower()).strip("-"),
        "flow": flow_pk,
        "single_use": True,
        "expires": expires,
        # Only place this invitation's email/sent-state lives — Authentik's
        # own Invitation model has no such fields, and this is the one it
        # leaves free for exactly this kind of caller-defined data. --see-queue
        # finds anything here with "sent" still false and not expired.
        "fixed_data": {"email": EMAIL, "sent": False},
    },
)
invite_url = f"{AUTHENTIK_URL}/if/flow/{flow_slug}/?itoken={invitation['pk']}"

sent_status = "not sent (default — use --send or --see-queue later)"
if SEND:
    if send_invite_email(EMAIL, TEAM, invite_url, expires):
        ak(f"/api/v3/stages/invitation/invitations/{invitation['pk']}/", method="PATCH",
           body={"fixed_data": {"email": EMAIL, "sent": True}})
        sent_status = "sent"
    else:
        sent_status = "FAILED to send — invitation was still created; link is valid, send it yourself or retry via --see-queue"

# ---------------------------------------------------------------------------
# Ensure a matching (empty) OpenWebUI Group exists — independent of
# Authentik's group of the same name, and not populated with members yet:
# OpenWebUI's own user row doesn't exist until this person's first
# successful signin, so there's nothing to add as a member at invitation
# time. Best-effort: skipped gracefully if the container isn't running.
# ---------------------------------------------------------------------------
openwebui_group_status = "skipped (openwebui container not running)"
ps = subprocess.run(["podman", "ps", "--format", "{{.Names}}"], capture_output=True, text=True)
if OPENWEBUI_CONTAINER in ps.stdout.splitlines():
    query_script = f"""
import sqlite3, time, uuid
conn = sqlite3.connect('/app/backend/data/webui.db')
c = conn.cursor()
c.execute('SELECT id FROM "group" WHERE name=?', ({TEAM!r},))
row = c.fetchone()
if row:
    print('already existed')
else:
    c.execute("SELECT id FROM user WHERE role='admin' ORDER BY created_at ASC LIMIT 1")
    owner_row = c.fetchone()
    owner = owner_row[0] if owner_row else None
    now = int(time.time())
    c.execute(
        'INSERT INTO "group" (id, user_id, name, description, data, meta, permissions, created_at, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)',
        (str(uuid.uuid4()), owner, {TEAM!r}, 'Created by provision-user.sh', '{{}}', '{{}}', '{{}}', now, now)
    )
    conn.commit()
    print('created')
"""
    r = subprocess.run(
        ["podman", "exec", "-i", OPENWEBUI_CONTAINER, "python3", "-c", query_script],
        capture_output=True, text=True,
    )
    if r.returncode == 0:
        openwebui_group_status = r.stdout.strip() or "unknown"
    else:
        openwebui_group_status = f"error: {r.stderr.strip()[:200]}"

result = {
    "email": EMAIL,
    "team": TEAM,
    "invite_url": invite_url,
    "expires": expires,
    "openwebui_group": openwebui_group_status,
    "sent": sent_status,
}

if OUTPUT_FORMAT == "json":
    print(json.dumps(result, indent=2))
else:
    print()
    print(f"Team:       {TEAM}")
    print(f"Email:      {EMAIL}")
    print(f"Expires:    {expires}")
    print(f"OpenWebUI Group: {openwebui_group_status}")
    print(f"Sent:       {sent_status}")
    print()
    if SEND and sent_status == "sent":
        print(f"Invite link (already emailed to {EMAIL}):")
    else:
        print(f"Invite link (send this to {EMAIL} yourself — no email is sent automatically):")
    print(f"  {invite_url}")

if SEND and sent_status.startswith("FAILED"):
    sys.exit(2)
PYEOF

python3 "$PY_SCRIPT"
