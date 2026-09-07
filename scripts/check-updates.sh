#!/usr/bin/env bash
# scripts/check-updates.sh
#
# Update checker for stack components — self-adapts to whichever host it
# runs on. Detects what's actually installed locally, by deploy mechanism:
#   quadlet   — Podman Quadlet .container file present in QUADLET_DIR (works
#               identically for CENTAURI's own stack and photondatum.space's
#               ai-stack-iam-* stack — no config.json required for either)
#   native    — OS-level binary/service (Caddy, Headscale, Forgejo, Tailscale);
#               detected via a small per-component check, run locally
#   compose   — podman-compose-managed (RustDesk on photondatum.space);
#               detected via its systemd wrapper unit / running container
#
# A component not detected as installed on the current host is skipped by
# default — run with --include-uninstalled to see the full manifest catalog
# regardless of local presence (e.g. for cross-host planning).
#
# For each installed component: current version, available version (live
# registry query, with a download link and, separately, a release-notes URL
# where one can be resolved), a best-effort risk assessment for updating,
# workflow dependencies (other components coupled to this one), known
# issues/incompatibilities (from configs/component-updates.json, sourced from
# this repo's own decisions.md / lessons_learned.md / git history), and a
# critical-update flag for security/stability issues. Components with no
# real download link (custom-built images, manual-check-only registries) get
# concrete update_instructions instead of a dead/missing link.
#
# The manifest (configs/component-updates.json) is a living document — extend
# known_issues/workflow_deps as new gotchas are discovered, the same way
# decisions.md and the per-component lessons_learned.md files are extended.
#
# Limitations:
#   - Forgejo is hosted on Codeberg, not GitHub — no automated AVAILABLE-version
#     check; flagged for manual review. CURRENT version is still detected
#     locally (via its own API).
#   - "Critical" flags come from the manifest's hand-curated known_issues plus
#     a major-version-bump heuristic. This is NOT a live CVE/security-advisory
#     feed — treat critical=false as "nothing known," not "nothing wrong."
#   - --role is an optional coarse pre-filter, not what determines relevance —
#     local detection does that. Mainly useful to narrow output further, or to
#     sanity-check a manifest entry's role tags.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_FILE="$PROJECT_ROOT/configs/component-updates.json"

AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
CONFIG_FILE="${CONFIG_FILE:-$AI_STACK_DIR/configs/config.json}"
QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"
if [[ ! -f "$CONFIG_FILE" ]]; then
    # Fall back to the tracked example template so the script is still useful
    # for review/testing on a machine without a live deployment. Only used as
    # a secondary signal now — quadlet-file detection is the primary source
    # of truth for "is this installed here," and doesn't need config.json at
    # all (e.g. photondatum.space has no config.json, only its own quadlets).
    CONFIG_FILE="$PROJECT_ROOT/configs/config.json.example"
fi

REQUEST_TIMEOUT="${REQUEST_TIMEOUT:-6}"

usage() {
    cat <<'EOF'
Usage: check-updates.sh [options]

Purpose:
  Check current vs. available versions for every stack component actually
  installed on the host this runs on — detected live (Quadlet files, native
  binaries, podman-compose units), not guessed from a role flag. Reports a
  risk assessment, workflow dependencies, known issues/incompatibilities, and
  a critical update flag (security/stability) per component. Run it as-is on
  CENTAURI, photondatum.space, TC25, SOL, etc. — each sees only what's there.

Options:
  --role <edge|backplane|node|all>   Optional coarse pre-filter on manifest
                                      role tags (default: all — local
                                      detection is what actually determines
                                      relevance, this just narrows further)
  --component <id>                   Check a single component by id
                                      (see configs/component-updates.json)
  --include-uninstalled              Also report components not detected as
                                      installed locally (full manifest catalog
                                      — e.g. for cross-host planning)
  --critical-only                    Only show components with a critical flag
  --offline                          Skip live registry queries; report only
                                      current version + manifest known_issues
  --json                             Emit structured JSON instead of a table
  --color                            Colorize the human-readable report
  --timeout <seconds>                Per-request network timeout (default: 6)
  -h, --help                         Show this message

Exit codes:
  0   Ran successfully, no critical updates found
  1   A required tool is missing, or the manifest/config could not be read
  2   Ran successfully, at least one critical update flag was raised

Environment:
  CONFIG_FILE   Path to config.json (default: $AI_STACK_DIR/configs/config.json,
                falling back to configs/config.json.example if not found) —
                secondary signal only; see QUADLET_DIR.
  QUADLET_DIR   Quadlet directory (default: ~/.config/containers/systemd) —
                primary source of truth for what's installed on this host.
EOF
}

