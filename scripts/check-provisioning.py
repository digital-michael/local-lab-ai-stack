#!/usr/bin/env python3
"""scripts/check-provisioning.py — Authentik + OpenWebUI provisioning check

Purpose:
  Cross-check every real user across Authentik (auth.photondatum.space, the
  access gate) and OpenWebUI (this host, what they see once inside) and flag
  anyone not fully, correctly provisioned:

    Authentik side:
      - account exists and is_active (self-service social-login accounts
        land inactive until an admin approves them — this is the most
        common gap)
      - assigned to at least one group (an active account with zero groups
        can't pass any bundle access policy)

    OpenWebUI side:
      - account exists (auto-provisioned on first successful Authentik
        forwardAuth signin — its absence means the person has never
        actually gotten through, even if their Authentik account looks fine)
      - role is "user" or "admin", not stuck at "pending"
      - assigned to at least one OpenWebUI Group

  Deliberately generic on the "assigned to a group" checks — it does not
  require a *specific* group name on either side, just non-zero membership.
  See docs/library/framework_components/openwebui/provisioning-guide.md and
  docs/library/framework_components/authentik/access-control.md for what
  each side's groups are actually supposed to mean; that's a policy
  question to tighten later, not something this script enforces.

  Service/system accounts (the Authentik embedded-outpost service account,
  etc.) are excluded automatically — this is about human users.

Usage:
  check-provisioning.py [options]

Options:
  --email EMAIL          Check only this one email instead of every user
  --authentik-url URL    Authentik base URL (default: https://auth.photondatum.space)
  --token-secret NAME    Podman secret holding the Authentik API token
                          (default: homepage_authentik_token)
  --container NAME       OpenWebUI container name (default: openwebui)
  --timeout SECONDS      Per-request HTTP timeout (default: 10)
  --json                 Emit a structured JSON report instead of a table
  -h, --help             Show this message

Exit codes:
  0   Every real user is fully provisioned on both sides
  1   One or more provisioning gaps found
  2   Environment problem — couldn't reach podman/Authentik, token secret
      missing, or the openwebui container isn't running

This is read-only — it reports gaps, it does not activate accounts, assign
groups, or otherwise write to Authentik or OpenWebUI. Fixing a reported gap
is still a manual step (Authentik: Directory -> Users -> activate/assign
groups; OpenWebUI: Admin Panel -> Users/Groups), same as documented in
provisioning-guide.md.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any

DEFAULT_AUTHENTIK_URL = "https://auth.photondatum.space"
DEFAULT_TOKEN_SECRET = "homepage_authentik_token"
DEFAULT_CONTAINER = "openwebui"
DEFAULT_TIMEOUT = 10.0
PAGE_SIZE = 100

# Authentik account types that are infrastructure, not a human to provision.
SERVICE_ACCOUNT_TYPES = ("internal_service_account",)


@dataclass
class AuthentikUser:
    username: str
    email: str
    is_active: bool
    groups: list[str]


@dataclass
class OpenWebUIUser:
    name: str
    email: str
    role: str
    groups: list[str]


@dataclass
class Finding:
    email: str
    display_name: str
    problems: list[str] = field(default_factory=list)

    @property
    def ok(self) -> bool:
        return not self.problems


def podman(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["podman", *args], capture_output=True, text=True)


def get_podman_secret(name: str) -> str:
    r = podman("secret", "inspect", name, "--showsecret", "--format", "{{.SecretData}}")
    if r.returncode != 0:
        print(f"ERROR: could not read podman secret '{name}': {r.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    return r.stdout.strip()


def http_get_json(url: str, headers: dict[str, str], timeout: float) -> dict[str, Any]:
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        print(f"ERROR: Authentik API request failed: HTTP {e.code} for {url}", file=sys.stderr)
        sys.exit(2)
    except urllib.error.URLError as e:
        print(f"ERROR: could not reach Authentik at {url}: {e.reason}", file=sys.stderr)
        sys.exit(2)


def fetch_authentik_users(base_url: str, token: str, timeout: float) -> list[AuthentikUser]:
    headers = {"Authorization": f"Bearer {token}"}
    users: list[AuthentikUser] = []
    page = 1
    while True:
        data = http_get_json(
            f"{base_url}/api/v3/core/users/?page_size={PAGE_SIZE}&page={page}",
            headers, timeout,
        )
        for u in data.get("results", []):
            if u.get("type") in SERVICE_ACCOUNT_TYPES or u.get("username", "").startswith("ak-outpost-"):
                continue
            email = (u.get("email") or "").strip()
            if not email:
                continue
            users.append(AuthentikUser(
                username=u["username"],
                email=email,
                is_active=bool(u.get("is_active")),
                groups=[g["name"] for g in u.get("groups_obj", [])],
            ))
        pagination = data.get("pagination", {})
        if page >= pagination.get("total_pages", 1):
            break
        page += 1
    return users


def fetch_openwebui_users(container: str) -> list[OpenWebUIUser]:
    query_script = (
        "import json, sqlite3\n"
        "conn = sqlite3.connect('/app/backend/data/webui.db')\n"
        "rows = conn.execute('''\n"
        "    SELECT u.name, u.email, u.role, GROUP_CONCAT(g.name, ', ')\n"
        "    FROM \"user\" u\n"
        "    LEFT JOIN group_member gm ON gm.user_id = u.id\n"
        "    LEFT JOIN \"group\" g ON g.id = gm.group_id\n"
        "    GROUP BY u.id\n"
        "''').fetchall()\n"
        "print(json.dumps(rows))\n"
    )
    r = subprocess.run(
        ["podman", "exec", "-i", container, "python3", "-c", query_script],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        print(f"ERROR: could not read OpenWebUI's webui.db: {r.stderr.strip()}", file=sys.stderr)
        sys.exit(2)
    rows = json.loads(r.stdout)
    return [
        OpenWebUIUser(
            name=name,
            email=(email or "").strip(),
            role=role,
            groups=groups_csv.split(", ") if groups_csv else [],
        )
        for name, email, role, groups_csv in rows
    ]


def reconcile(
    authentik_users: list[AuthentikUser],
    openwebui_users: list[OpenWebUIUser],
    only_email: str | None,
) -> list[Finding]:
    by_email_ak = {u.email.lower(): u for u in authentik_users}
    by_email_ow = {u.email.lower(): u for u in openwebui_users}
    all_emails = sorted(set(by_email_ak) | set(by_email_ow))

    if only_email:
        target = only_email.lower()
        if target not in all_emails:
            print(f"ERROR: '{only_email}' not found in Authentik or OpenWebUI", file=sys.stderr)
            sys.exit(2)
        all_emails = [target]

    findings = []
    for email in all_emails:
        ak = by_email_ak.get(email)
        ow = by_email_ow.get(email)
        display_name = (ak.username if ak else None) or (ow.name if ow else email)
        problems: list[str] = []

        if ak is None:
            problems.append("has an OpenWebUI account but no matching Authentik account")
        else:
            if not ak.is_active:
                problems.append("Authentik account is inactive (self-service signup awaiting admin approval)")
            if not ak.groups:
                problems.append("Authentik account has no group assigned (cannot pass any bundle access policy)")

        if ow is None:
            problems.append("no OpenWebUI account yet (hasn't completed a signin, or Authentik access isn't effective)")
        else:
            if ow.role == "pending":
                problems.append("OpenWebUI role is stuck at 'pending'")
            elif ow.role not in ("user", "admin"):
                problems.append(f"OpenWebUI role is '{ow.role}' (unexpected)")
            if not ow.groups:
                problems.append("not assigned to any OpenWebUI group")

        findings.append(Finding(email=email, display_name=display_name, problems=problems))
    return findings


def print_report(findings: list[Finding]) -> None:
    ok = [f for f in findings if f.ok]
    bad = [f for f in findings if not f.ok]

    if ok:
        print(f"Fully provisioned ({len(ok)}):")
        for f in ok:
            print(f"  {f.display_name} <{f.email}>")
        print()

    if bad:
        print(f"Provisioning gaps ({len(bad)}):")
        for f in bad:
            print(f"  {f.display_name} <{f.email}>")
            for p in f.problems:
                print(f"    - {p}")
        print()

    print(f"{len(ok)} fully provisioned, {len(bad)} with gaps")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Cross-check Authentik + OpenWebUI for incompletely provisioned users.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Exit codes:\n"
            "  0   Every real user is fully provisioned\n"
            "  1   One or more provisioning gaps found\n"
            "  2   Environment problem (podman, Authentik, token secret, or container missing)\n"
        ),
    )
    parser.add_argument("--email", default=None, help="Check only this one email")
    parser.add_argument("--authentik-url", default=DEFAULT_AUTHENTIK_URL, help=f"Authentik base URL (default: {DEFAULT_AUTHENTIK_URL})")
    parser.add_argument("--token-secret", default=DEFAULT_TOKEN_SECRET, help=f"Podman secret with the Authentik API token (default: {DEFAULT_TOKEN_SECRET})")
    parser.add_argument("--container", default=DEFAULT_CONTAINER, help=f"OpenWebUI container name (default: {DEFAULT_CONTAINER})")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help=f"Per-request HTTP timeout in seconds (default: {DEFAULT_TIMEOUT:g})")
    parser.add_argument("--json", action="store_true", help="Emit a structured JSON report instead of a table")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if shutil.which("podman") is None:
        print("ERROR: required command not found: podman", file=sys.stderr)
        return 2

    exists = podman("container", "exists", args.container)
    if exists.returncode != 0:
        print(f"ERROR: container '{args.container}' not found — is openwebui.service running?", file=sys.stderr)
        return 2

    token = get_podman_secret(args.token_secret)
    authentik_users = fetch_authentik_users(args.authentik_url, token, args.timeout)
    openwebui_users = fetch_openwebui_users(args.container)
    findings = reconcile(authentik_users, openwebui_users, args.email)

    if args.json:
        print(json.dumps({
            "findings": [
                {"email": f.email, "display_name": f.display_name, "problems": f.problems, "ok": f.ok}
                for f in findings
            ],
            "fully_provisioned": sum(1 for f in findings if f.ok),
            "with_gaps": sum(1 for f in findings if not f.ok),
        }, indent=2))
    else:
        print_report(findings)

    return 0 if all(f.ok for f in findings) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
