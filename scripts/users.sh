#!/usr/bin/env bash
# scripts/users.sh — OpenWebUI user activity report
#
# Lists every OpenWebUI account (name, email, role, last-active) and flags
# anyone active within a recent window. Meant to be run before anything that
# restarts or upgrades openwebui.service — check nobody's mid-session first.
#
# Exit codes:
#   0   No user active within the window — safe to restart
#   1   At least one user active within the window — hold off
#   2   openwebui container not running, or its DB could not be read

set -euo pipefail

CONTAINER="${OPENWEBUI_CONTAINER:-openwebui}"
ACTIVE_WINDOW_MIN="${ACTIVE_WINDOW_MIN:-5}"
OUTPUT_FORMAT="text"
USE_COLOR=0

usage() {
    cat <<'EOF'
Usage: users.sh [options]

Purpose:
  Report every OpenWebUI user's role and last-active time, and flag anyone
  active within a recent window (default 5 minutes). Run this before
  restarting or upgrading openwebui.service to check nobody's mid-session.

Options:
  --active-window <minutes>  Recency threshold for "active" (default: 5)
  --json                     Emit structured JSON instead of a table
  --color                    Highlight active users in the human-readable report
  -h, --help                 Show this message

Exit codes:
  0   No user active within the window — safe to restart
  1   At least one user active within the window — hold off
  2   openwebui container not running, or its DB could not be read

Environment:
  OPENWEBUI_CONTAINER   Container name to query  (default: openwebui)
  ACTIVE_WINDOW_MIN      Same as --active-window  (default: 5)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --active-window)
            ACTIVE_WINDOW_MIN="${2:?--active-window requires a value}"
            shift 2
            ;;
        --json)   OUTPUT_FORMAT="json"; shift ;;
        --color)  USE_COLOR=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if ! command -v podman &>/dev/null; then
    echo "ERROR: Required command not found: podman" >&2
    exit 2
fi

if ! podman container exists "$CONTAINER"; then
    echo "ERROR: container '$CONTAINER' not found — is openwebui.service running?" >&2
    exit 2
fi

export ACTIVE_WINDOW_MIN OUTPUT_FORMAT USE_COLOR

# The last command in the script — its exit code (0/1/2, set explicitly by
# the Python below) becomes users.sh's own exit code.
podman exec -i -e ACTIVE_WINDOW_MIN -e OUTPUT_FORMAT -e USE_COLOR "$CONTAINER" python3 <<'PYEOF'
import json
import os
import sqlite3
import sys
import time

ACTIVE_WINDOW_MIN = float(os.environ["ACTIVE_WINDOW_MIN"])
OUTPUT_FORMAT = os.environ["OUTPUT_FORMAT"]
USE_COLOR = os.environ.get("USE_COLOR") == "1"

BOLD = "\033[1m" if USE_COLOR else ""
GREEN = "\033[1;32m" if USE_COLOR else ""
RESET = "\033[0m" if USE_COLOR else ""

try:
    conn = sqlite3.connect("/app/backend/data/webui.db")
    rows = conn.execute(
        'SELECT name, email, role, last_active_at FROM "user" ORDER BY last_active_at DESC'
    ).fetchall()
except Exception as e:
    print(f"ERROR: could not read webui.db: {e}", file=sys.stderr)
    sys.exit(2)

def format_age(age_min: float) -> str:
    if age_min < 1:
        return "just now"
    if age_min < 60:
        return f"{age_min:.1f} min ago"
    age_hr = age_min / 60
    if age_hr < 24:
        return f"{age_hr:.1f} hours ago"
    age_day = age_hr / 24
    if age_day < 30:
        return f"{age_day:.1f} days ago"
    age_month = age_day / 30
    if age_month < 12:
        return f"{age_month:.1f} months ago"
    return f"{age_day / 365:.1f} years ago"


now = time.time()
users = []
any_active = False
for name, email, role, last_active in rows:
    age_min = (now - last_active) / 60 if last_active else None
    active = age_min is not None and age_min <= ACTIVE_WINDOW_MIN
    any_active = any_active or active
    users.append({
        "name": name,
        "email": email,
        "role": role,
        "last_active_at": (
            time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(last_active))
            if last_active else None
        ),
        "minutes_ago": round(age_min, 1) if age_min is not None else None,
        "active": active,
    })

if OUTPUT_FORMAT == "json":
    print(json.dumps({
        "checked_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now)),
        "active_window_minutes": ACTIVE_WINDOW_MIN,
        "any_active": any_active,
        "users": users,
    }, indent=2))
    sys.exit(1 if any_active else 0)

NAME_W, EMAIL_W, ROLE_W = 25, 35, 8
header = f"{'NAME':<{NAME_W}} {'EMAIL':<{EMAIL_W}} {'ROLE':<{ROLE_W}} LAST ACTIVE"
print(f"{BOLD}{header}{RESET}")
for u in users:
    if u["last_active_at"] is None:
        last = "never"
    else:
        last = f"{u['last_active_at']}  ({format_age(u['minutes_ago'])})"
    line = f"{u['name']:<{NAME_W}} {u['email']:<{EMAIL_W}} {u['role']:<{ROLE_W}} {last}"
    if u["active"]:
        line += "  <- ACTIVE"
        print(f"{GREEN}{line}{RESET}")
    else:
        print(line)

print()
if any_active:
    print(f"{BOLD}Someone is active within the last {ACTIVE_WINDOW_MIN:g} minutes — hold off on restarting openwebui.{RESET}")
else:
    print(f"No user active within the last {ACTIVE_WINDOW_MIN:g} minutes — safe to restart openwebui.")

sys.exit(1 if any_active else 0)
PYEOF