ROLE_FILTER="all"
COMPONENT_FILTER=""
INCLUDE_UNINSTALLED=0
CRITICAL_ONLY=0
OFFLINE=0
OUTPUT_FORMAT="text"
USE_COLOR=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --role)               ROLE_FILTER="$2"; shift 2 ;;
        --component)          COMPONENT_FILTER="$2"; shift 2 ;;
        --include-uninstalled) INCLUDE_UNINSTALLED=1; shift ;;
        --critical-only)      CRITICAL_ONLY=1; shift ;;
        --offline)            OFFLINE=1; shift ;;
        --json)               OUTPUT_FORMAT="json"; shift ;;
        --color)              USE_COLOR=1; shift ;;
        --timeout)            REQUEST_TIMEOUT="$2"; shift 2 ;;
        -h|--help)            usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [[ "$ROLE_FILTER" != "all" && "$ROLE_FILTER" != "edge" && "$ROLE_FILTER" != "backplane" && "$ROLE_FILTER" != "node" ]]; then
    echo "ERROR: --role must be one of: edge, backplane, node, all" >&2
    exit 1
fi

for cmd in python3 curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ ! -f "$MANIFEST_FILE" ]]; then
    echo "ERROR: $MANIFEST_FILE not found" >&2
    exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: $CONFIG_FILE not found" >&2
    exit 1
fi

export MANIFEST_FILE CONFIG_FILE QUADLET_DIR PROJECT_ROOT ROLE_FILTER COMPONENT_FILTER INCLUDE_UNINSTALLED CRITICAL_ONLY OFFLINE OUTPUT_FORMAT USE_COLOR REQUEST_TIMEOUT

python3 <<'PYEOF'
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import urllib.error

MANIFEST_FILE   = os.environ["MANIFEST_FILE"]
CONFIG_FILE     = os.environ["CONFIG_FILE"]
QUADLET_DIR     = os.environ["QUADLET_DIR"]
PROJECT_ROOT    = os.environ["PROJECT_ROOT"]
ROLE_FILTER     = os.environ["ROLE_FILTER"]
COMPONENT_FILTER = os.environ.get("COMPONENT_FILTER", "")
INCLUDE_UNINSTALLED = os.environ.get("INCLUDE_UNINSTALLED") == "1"
CRITICAL_ONLY   = os.environ.get("CRITICAL_ONLY") == "1"
OFFLINE         = os.environ.get("OFFLINE") == "1"
OUTPUT_FORMAT   = os.environ["OUTPUT_FORMAT"]
USE_COLOR       = os.environ.get("USE_COLOR") == "1"
TIMEOUT         = float(os.environ["REQUEST_TIMEOUT"])
LOCAL_CMD_TIMEOUT = 5

DIM_RED = "\033[2;31m"
YELLOW  = "\033[33m"
BOLD    = "\033[1m"
RESET   = "\033[0m"


def colorize(text, code):
    if not USE_COLOR:
        return text
    return f"{code}{text}{RESET}"


with open(MANIFEST_FILE) as f:
    manifest = json.load(f)

with open(CONFIG_FILE) as f:
    config = json.load(f)


def _get_path(d, dotted):
    if not dotted:
        return None
    cur = d
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return None
        cur = cur[part]
    return cur


def _http_json(url, headers=None, timeout=TIMEOUT):
    req = urllib.request.Request(url, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode())


def _version_key(tag: str):
    """Best-effort semver-ish sort key. Falls back to raw string comparison
    for non-semver tags (date-based, calendar-versioned, etc.) — those are
    flagged as 'unparseable, compare manually' rather than guessed at."""
    m = re.search(r"(\d+)\.(\d+)\.(\d+)", tag or "")
    if m:
        return tuple(int(x) for x in m.groups())
    return None


