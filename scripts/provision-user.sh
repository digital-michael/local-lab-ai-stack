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
# Usage:
#   scripts/provision-user.sh --email new.person@example.com [--team "Family Group"]
#   scripts/provision-user.sh --email new.person@example.com        # lists teams, prompts for one
#
# Options:
#   --email EMAIL          Required. The invitee's email address.
#   --team NAME            Team to provision into. If omitted, lists the
#                          live-discovered teams and prompts for exactly one.
#   --expires-days N       Invitation validity in days (default: 7)
#   --authentik-url URL    Authentik base URL (default: https://auth.photondatum.space)
#   --token-secret NAME    Podman secret holding the Authentik API token
#                          (default: homepage_authentik_token)
#   --json                 Emit a structured JSON result instead of text
#   -h, --help             Show this message
#
# Exit codes:
#   0   Invitation created
#   1   Invalid input (bad email, unknown --team)
#   2   Environment/connectivity problem (podman, Authentik unreachable, no
#       teams discoverable)
#
# This is additive only — it never deletes or modifies an existing user,
# invitation, group, or flow. Re-running for the same email just creates
# another invitation.

set -euo pipefail

AUTHENTIK_URL="${AUTHENTIK_URL:-https://auth.photondatum.space}"
TOKEN_SECRET="${TOKEN_SECRET:-homepage_authentik_token}"
OPENWEBUI_CONTAINER="${OPENWEBUI_CONTAINER:-openwebui}"
EXPIRES_DAYS="${EXPIRES_DAYS:-7}"
EMAIL=""
TEAM=""
OUTPUT_FORMAT="text"

usage() {
    cat <<'EOF'
Usage: provision-user.sh --email EMAIL [options]

Purpose:
  Create a single-use Authentik invitation for a new OpenWebUI user,
  pre-bound to one team (an Authentik Group with its own dedicated
  invitation-capable enrollment flow, discovered live). Prints the
  resulting link for you to send — Authentik has no email stage
  configured, so nothing here sends mail itself. Also ensures a
  matching (empty) OpenWebUI Group exists for future model-visibility
  grants.

Options:
  --email EMAIL          Required. The invitee's email address.
  --team NAME            Team to provision into. If omitted, lists the
                         live-discovered teams and prompts for exactly one.
  --expires-days N       Invitation validity in days (default: 7)
  --authentik-url URL    Authentik base URL (default: https://auth.photondatum.space)
  --token-secret NAME    Podman secret holding the Authentik API token
                         (default: homepage_authentik_token)
  --json                 Emit a structured JSON result instead of text
  -h, --help             Show this message

Exit codes:
  0   Invitation created
  1   Invalid input (bad email, unknown --team)
  2   Environment/connectivity problem
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --email)         EMAIL="${2:?--email requires a value}"; shift 2 ;;
        --team)          TEAM="${2:?--team requires a value}"; shift 2 ;;
        --expires-days)  EXPIRES_DAYS="${2:?--expires-days requires a value}"; shift 2 ;;
        --authentik-url) AUTHENTIK_URL="${2:?--authentik-url requires a value}"; shift 2 ;;
        --token-secret)  TOKEN_SECRET="${2:?--token-secret requires a value}"; shift 2 ;;
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

if [[ -z "$EMAIL" ]]; then
    echo "ERROR: --email is required" >&2
    usage >&2
    exit 1
fi
if [[ ! "$EMAIL" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]]; then
    echo "ERROR: '$EMAIL' doesn't look like a valid email address" >&2
    exit 1
fi

TOKEN="$(podman secret inspect "$TOKEN_SECRET" --showsecret --format '{{.SecretData}}' 2>/dev/null || true)"
if [[ -z "$TOKEN" ]]; then
    echo "ERROR: could not read Authentik API token from Podman secret '$TOKEN_SECRET'" >&2
    exit 2
fi

export AUTHENTIK_URL TOKEN EMAIL TEAM EXPIRES_DAYS OUTPUT_FORMAT OPENWEBUI_CONTAINER

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


teams = discover_teams()
if not teams:
    print("ERROR: no team-capable invitation flows found in Authentik — nothing to provision into.", file=sys.stderr)
    sys.exit(2)

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
    },
)
invite_url = f"{AUTHENTIK_URL}/if/flow/{flow_slug}/?itoken={invitation['pk']}"

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
}

if OUTPUT_FORMAT == "json":
    print(json.dumps(result, indent=2))
else:
    print()
    print(f"Team:       {TEAM}")
    print(f"Email:      {EMAIL}")
    print(f"Expires:    {expires}")
    print(f"OpenWebUI Group: {openwebui_group_status}")
    print()
    print(f"Invite link (send this to {EMAIL} yourself — no email is sent automatically):")
    print(f"  {invite_url}")
PYEOF

python3 "$PY_SCRIPT"
