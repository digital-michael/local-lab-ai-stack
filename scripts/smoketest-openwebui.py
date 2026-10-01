#!/usr/bin/env python3
"""scripts/smoketest-openwebui.py — OpenWebUI post-change smoke test

Purpose:
  Verify OpenWebUI is actually working after a restart, upgrade, or config
  change — not just "container is healthy" but the things that have broken
  in practice on this stack: trusted-header SSO, the model list, existing
  chat history surviving a DB migration, and the Authentik signout redirect.
  Grew out of the manual curl checks run by hand after the v0.8.10 -> v0.11.3
  upgrade (2026-09-16) — this is that same sequence, captured so it doesn't
  have to be reconstructed by hand for the next version bump.

  Deliberately asserts nothing about a specific OpenWebUI version. Reads
  actual expected values (ports, trusted-header names, signout redirect URL)
  from config.json, so it keeps working as that file changes across
  versions rather than needing to be re-hardcoded each upgrade.

Usage:
  smoketest-openwebui.py --email you@example.com [options]

Options:
  --email EMAIL         Trusted-header identity to sign in as (required)
  --name NAME           Display name to send via the trusted name header
                         (default: derived from --email)
  --config PATH         Path to config.json (default: ~/ai-stack/configs/config.json)
  --base-url URL        Override the computed base URL (default: derived
                         from config.json's openwebui host port)
  --container NAME      Container name (default: openwebui)
  --timeout SECONDS     Per-request HTTP timeout (default: 10)
  --skip-logs           Skip the container-log error scan
  --json                Emit a structured JSON report instead of a table
  -h, --help            Show this message

Exit codes:
  0   All checks passed
  1   One or more checks failed
  2   Environment/config problem — couldn't reach podman, config.json missing
      or malformed, or the container isn't running at all

Run this any time you want confidence OpenWebUI is actually working, not
just "the container came up" — most obviously right after restarting it
for a version bump, but just as usable as a general health check. Check
scripts/users.sh first if the run would involve a restart — this script
does not check for active sessions.
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any

DEFAULT_CONFIG_PATH = Path.home() / "ai-stack" / "configs" / "config.json"
DEFAULT_CONTAINER = "openwebui"
DEFAULT_TIMEOUT = 10.0

# Log lines containing these substrings are ignored by the log-scan check —
# known-benign noise from dependencies, unrelated to app correctness. Extend
# this list as new dependency warnings show up, rather than loosening the
# ERROR/Traceback/Exception match itself.
BENIGN_LOG_PATTERNS = (
    "FutureWarning",
    "grpcio",
)


@dataclass
class CheckResult:
    name: str
    passed: bool
    detail: str
    skipped: bool = False


@dataclass
class Context:
    base_url: str
    container: str
    email: str
    name: str
    timeout: float
    config: dict[str, Any]
    token: str | None = None
    role: str | None = None
    version: str | None = None


def load_config(path: Path) -> dict[str, Any]:
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        print(f"ERROR: config not found at {path}", file=sys.stderr)
        sys.exit(2)
    except json.JSONDecodeError as e:
        print(f"ERROR: config at {path} is not valid JSON: {e}", file=sys.stderr)
        sys.exit(2)


def openwebui_block(config: dict[str, Any]) -> dict[str, Any]:
    try:
        return config["services"]["openwebui"]
    except KeyError:
        print("ERROR: config.json has no services.openwebui block", file=sys.stderr)
        sys.exit(2)


def default_base_url(config: dict[str, Any]) -> str:
    ports = openwebui_block(config).get("ports") or []
    if not ports:
        print("ERROR: services.openwebui.ports is empty in config.json", file=sys.stderr)
        sys.exit(2)
    p = ports[0]
    host = p.get("bind") or "127.0.0.1"
    return f"http://{host}:{p['host']}"


def bearer(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def http_request(
    method: str,
    url: str,
    headers: dict[str, str] | None = None,
    body: dict[str, Any] | None = None,
    timeout: float = DEFAULT_TIMEOUT,
) -> tuple[int, bytes]:
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            return resp.status, resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read()
    except urllib.error.URLError as e:
        raise ConnectionError(str(e.reason)) from e


def podman(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(["podman", *args], capture_output=True, text=True)


def user_exists(ctx: Context) -> bool:
    # A direct read of webui.db, not the API — this runs *before* any signin
    # attempt (to decide whether one is safe), so there's no admin session
    # yet to call GET /api/v1/users with.
    query_script = (
        "import sqlite3, sys\n"
        "conn = sqlite3.connect('/app/backend/data/webui.db')\n"
        "row = conn.execute('SELECT 1 FROM \"user\" WHERE lower(email) = lower(?)', (sys.argv[1],)).fetchone()\n"
        "print(1 if row else 0)\n"
    )
    r = subprocess.run(
        ["podman", "exec", "-i", ctx.container, "python3", "-c", query_script, ctx.email],
        capture_output=True, text=True,
    )
    return r.returncode == 0 and r.stdout.strip() == "1"


# --- checks -------------------------------------------------------------
# Each check takes the shared Context, may read/write it (signin populates
# ctx.token/role for downstream checks), and returns one CheckResult. A
# check with no token available reports itself skipped rather than failed —
# one upstream failure (signin) shouldn't read as four separate failures.

def check_container_running(ctx: Context) -> CheckResult:
    r = podman(
        "inspect", ctx.container,
        "--format", "{{.State.Status}}|{{.State.Health.Status}}",
    )
    if r.returncode != 0:
        return CheckResult("container running", False, r.stderr.strip() or "podman inspect failed")
    status, _, health = r.stdout.strip().partition("|")
    if status != "running":
        return CheckResult("container running", False, f"state={status}")
    return CheckResult("container running", True, f"state=running health={health or 'n/a'}")


def check_version_endpoint(ctx: Context) -> CheckResult:
    try:
        status, raw = http_request("GET", f"{ctx.base_url}/api/version", timeout=ctx.timeout)
    except ConnectionError as e:
        return CheckResult("version endpoint", False, str(e))
    if status != 200:
        return CheckResult("version endpoint", False, f"HTTP {status}")
    ctx.version = json.loads(raw).get("version", "unknown")
    return CheckResult("version endpoint", True, f"reports v{ctx.version}")


def check_health_endpoint(ctx: Context) -> CheckResult:
    try:
        status, _ = http_request("GET", f"{ctx.base_url}/health", timeout=ctx.timeout)
    except ConnectionError as e:
        return CheckResult("health endpoint", False, str(e))
    return CheckResult("health endpoint", status == 200, f"HTTP {status}")


def check_sso_signin(ctx: Context) -> CheckResult:
    env = openwebui_block(ctx.config).get("environment", {})
    email_header = env.get("WEBUI_AUTH_TRUSTED_EMAIL_HEADER")
    if not email_header:
        return CheckResult(
            "SSO signin", False,
            "WEBUI_AUTH_TRUSTED_EMAIL_HEADER not set in config.json — trusted-header auth not in use",
            skipped=True,
        )

    # Trusted-header auth auto-provisions a brand-new account for any email
    # that doesn't already exist (WebUI's enable_signup=false does not block
    # this path — see docs/library/framework_components/openwebui/
    # lessons_learned.md #7). Refuse to sign in as an unknown email rather
    # than silently creating a real account as a side effect of a smoke test.
    if not user_exists(ctx):
        return CheckResult(
            "SSO signin", False,
            f"{ctx.email!r} has no existing account — refusing to sign in "
            "(trusted-header auth would auto-provision a new real user)",
        )

    name_header = env.get("WEBUI_AUTH_TRUSTED_NAME_HEADER")

    headers = {email_header: ctx.email, "Content-Type": "application/json"}
    if name_header:
        headers[name_header] = ctx.name

    # SigninForm's email/password fields are validated before the
    # trusted-header branch runs, so a body is required even though the
    # password value itself is never checked under trusted-header auth.
    body = {"email": ctx.email, "password": "smoketest"}
    try:
        status, raw = http_request(
            "POST", f"{ctx.base_url}/api/v1/auths/signin",
            headers=headers, body=body, timeout=ctx.timeout,
        )
    except ConnectionError as e:
        return CheckResult("SSO signin", False, str(e))
    if status != 200:
        return CheckResult("SSO signin", False, f"HTTP {status}: {raw[:200]!r}")

    data = json.loads(raw)
    if data.get("email", "").lower() != ctx.email.lower():
        return CheckResult("SSO signin", False, f"signed in as {data.get('email')!r}, expected {ctx.email!r}")
    ctx.token = data.get("token")
    ctx.role = data.get("role")
    if not ctx.token:
        return CheckResult("SSO signin", False, "200 response but no token in body")
    return CheckResult("SSO signin", True, f"role={ctx.role}")


def check_models_list(ctx: Context) -> CheckResult:
    if not ctx.token:
        return CheckResult("models list", False, "no session token (signin failed)", skipped=True)
    try:
        status, raw = http_request("GET", f"{ctx.base_url}/api/models", headers=bearer(ctx.token), timeout=ctx.timeout)
    except ConnectionError as e:
        return CheckResult("models list", False, str(e))
    if status != 200:
        return CheckResult("models list", False, f"HTTP {status}")
    count = len(json.loads(raw).get("data", []))
    return CheckResult("models list", count > 0, f"{count} model(s) visible")


def check_chat_history(ctx: Context) -> CheckResult:
    if not ctx.token:
        return CheckResult("chat history readable", False, "no session token (signin failed)", skipped=True)
    try:
        status, raw = http_request(
            "GET", f"{ctx.base_url}/api/v1/chats/?page=1",
            headers=bearer(ctx.token), timeout=ctx.timeout,
        )
    except ConnectionError as e:
        return CheckResult("chat history readable", False, str(e))
    if status != 200:
        return CheckResult("chat history readable", False, f"HTTP {status}")
    count = len(json.loads(raw))
    return CheckResult("chat history readable", True, f"{count} chat(s) for {ctx.email}")


def check_signout_redirect(ctx: Context) -> CheckResult:
    if not ctx.token:
        return CheckResult("signout / IdP redirect", False, "no session token (signin failed)", skipped=True)
    expected = openwebui_block(ctx.config).get("environment", {}).get("WEBUI_AUTH_SIGNOUT_REDIRECT_URL")
    try:
        status, raw = http_request(
            "POST", f"{ctx.base_url}/api/v1/auths/signout",
            headers=bearer(ctx.token), timeout=ctx.timeout,
        )
    except ConnectionError as e:
        return CheckResult("signout / IdP redirect", False, str(e))
    if status != 200:
        return CheckResult("signout / IdP redirect", False, f"HTTP {status}")
    actual = json.loads(raw).get("redirect_url")
    if expected and actual != expected:
        return CheckResult("signout / IdP redirect", False, f"got {actual!r}, config.json expects {expected!r}")
    ctx.token = None  # session just ended server-side
    return CheckResult("signout / IdP redirect", True, f"redirect_url={actual!r}" if actual else "no redirect configured")


def container_started_at(container: str) -> str | None:
    # Plain JSON output (not --format) is what gives an RFC3339 string podman
    # logs --since accepts — the Go-template form (.State.StartedAt) renders
    # via time.Time's default String() layout ("... -0400 EDT"), which
    # `podman logs --since` cannot parse.
    r = podman("inspect", container)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout)[0]["State"]["StartedAt"]
    except (json.JSONDecodeError, KeyError, IndexError):
        return None


def check_container_logs(ctx: Context) -> CheckResult:
    since = container_started_at(ctx.container)
    args = ["logs"]
    if since:
        args += ["--since", since]
    args.append(ctx.container)
    r = podman(*args)
    if r.returncode != 0:
        return CheckResult("container logs clean", False, r.stderr.strip() or "podman logs failed")
    bad = [
        line for line in (r.stdout + r.stderr).splitlines()
        if any(marker in line for marker in ("ERROR", "Traceback", "Exception"))
        and not any(benign in line for benign in BENIGN_LOG_PATTERNS)
    ]
    if bad:
        return CheckResult("container logs clean", False, f"{len(bad)} suspect line(s), first: {bad[0][:200]}")
    return CheckResult("container logs clean", True, "no errors/tracebacks since container start")


CHECKS = (
    check_container_running,
    check_version_endpoint,
    check_health_endpoint,
    check_sso_signin,
    check_models_list,
    check_chat_history,
    check_signout_redirect,
    check_container_logs,
)


def run_checks(ctx: Context, include_logs: bool) -> list[CheckResult]:
    results = []
    for check in CHECKS:
        if check is check_container_logs and not include_logs:
            continue
        results.append(check(ctx))
    return results


def print_report(results: list[CheckResult], ctx: Context) -> None:
    name_w = max(len(r.name) for r in results) + 2
    header = f"{'CHECK':<{name_w}} STATUS   DETAIL"
    print(header)
    for r in results:
        status = "SKIP" if r.skipped else ("PASS" if r.passed else "FAIL")
        print(f"{r.name:<{name_w}} {status:<8} {r.detail}")
    print()
    passed = sum(1 for r in results if r.passed)
    failed = sum(1 for r in results if not r.passed and not r.skipped)
    skipped = sum(1 for r in results if r.skipped)
    version_note = f" (OpenWebUI v{ctx.version})" if ctx.version else ""
    print(f"{passed} passed, {failed} failed, {skipped} skipped{version_note}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Post-change smoke test for OpenWebUI: SSO, models, chat history, signout, logs.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Exit codes:\n"
            "  0   All checks passed\n"
            "  1   One or more checks failed\n"
            "  2   Environment/config problem (podman, config.json, or container missing)\n"
        ),
    )
    parser.add_argument("--email", required=True, help="Trusted-header identity to sign in as")
    parser.add_argument("--name", default=None, help="Display name for the trusted name header (default: derived from --email)")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG_PATH, help=f"Path to config.json (default: {DEFAULT_CONFIG_PATH})")
    parser.add_argument("--base-url", default=None, help="Override the computed base URL")
    parser.add_argument("--container", default=DEFAULT_CONTAINER, help=f"Container name (default: {DEFAULT_CONTAINER})")
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT, help=f"Per-request HTTP timeout in seconds (default: {DEFAULT_TIMEOUT:g})")
    parser.add_argument("--skip-logs", action="store_true", help="Skip the container-log error scan")
    parser.add_argument("--json", action="store_true", help="Emit a structured JSON report instead of a table")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if shutil.which("podman") is None:
        print("ERROR: required command not found: podman", file=sys.stderr)
        return 2

    config = load_config(args.config)

    exists = podman("container", "exists", args.container)
    if exists.returncode != 0:
        print(f"ERROR: container '{args.container}' not found — is it running?", file=sys.stderr)
        return 2

    ctx = Context(
        base_url=args.base_url or default_base_url(config),
        container=args.container,
        email=args.email,
        name=args.name or args.email.split("@")[0],
        timeout=args.timeout,
        config=config,
    )

    results = run_checks(ctx, include_logs=not args.skip_logs)

    if args.json:
        print(json.dumps({
            "base_url": ctx.base_url,
            "version": ctx.version,
            "results": [r.__dict__ for r in results],
            "passed": all(r.passed or r.skipped for r in results),
        }, indent=2))
    else:
        print_report(results, ctx)

    return 0 if all(r.passed or r.skipped for r in results) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