def _bump_size(current_tag, available_tag):
    cv, av = _version_key(current_tag), _version_key(available_tag)
    if cv is None or av is None:
        return "unknown"
    if av <= cv:
        return "none"
    if av[0] != cv[0]:
        return "major"
    if av[1] != cv[1]:
        return "minor"
    return "patch"


# Tags that are never a meaningful "available version" to surface: mutable
# rolling tags, prerelease/dev channels, and CI artifacts (commit-hash or
# sha-prefixed tags). Excluding these is necessary because registries return
# tags in push-recency or lexical order, neither of which tracks "newest
# stable release" — the most-recently-pushed tag is very often a dev/nightly
# build, not the one worth upgrading to.
_NOISE_TAG_RE = re.compile(
    r"^(latest|main|master|nightly|dev|edge|test|canary|unstable|unprivileged)$"
    r"|^(alpha|beta|rc)\d*$"
    r"|^(git|sha|commit)-?[0-9a-f]{6,}$"
    r"|^[0-9a-f]{7,40}$",
    re.IGNORECASE,
)


def _pick_best_tag(tags: list[str]):
    """From a list of tag names, filter obvious noise and pick the highest
    semver-parseable tag. Returns (tag, parseable: bool) or (None, False) if
    nothing usable remains. When nothing is semver-parseable, falls back to
    the lexically-last surviving tag with parseable=False so callers can
    flag it as 'compare manually' rather than presenting it as authoritative."""
    candidates = [t for t in tags if t and not _NOISE_TAG_RE.match(t)]
    if not candidates:
        return None, False
    with_keys = [(t, _version_key(t)) for t in candidates]
    parseable = [t for t in with_keys if t[1] is not None]
    if parseable:
        return max(parseable, key=lambda x: x[1])[0], True
    return sorted(candidates)[-1], False


_URL_RE = re.compile(r"https?://\S+")


def _extract_url_from_issues(known_issues: list[dict]):
    """Last-resort link for components with no automated registry check:
    known_issues prose sometimes already embeds the manual-check URL
    (e.g. forgejo's Codeberg releases page) — surface it as a clickable
    link instead of making the user re-read the issue text to find it."""
    for issue in known_issues or []:
        m = _URL_RE.search(issue.get("summary", ""))
        if m:
            return m.group(0).rstrip(".,;)")
    return None


def _fetch_github_release_notes_url(release_repo: str):
    """Best-effort release-notes link for components whose primary registry
    isn't GitHub itself (dockerhub/ghcr) but do have a release_repo mapping.
    One extra lightweight call; falls back to the releases *list* (still a
    valid release-notes destination) rather than failing outright — Docker
    image tags often carry variant suffixes (-alpine, -distroless, -trixie)
    that don't match the upstream git tag exactly, so we don't try to
    guess a tag-specific URL here."""
    try:
        data = _http_json(f"https://api.github.com/repos/{release_repo}/releases/latest")
        html_url = data.get("html_url")
        if html_url:
            return html_url, None
    except Exception as e:
        return f"https://github.com/{release_repo}/releases", f"release-notes lookup failed ({e.__class__.__name__}) — linking to the releases list instead"
    return f"https://github.com/{release_repo}/releases", None


def _read_quadlet_image_tag(component_id: str):
    """Detects whether <component_id>.container exists in QUADLET_DIR and, if
    so, parses its Image=repo:tag line directly — no config.json involved.
    This is what makes 'installed' detection host-agnostic: it works
    identically for CENTAURI's own quadlets and for photondatum.space's
    ai-stack-iam-* stack, and requires nothing beyond the quadlet file itself.
    Returns (installed: bool, tag: str|None)."""
    path = os.path.join(QUADLET_DIR, f"{component_id}.container")
    if not os.path.isfile(path):
        return False, None
    with open(path) as f:
        contents = f.read()
    m = re.search(r"^Image=(\S+)$", contents, re.MULTILINE)
    if not m:
        return True, None
    image = m.group(1)
    last_segment = image.rsplit("/", 1)[-1]
    if ":" in last_segment:
        return True, image.rsplit(":", 1)[1]
    return True, None


def _run(cmd, timeout=LOCAL_CMD_TIMEOUT):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def _detect_native(component_id: str):
    """Local, host-specific detection for OS-level services that aren't
    containers at all. Returns (installed: bool, version: str|None, note: str|None).
    Each of these is genuinely different (CLI flag vs. local HTTP API), so
    this is deliberately fixed, reviewed code per component rather than a
    manifest-driven command — running arbitrary strings from a JSON file
    through a shell is not a trade worth making for four known cases."""
    try:
        if component_id in ("caddy", "tailscale"):
            # Both print the bare version as the first token of the first line:
            # caddy: "v2.11.4 h1:XKxk..."   tailscale: "1.102.2\n  tailscale commit: ..."
            if not shutil.which(component_id):
                return False, None, None
            out = _run([component_id, "version"]).stdout.strip()
            first_line = out.splitlines()[0].strip() if out else ""
            version = first_line.split()[0] if first_line else None
            return True, version, None if version else "installed but version output unparseable"

        if component_id == "headscale":
            # Different shape from the above: "headscale version 0.28.0\ncommit: ..."
            # — version is the LAST token of the first line, not the first.
            if not shutil.which("headscale"):
                return False, None, None
            out = _run(["headscale", "version"]).stdout.strip()
            first_line = out.splitlines()[0].strip() if out else ""
            tokens = first_line.split()
            version = tokens[-1] if tokens else None
            return True, version, None if version else "installed but version output unparseable"

        if component_id == "forgejo":
            # Runs as a systemd service; don't assume a binary is on PATH —
            # query its own local API instead of guessing an install path.
            try:
                data = _http_json("http://127.0.0.1:3000/api/v1/version", timeout=3)
                v = data.get("version")
                if v:
                    return True, v, None
            except Exception:
                pass
            try:
                r = _run(["systemctl", "is-active", "forgejo"], timeout=3)
                if r.stdout.strip() == "active":
                    return True, None, "service active but local API unreachable — check ROOT_URL/firewall"
            except Exception:
                pass
            return False, None, None

        return False, None, f"no native detector implemented for {component_id!r}"
    except Exception as e:
        return False, None, f"local detection failed: {e.__class__.__name__}"


def _detect_compose(component: dict):
    """Detection for podman-compose-managed components (RustDesk on
    photondatum.space). Primary signal is the actual container's existence
    via `podman ps -a` (works whether it's running or stopped — "installed"
    means present, not necessarily active, same as a masked Quadlet service).
    Verified against the real deployment: despite the compose file's own
    comment claiming a `podman-compose@<name>.service` systemd wrapper, no
    such unit is actually registered (checked both --user and system scope)
    — the containers were created directly via `podman-compose up` with no
    systemd supervision at all. So the systemd-unit check is kept only as a
    secondary signal for a host that genuinely does wrap it that way, not
    the primary one.
    Returns (installed: bool, version: str|None, note: str|None)."""
    container = component.get("compose_container")
    if container:
        try:
            out = _run(["podman", "ps", "-a", "--filter", f"name={container}",
                        "--format", "{{.Image}}"]).stdout.strip()
            if out:
                last_segment = out.rsplit("/", 1)[-1]
                if ":" in last_segment:
                    return True, out.rsplit(":", 1)[1], None
                return True, None, "container present but image tag unparseable"
        except Exception:
            pass

    unit = component.get("compose_systemd_unit")
    installed = False
    if unit:
        try:
            r = _run(["systemctl", "--user", "is-active", unit], timeout=3)
            installed = r.returncode == 0
            if not installed:
                r2 = _run(["systemctl", "--user", "list-unit-files", unit], timeout=3)
                installed = unit in r2.stdout
        except Exception:
            pass
    if not installed:
        return False, None, None

    compose_file = component.get("compose_file")
    if compose_file:
        try:
            with open(os.path.join(PROJECT_ROOT, compose_file)) as f:
                contents = f.read()
            m = re.search(r"image:\s*\S*rustdesk-server:(\S+)", contents)
            if m:
                return True, m.group(1), "read from compose file, not the live container"
        except Exception:
            pass
    return True, None, "systemd unit present but current version could not be determined"


def _detect_ollama_bare_metal():
    """Fallback for hosts where Ollama runs bare-metal with no Podman/Quadlet
    at all (TC25, a macOS worker — see node inventory). Ollama's local REST
    API is identical across install methods and platforms, so it's queried
    directly rather than parsed from `ollama -v` CLI text, whose exact
    wording isn't guaranteed stable (the same class of surprise headscale's
    CLI output produced above). Mirrors forgejo's two-signal style: local API
    first, binary-on-PATH as a weaker fallback. Returns
    (installed: bool, version: str|None, note: str|None)."""
    try:
        data = _http_json("http://localhost:11434/api/version", timeout=3)
        v = data.get("version")
        if v:
            return True, v, None
    except Exception:
        pass
    if shutil.which("ollama"):
        return True, None, "ollama binary present but local API unreachable — is the server running?"
    return False, None, None


def _detect_installed(component: dict):
    """Dispatches to the right detector by the manifest's 'deploy' field.
    Returns (installed: bool, current_version: str|None, note: str|None)."""
    deploy = component.get("deploy", "quadlet")
    comp_id = component["id"]

    if deploy == "quadlet":
        installed, tag = _read_quadlet_image_tag(comp_id)
        if installed:
            if tag is not None:
                return True, tag, None
            # Quadlet file present but tag unparseable — fall back to config.json.
            cfg_val = _get_path(config, component.get("config_path")) if component.get("config_path") else None
            note = None if cfg_val else "quadlet file present but current version unparseable"
            return True, cfg_val, note
        if comp_id == "ollama":
            # Ollama is the one component here that legitimately runs two
            # ways across the fleet: containerized (Centauri, SOL) or
            # bare-metal (TC25). No quadlet file just rules out the first —
            # check its local API before concluding it's absent entirely.
            bm_installed, bm_version, bm_note = _detect_ollama_bare_metal()
            if bm_installed:
                return True, bm_version, bm_note
        # No local quadlet file — genuinely not installed on this host. Do
        # NOT fall back to config.json here: on a host with no live deploy,
        # CONFIG_FILE degrades to configs/config.json.example (the tracked
        # bootstrap template), whose placeholder tags would otherwise get
        # reported as real, "installed" versions — verified empirically
        # against photondatum.space, where every quadlet-type component
        # showed up this way despite none of them running there at all.
        return False, None, None

    if deploy == "native":
        return _detect_native(comp_id)

    if deploy == "compose":
        return _detect_compose(component)

    return False, None, f"unrecognized deploy type: {deploy!r}"


def _fetch_available(component: dict):
    """Returns (available_version, download_link, release_notes_url, note)."""
    registry = component.get("registry")
    release_repo = component.get("release_repo")

    if OFFLINE:
        return None, None, None, "offline mode — skipped live registry check"

    try:
        if registry == "dockerhub":
            repo = component["registry_repo"]
            url = f"https://hub.docker.com/v2/repositories/{repo}/tags?page_size=100&ordering=last_updated"
            data = _http_json(url)
            all_tags = [t.get("name", "") for t in data.get("results", [])]
            top, parseable = _pick_best_tag(all_tags)
            if not top:
                return None, None, None, "no usable (non-dev/prerelease/CI) tags found"
            note = None if parseable else "no cleanly-parseable release tag found — showing the closest candidate; verify manually"
            download_link = f"https://hub.docker.com/r/{repo}/tags?name={top}"
            release_notes_url = None
            if release_repo:
                release_notes_url, rn_note = _fetch_github_release_notes_url(release_repo)
                note = note or rn_note
            return top, download_link, release_notes_url, note

        elif registry == "ghcr":
            repo = component["registry_repo"]
            token_url = f"https://ghcr.io/token?service=ghcr.io&scope=repository:{repo}:pull"
            token = _http_json(token_url).get("token", "")
            list_url = f"https://ghcr.io/v2/{repo}/tags/list"
            data = _http_json(list_url, headers={"Authorization": f"Bearer {token}"})
            top, parseable = _pick_best_tag(data.get("tags", []))
            if not top and release_repo:
                # High-traffic GHCR images are often dominated by CI/commit-hash
                # tags in the most recent page with no clean release tag visible.
                # Fall back to the upstream GitHub release, which is authoritative
                # for "latest stable" regardless of what GHCR's tag list shows.
                try:
                    gh_data = _http_json(f"https://api.github.com/repos/{release_repo}/releases/latest")
                    gh_tag = gh_data.get("tag_name", "")
                    if gh_tag:
                        html_url = gh_data.get("html_url")
                        # Same page serves as both: it's a real GitHub release,
                        # not just a container-registry tag list.
                        return gh_tag, html_url, html_url, "GHCR tag list had no clean release tag — fell back to the GitHub release"
                except Exception:
                    pass
            if not top:
                return None, None, None, "no usable (non-dev/prerelease/CI) tags found"
            download_link = f"https://github.com/{release_repo}/releases" if release_repo else f"https://ghcr.io/{repo}"
            note = None if parseable else "no cleanly-parseable release tag found — showing the closest candidate; verify manually"
            release_notes_url = None
            if release_repo:
                release_notes_url, rn_note = _fetch_github_release_notes_url(release_repo)
                note = note or rn_note
            return top, download_link, release_notes_url, note

        elif registry == "github":
            if not release_repo:
                return None, None, None, "no release_repo configured"
            data = _http_json(f"https://api.github.com/repos/{release_repo}/releases/latest")
            tag = data.get("tag_name", "")
            html_url = data.get("html_url")
            # GitHub's own release page IS the release notes for github-registry
            # components (no separate container/binary registry to distinguish).
            return tag, html_url, html_url, None

        elif registry == "custom":
            return None, None, None, "custom-built image — no upstream registry; rebuild after a source change"

        elif registry == "manual":
            return None, None, None, "no automated check available for this registry — see known_issues for the manual-check URL"

        else:
            return None, None, None, f"unrecognized registry type: {registry!r}"

    except urllib.error.HTTPError as e:
        return None, None, None, f"registry query failed: HTTP {e.code}"
    except Exception as e:
        return None, None, None, f"registry query failed: {e.__class__.__name__}: {e}"


def _update_instructions(component: dict, download_link, matched_issues):
    """Actionable next step when there's no download link to follow —
    custom-built images and manual-check-only registries need instructions,
    not a URL that doesn't exist."""
    if download_link:
        return None
    if component.get("custom_built"):
        cid = component["id"]
        return (
            f"Custom-built — no upstream registry. Rebuild after a source change: "
            f"podman build -t localhost/{cid}:<tag> -f services/{cid}/Containerfile services/{cid}/ "
            f"&& systemctl --user restart {cid}"
        )
    if component.get("registry") == "manual":
        url = _extract_url_from_issues(matched_issues)
        if url:
            return f"No automated check available — check manually: {url}"
        return "No automated check available — see known_issues below for manual-check details."
    return None


def _assess_risk(component, current, available, bump, matched_issues):
    """Heuristic risk assessment — not authoritative, a starting point for
    manual review. Factors: version bump size, number of workflow deps,
    and matched known_issues severities."""
    reasons = []
    score = 0

    if bump == "major":
        score += 3
        reasons.append("major version bump")
    elif bump == "minor":
        score += 1
        reasons.append("minor version bump")
    elif bump == "unknown" and available and current:
        score += 1
        reasons.append("non-semver tags — bump size not determinable, compare changelogs manually")

    dep_count = len(component.get("workflow_deps", []))
    if dep_count:
        score += min(dep_count, 3)
        reasons.append(f"{dep_count} workflow-dependent component(s)")

    max_issue_sev = None
    sev_rank = {"info": 0, "medium": 1, "high": 2, "critical": 3}
    for issue in matched_issues:
        sev = issue.get("severity", "info")
        if max_issue_sev is None or sev_rank.get(sev, 0) > sev_rank.get(max_issue_sev, 0):
            max_issue_sev = sev
    if max_issue_sev in ("high", "critical"):
        score += 3
        reasons.append(f"known issue at {max_issue_sev} severity")
    elif max_issue_sev == "medium":
        score += 1
        reasons.append("known issue at medium severity")

    if component.get("custom_built"):
        reasons.append("custom-built — risk is about your own code changes, not an upstream pull")

    if score >= 5:
        level = "high"
    elif score >= 2:
        level = "medium"
    elif score >= 1:
        level = "low"
    else:
        level = "minimal"

    return level, reasons


def _is_critical(component, bump, matched_issues):
    if any(i.get("severity") == "critical" for i in matched_issues):
        return True
    if bump == "major" and component.get("workflow_deps"):
        return True
    return False


components = manifest["components"]
if COMPONENT_FILTER:
    components = [c for c in components if c["id"] == COMPONENT_FILTER]
    if not components:
        print(f"ERROR: no component with id {COMPONENT_FILTER!r} in manifest", file=sys.stderr)
        sys.exit(1)
elif ROLE_FILTER != "all":
    components = [c for c in components if ROLE_FILTER in c.get("roles", [])]

report = []
any_critical = False

for component in components:
    installed, current, current_note = _detect_installed(component)
    if not installed and not INCLUDE_UNINSTALLED:
        continue
    if not installed:
        current_note = current_note or "not detected as installed on this host"

    available, link, release_notes_url, note = _fetch_available(component)
    bump = _bump_size(current, available) if (current and available) else "unknown"

    matched_issues = component.get("known_issues", [])
    risk_level, risk_reasons = _assess_risk(component, current, available, bump, matched_issues)
    critical = _is_critical(component, bump, matched_issues)
    if critical:
        any_critical = True

    update_instructions = _update_instructions(component, link, matched_issues)
    # Fallback link for manual-check registries (e.g. forgejo on Codeberg):
    # known_issues prose often already names the URL to check.
    if not link and component.get("registry") == "manual":
        link = _extract_url_from_issues(matched_issues)

    entry = {
        "id": component["id"],
        "name": component["name"],
        "roles": component["roles"],
        "deploy": component.get("deploy"),
        "installed": installed,
        "custom_built": component.get("custom_built", False),
        "current_version": current,
        "current_version_note": current_note,
        "available_version": available,
        "available_version_note": note,
        "download_link": link,
        "release_notes_url": release_notes_url,
        "update_instructions": update_instructions,
        "update_available": bool(current and available and bump not in ("none", "unknown")) or (bump == "unknown" and available and current and available != current),
        "version_bump": bump,
        "risk_level": risk_level,
        "risk_reasons": risk_reasons,
        "workflow_deps": component.get("workflow_deps", []),
        "known_issues": matched_issues,
        "critical": critical,
    }

    if CRITICAL_ONLY and not critical:
        continue
    report.append(entry)

if OUTPUT_FORMAT == "json":
    print(json.dumps({"components": report, "any_critical": any_critical}, indent=2))
else:
    for entry in report:
        header = f"{entry['name']} ({entry['id']}) — roles: {', '.join(entry['roles'])}"
        if not entry["installed"]:
            header = f"[NOT INSTALLED HERE] {header}"
        if entry["critical"]:
            header = colorize(f"[CRITICAL] {header}", DIM_RED)
        elif entry["update_available"]:
            header = colorize(header, YELLOW)
        print(colorize(header, BOLD) if not entry["critical"] and not entry["update_available"] else header)

        cur = entry["current_version"] or f"unknown ({entry['current_version_note']})"
        print(f"  current:   {cur}")
        if entry["available_version"]:
            print(f"  available: {entry['available_version']}  ({entry['version_bump']} bump)")
            if entry["download_link"]:
                print(f"  link:      {entry['download_link']}")
            if entry["release_notes_url"] and entry["release_notes_url"] != entry["download_link"]:
                print(f"  notes:     {entry['release_notes_url']}")
            if entry["available_version_note"]:
                print(colorize(f"  note:      {entry['available_version_note']}", YELLOW))
        else:
            print(f"  available: unknown — {entry['available_version_note']}")
            if entry["download_link"]:
                print(f"  link:      {entry['download_link']}")

        if entry["update_instructions"]:
            print(colorize(f"  next step: {entry['update_instructions']}", YELLOW))

        print(f"  risk:      {entry['risk_level']}" + (f" — {'; '.join(entry['risk_reasons'])}" if entry["risk_reasons"] else ""))

        if entry["workflow_deps"]:
            print(f"  depends with: {', '.join(entry['workflow_deps'])}")

        if entry["known_issues"]:
            print("  known issues:")
            for issue in entry["known_issues"]:
                sev = issue["severity"]
                line = f"    [{sev}] {issue['summary']}"
                print(colorize(line, DIM_RED) if sev in ("high", "critical") else line)
                print(f"      source: {issue['source']}")
        print()

    print(f"{len(report)} component(s) reported.", end="")
    if any_critical:
        print(colorize("  CRITICAL update(s) present — review above.", DIM_RED))
    else:
        print()

sys.exit(2 if any_critical else 0)
PYEOF
