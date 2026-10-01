#!/usr/bin/env bash
# scripts/model-inventory.sh
#
# Per-node model inventory: for every node in configs/nodes/*.json (plus the
# controller itself), reports whether the node is reachable, which models
# are actually available there (live-probed via Ollama /api/tags and, for
# the controller, vLLM /v1/models), and whether each is registered as a
# route in LiteLLM. Models registered in LiteLLM but not actually available
# on the node they claim to serve (stale/broken routes) are flagged.
#
# Cloud/API-hosted models (openai, groq, anthropic, mistral backends in
# config.json's models[]) are reported separately: registration status plus
# whether the required Podman secret is provisioned. No live call is made
# against external providers, to avoid burning quota/rate limits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NODES_DIR="$PROJECT_ROOT/configs/nodes"

AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
CONFIG_FILE="${CONFIG_FILE:-$AI_STACK_DIR/configs/config.json}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-3}"
LITELLM_URL="${LITELLM_URL:-http://localhost:9000}"

usage() {
    cat <<'EOF'
Usage: model-inventory.sh [options]

Purpose:
  Report, per node, which models are actually available (live-probed) and
  whether each is registered as a route in LiteLLM. Also flags stale routes
  (registered but not available) and unregistered-but-available models.
  Cloud/API-hosted models are reported separately (registration + secret
  provisioned status only — no live provider call).

Options:
  --json        Emit structured JSON instead of the human-readable report
                (for a future web UI)
  --color       Colorize the human-readable report; dims unregistered/
                unavailable/stale entries in red to draw attention
  -v, --verbose Add per-model disk size, parameter count, a PULLED date, and
                a single merged TAGS column: LiteLLM's "strong-1"-style node
                classification plus Ollama's supported-modes capabilities
                (completion/tools/thinking/vision/etc.) — see
                output/CENTAURI-playbook.md §13 L-31/L-34/L-35. Both are
                applied by pull-models.sh itself at registration time
                (modes pre-sorted alphabetically there, so this column is
                always in a consistent order), so this is simply what's
                actually registered, read straight off LiteLLM's
                /model/info — no live /api/show call from this script
                anymore. "-" means genuinely untagged: a cloud model or a
                per-node alias route, both deliberately excluded from the
                scheme. --json keeps "classification" and "modes" as
                separate fields, unchanged, for structured consumers.
                PULLED is Ollama's own "modified_at" — when THIS HOST
                downloaded the model, not an upstream release/publication
                date, which Ollama's API exposes nowhere.
                Also prints the controller's Ollama server version, and its
                local model-repository directory with total and free space
                on that filesystem, once, under the controller's own
                section — this is filesystem-level info, so it's only ever
                available for the controller itself, not remote nodes
                (nothing in Ollama's HTTP API exposes a remote node's
                storage path or on-disk usage).
  -cpu, --cpu   Add a LOAD column (right after STATUS) showing each loaded
                model's live CPU%, attributed the same way loads.sh does:
                the runner subprocess invoked with `--model <weights-blob>`
                is matched to Ollama's own manifest file on disk for that
                model (not /api/ps's own "digest" field — that's the
                *manifest's* digest, a different hash that never matches the
                blob path). A single currently-loaded model with no digest
                match falls back to the whole `ollama` process/container's
                CPU total, since that's unambiguous. vLLM's one served model
                gets the `vllm` container's CPU total directly — no digest
                matching needed, there's only ever one. "-" means not
                currently loaded (most rows, most of the time — this is a
                live snapshot, not a historical one) or, for a remote node,
                that this script has no way to see its processes at all
                (HTTP-only — see the model-repository note above for why).
                Combines with -v to add both sets of columns at once.
  -h, --help    Show this message

Exit codes:
  0   Report generated
  1   A required tool is missing, or config.json / configs/nodes could not be read

Environment:
  CONFIG_FILE          Path to config.json       (default: $AI_STACK_DIR/configs/config.json)
  LITELLM_URL          LiteLLM base URL          (default: http://localhost:9000)
  LITELLM_MASTER_KEY   Bearer token               (auto-read from Podman secret if unset)
  PROBE_TIMEOUT        Seconds per live probe    (default: 3)
EOF
}

OUTPUT_FORMAT="text"
USE_COLOR=0
VERBOSE=0
CPU_FLAG=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)       OUTPUT_FORMAT="json"; shift ;;
        --color)      USE_COLOR=1;          shift ;;
        -v|--verbose) VERBOSE=1;            shift ;;
        -cpu|--cpu)   CPU_FLAG=1;           shift ;;
        -h|--help)    usage; exit 0 ;;
        *)            echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

for cmd in jq python3 podman curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: $CONFIG_FILE not found" >&2
    exit 1
fi

if [[ ! -d "$NODES_DIR" ]]; then
    echo "ERROR: $NODES_DIR not found" >&2
    exit 1
fi

OLLAMA_PORT="$(jq -r '.services.ollama.ports[0].host // 11434' "$CONFIG_FILE")"
VLLM_PORT="$(jq -r '.services.vllm.ports[0].host // 8000' "$CONFIG_FILE")"

# litellm_params (api_base, model) are encrypted at rest in Postgres — must go
# through LiteLLM's own authenticated API to get decrypted values, not raw SQL.
_resolve_litellm_key() {
    if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
        echo "$LITELLM_MASTER_KEY"
        return
    fi
    podman run --rm \
        --secret litellm_master_key \
        docker.io/library/alpine:latest \
        sh -c "cat /run/secrets/litellm_master_key" 2>/dev/null || true
}

MASTER_KEY="$(_resolve_litellm_key)"
REGISTERED_ROUTES='{"data":[]}'
if [[ -n "$MASTER_KEY" ]]; then
    resp="$(curl -s -H "Authorization: Bearer $MASTER_KEY" "$LITELLM_URL/model/info" 2>/dev/null || true)"
    if [[ -n "$resp" ]]; then
        REGISTERED_ROUTES="$resp"
    fi
fi

if [[ "$REGISTERED_ROUTES" == '{"data":[]}' ]]; then
    echo "WARNING: could not read LiteLLM's registered model list (master key or LiteLLM unreachable) — registration status will show as unknown" >&2
fi

PROVISIONED_SECRETS="$(podman secret ls --format '{{.Name}}' 2>/dev/null || true)"

# Controller's local Ollama model-repository directory, its on-disk size, and
# free space on that filesystem (-v only; filesystem-level, so controller-only
# — same discovery order as loads.sh: explicit override, then this stack's
# bind-mount convention, then the bare-metal default). Also the controller's
# own Ollama server version, straight from /api/version. -cpu needs this same
# directory too (to resolve a loaded model's weights digest from its manifest
# file — see resolve_weights_digest() in the Python below), so either flag
# triggers the lookup.
OLLAMA_MODELS_DIR=""
OLLAMA_MODELS_DIR_SIZE=""
OLLAMA_MODELS_DIR_FREE=""
OLLAMA_VERSION=""
if [[ "$VERBOSE" == "1" || "$CPU_FLAG" == "1" ]]; then
    for _candidate in "${OLLAMA_MODELS:-}" "$AI_STACK_DIR/ollama/models" "$HOME/.ollama/models"; do
        if [[ -n "$_candidate" && -d "$_candidate" ]]; then
            OLLAMA_MODELS_DIR="$_candidate"
            if [[ "$VERBOSE" == "1" ]]; then
                OLLAMA_MODELS_DIR_SIZE="$(du -sh "$_candidate" 2>/dev/null | cut -f1)"
                OLLAMA_MODELS_DIR_FREE="$(df -h "$_candidate" 2>/dev/null | tail -1 | awk '{print $4}')"
            fi
            break
        fi
    done
    if [[ "$VERBOSE" == "1" ]]; then
        OLLAMA_VERSION="$(curl -s -m "$PROBE_TIMEOUT" "http://localhost:$OLLAMA_PORT/api/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null || true)"
    fi
fi

# -cpu only: a host-wide `ps` snapshot (to match a loaded model's runner
# subprocess by its weights-blob digest) and each container's CPU% (for the
# vLLM single-model case, and as the ollama fallback when digest matching
# can't find a match but there's only one loaded model to attribute to).
# Both are controller-only by nature — there's no way to see a remote node's
# processes over HTTP alone.
PS_SNAPSHOT_RAW=""
PODMAN_STATS_RAW=""
if [[ "$CPU_FLAG" == "1" ]]; then
    PS_SNAPSHOT_RAW="$(ps -A -o pid,ppid,pcpu,args 2>/dev/null || true)"
    PODMAN_STATS_RAW="$(podman stats --no-stream --no-trunc --format '{{.Name}}	{{.CPUPerc}}' 2>/dev/null || true)"
fi

export REGISTERED_ROUTES PROVISIONED_SECRETS CONFIG_FILE NODES_DIR OLLAMA_PORT VLLM_PORT PROBE_TIMEOUT OUTPUT_FORMAT USE_COLOR
export VERBOSE OLLAMA_MODELS_DIR OLLAMA_MODELS_DIR_SIZE OLLAMA_MODELS_DIR_FREE OLLAMA_VERSION
export CPU_FLAG PS_SNAPSHOT_RAW PODMAN_STATS_RAW

python3 <<'PYEOF'
import json
import os
import re
import sys
import urllib.request
from datetime import datetime, timezone

CONFIG_FILE = os.environ["CONFIG_FILE"]
NODES_DIR = os.environ["NODES_DIR"]
OLLAMA_PORT = os.environ["OLLAMA_PORT"]
VLLM_PORT = os.environ["VLLM_PORT"]
PROBE_TIMEOUT = float(os.environ["PROBE_TIMEOUT"])
OUTPUT_FORMAT = os.environ["OUTPUT_FORMAT"]
USE_COLOR = os.environ.get("USE_COLOR") == "1"
PROVISIONED_SECRETS = set(
    line.strip() for line in os.environ.get("PROVISIONED_SECRETS", "").splitlines() if line.strip()
)

DIM_RED = "\033[2;31m"
RESET = "\033[0m"
BOLD = "\033[1m"


def colorize(text, ok):
    if not USE_COLOR or ok:
        return text
    return f"{DIM_RED}{text}{RESET}"


def parse_registered_routes(raw: str):
    try:
        data = json.loads(raw)
    except Exception:
        return []
    routes = []
    for entry in data.get("data", []):
        lp = entry.get("litellm_params", {}) or {}
        mi = entry.get("model_info", {}) or {}
        routes.append({
            "model_name": entry.get("model_name", ""),
            "model": lp.get("model", ""),
            "api_base": lp.get("api_base", "") or "",
            "tags": mi.get("tags"),
        })
    return routes


def host_of(api_base: str):
    if not api_base:
        return None
    rest = api_base.split("://", 1)[-1]
    return rest.split("/", 1)[0].split(":", 1)[0]


def http_get_json(url: str, timeout: float):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


VERBOSE = os.environ.get("VERBOSE") == "1"
CPU_FLAG = os.environ.get("CPU_FLAG") == "1"
OLLAMA_MODELS_DIR = os.environ.get("OLLAMA_MODELS_DIR", "")
OLLAMA_MODELS_DIR_SIZE = os.environ.get("OLLAMA_MODELS_DIR_SIZE", "")
OLLAMA_MODELS_DIR_FREE = os.environ.get("OLLAMA_MODELS_DIR_FREE", "")
OLLAMA_VERSION = os.environ.get("OLLAMA_VERSION", "")


def parse_ps_snapshot(raw: str):
    rows = []
    lines = raw.splitlines()[1:]  # drop header
    for line in lines:
        line = line.strip()
        if not line:
            continue
        fields = line.split(None, 3)
        if len(fields) < 4:
            continue
        pid, ppid, pcpu, args = fields
        try:
            rows.append({"pid": int(pid), "pcpu": float(pcpu), "args": fields[3]})
        except ValueError:
            continue
    return rows


def parse_podman_stats(raw: str):
    stats = {}
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) != 2:
            continue
        name, cpu = parts
        try:
            stats[name] = float(cpu.rstrip("%") or 0)
        except ValueError:
            continue
    return stats


PS_ROWS = parse_ps_snapshot(os.environ.get("PS_SNAPSHOT_RAW", "")) if CPU_FLAG else []
PODMAN_CPU = parse_podman_stats(os.environ.get("PODMAN_STATS_RAW", "")) if CPU_FLAG else {}
OLLAMA_PATTERN = re.compile(r"\bollama\b", re.IGNORECASE)
RUNNER_MODEL_RE = re.compile(r"--model\s+(\S+)")


def resolve_weights_digest(models_dir: str, name: str):
    """The digest /api/ps reports is the model *manifest*'s own digest, not
    the weights blob a runner subprocess is invoked with --model <path> for —
    two different hashes (see loads.sh, where this was first worked out and
    verified directly against this stack's own manifests). Read the real
    weights digest out of the manifest file Ollama itself writes to disk."""
    if not models_dir or not name:
        return None
    repo, _, tag = name.partition(":")
    tag = tag or "latest"
    namespace, _, model = repo.rpartition("/")
    namespace = namespace or "library"
    manifest_path = os.path.join(models_dir, "manifests", "registry.ollama.ai", namespace, model, tag)
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except Exception:
        return None
    for layer in manifest.get("layers", []):
        if layer.get("mediaType") == "application/vnd.ollama.image.model":
            return layer.get("digest", "").rsplit(":", 1)[-1].lower()
    return None


def ollama_runners():
    runners = []
    for row in PS_ROWS:
        if not OLLAMA_PATTERN.search(row["args"]):
            continue
        m = RUNNER_MODEL_RE.search(row["args"])
        if not m:
            continue
        blob = os.path.basename(m.group(1))
        digest = re.sub(r"^sha256[:\-]", "", blob).lower()
        runners.append({"pcpu": row["pcpu"], "digest": digest})
    return runners


def cpu_pct_by_model(models_dir: str, loaded_names: list[str]):
    """name -> live CPU% for every currently-loaded Ollama model (from
    /api/ps), matched to its runner subprocess by weights digest. A single
    loaded model with no digest match falls back to the whole ollama
    container/process's CPU total, since that's unambiguous either way."""
    if not CPU_FLAG or not loaded_names:
        return {}
    runners = ollama_runners()
    result = {}
    for name in loaded_names:
        digest = resolve_weights_digest(models_dir, name)
        hits = [r["pcpu"] for r in runners if digest and r["digest"] == digest]
        if hits:
            result[name] = round(sum(hits), 1)
        elif len(loaded_names) == 1 and "ollama" in PODMAN_CPU:
            result[name] = PODMAN_CPU["ollama"]
    return result


def ollama_model_info(base_url: str, tags_response: dict):
    """name -> {size_gb, params, pulled_at} straight from an already-fetched
    /api/tags response — no extra call needed for these fields. pulled_at is
    Ollama's own "modified_at": when this host pulled the model, NOT when the
    model was published upstream (Ollama's API exposes no such date — checked
    both /api/tags and the registry's manifest/config blobs)."""
    info = {}
    for m in (tags_response or {}).get("models", []):
        pulled_at = (m.get("modified_at") or "")[:10] or None
        info[m["name"]] = {
            "size_gb": round(m.get("size", 0) / 1e9, 2),
            "params": (m.get("details") or {}).get("parameter_size"),
            "pulled_at": pulled_at,
        }
    return info


with open(CONFIG_FILE) as f:
    config = json.load(f)

routes = parse_registered_routes(os.environ.get("REGISTERED_ROUTES", ""))

# model_name -> merged tags list from LiteLLM's model_info.tags (L-31/L-35 —
# see output/CENTAURI-playbook.md §13): the "strong-1" style node
# classification plus Ollama's supported-modes capabilities
# (completion/tools/thinking/vision/...), all tagged directly by
# pull-models.sh at registration time — no live /api/show call needed here
# anymore, this is simply what's actually registered. Only present on routes
# that have actually been tagged; None otherwise, not guessed.
tags_by_name = {}
for r in routes:
    if r.get("tags"):
        tags_by_name[r["model_name"]] = r["tags"]

TIER_PATTERN = re.compile(r"^(strong|mid|low|micro)-\d+$")


def split_tags(tags):
    """(classification, modes) from a merged tags list — kept split for JSON
    output's existing shape, even though the human-readable table just shows
    the merged list directly."""
    if not tags:
        return None, None
    classification = None
    modes = []
    for t in tags:
        if classification is None and TIER_PATTERN.match(t):
            classification = t
        else:
            modes.append(t)
    return classification, (modes or None)

# Split cloud (no api_base — hosted providers) from node-attached routes
CLOUD_BACKENDS = {"openai", "groq", "anthropic", "mistral"}
cloud_route_names = {r["model_name"] for r in routes if not r["api_base"]}
node_routes = [r for r in routes if r["api_base"]]

# ---------------------------------------------------------------------------
# Controller (this host) — live probe
# ---------------------------------------------------------------------------
controller_ollama = http_get_json(f"http://localhost:{OLLAMA_PORT}/api/tags", PROBE_TIMEOUT)
controller_vllm = http_get_json(f"http://localhost:{VLLM_PORT}/v1/models", PROBE_TIMEOUT)

controller_available = []
if controller_ollama:
    for m in controller_ollama.get("models", []):
        controller_available.append((m["name"], "ollama"))
if controller_vllm:
    for m in controller_vllm.get("data", []):
        controller_available.append((m["id"], "vllm"))

CONTROLLER_HOSTS = {"ollama.ai-stack", "vllm.ai-stack", "localhost", "127.0.0.1"}
controller_registered = {
    r["model_name"] for r in node_routes if host_of(r["api_base"]) in CONTROLLER_HOSTS
}

# -cpu only: which Ollama models are actually resident right now (/api/ps —
# a separate, smaller list than /api/tags above, which is every model ever
# pulled regardless of whether it's loaded), and vLLM's one served model's
# container CPU total (no digest matching needed, there's only ever one).
controller_loaded_names = []
vllm_cpu_pct = None
if CPU_FLAG:
    controller_ps = http_get_json(f"http://localhost:{OLLAMA_PORT}/api/ps", PROBE_TIMEOUT)
    controller_loaded_names = [m["name"] for m in (controller_ps or {}).get("models", [])]
    if controller_vllm and controller_vllm.get("data"):
        vllm_cpu_pct = PODMAN_CPU.get("vllm")
cpu_pct_by_name = cpu_pct_by_model(OLLAMA_MODELS_DIR, controller_loaded_names)

nodes_report = []

controller_file = os.path.join(NODES_DIR, "controller-1.json")
controller_alias = "controller-1"
controller_node_id = "CENTAURI"
controller_profile = "controller"
if os.path.isfile(controller_file):
    with open(controller_file) as f:
        cdata = json.load(f)
    controller_alias = cdata.get("alias", controller_alias)
    controller_node_id = cdata.get("node_id", controller_node_id)
    controller_profile = cdata.get("profile", controller_profile)

names = {name for name, _ in controller_available} | controller_registered
model_entries = []
backend_by_name = dict(controller_available)
controller_ollama_info = ollama_model_info(f"http://localhost:{OLLAMA_PORT}", controller_ollama)
for name in sorted(names):
    backend = backend_by_name.get(name)
    classification, modes = split_tags(tags_by_name.get(name))
    entry = {
        "name": name,
        "backend": backend,
        "available": name in backend_by_name,
        "registered": name in controller_registered,
        "size_gb": None, "params": None, "pulled_at": None, "cpu_pct": None,
        "classification": classification, "modes": modes,
    }
    if backend == "ollama" and name in controller_ollama_info:
        entry["size_gb"] = controller_ollama_info[name]["size_gb"]
        entry["params"] = controller_ollama_info[name]["params"]
        entry["pulled_at"] = controller_ollama_info[name]["pulled_at"]
    if backend == "ollama" and name in cpu_pct_by_name:
        entry["cpu_pct"] = cpu_pct_by_name[name]
    elif backend == "vllm":
        entry["cpu_pct"] = vllm_cpu_pct
    model_entries.append(entry)

nodes_report.append({
    "alias": controller_alias,
    "node_id": controller_node_id,
    "profile": controller_profile,
    "address": "localhost",
    "online": bool(controller_ollama or controller_vllm),
    "models": model_entries,
    "models_dir": OLLAMA_MODELS_DIR or None,
    "models_dir_size": OLLAMA_MODELS_DIR_SIZE or None,
    "models_dir_free": OLLAMA_MODELS_DIR_FREE or None,
    "ollama_version": OLLAMA_VERSION or None,
})

# ---------------------------------------------------------------------------
# Remote nodes (from configs/nodes/*.json, profile != controller)
# ---------------------------------------------------------------------------
for fname in sorted(os.listdir(NODES_DIR)):
    if not fname.endswith(".json"):
        continue
    path = os.path.join(NODES_DIR, fname)
    with open(path) as f:
        node = json.load(f)
    if node.get("profile") == "controller":
        continue

    alias = node.get("alias", fname)
    address = node.get("address") or ""
    fallback = node.get("address_fallback") or ""

    resolved = None
    tags = None
    for candidate in [c for c in (address, fallback) if c]:
        body = http_get_json(f"http://{candidate}:11434/api/tags", PROBE_TIMEOUT)
        if body is not None:
            resolved = candidate
            tags = body
            break

    available = []
    if tags:
        available = [m["name"] for m in tags.get("models", [])]

    # Registered routes attributed to this node: api_base host matches its
    # address or fallback (plain-name base routes may also live here if the
    # base entry itself was generated with a "host" pointing at this node).
    node_hosts = {h for h in (address, fallback) if h}
    node_registered = {
        r["model_name"] for r in node_routes if host_of(r["api_base"]) in node_hosts
    }

    names = set(available) | node_registered
    model_entries = []
    node_ollama_info = ollama_model_info(f"http://{resolved}:11434", tags) if resolved else {}
    for name in sorted(names):
        classification, modes = split_tags(tags_by_name.get(name))
        entry = {
            "name": name,
            "backend": "ollama",
            "available": name in available,
            "registered": name in node_registered,
            "size_gb": None, "params": None, "pulled_at": None, "cpu_pct": None,
            "classification": classification, "modes": modes,
        }
        if name in node_ollama_info:
            entry["size_gb"] = node_ollama_info[name]["size_gb"]
            entry["params"] = node_ollama_info[name]["params"]
            entry["pulled_at"] = node_ollama_info[name]["pulled_at"]
        model_entries.append(entry)

    nodes_report.append({
        "alias": alias,
        "node_id": node.get("node_id", alias),
        "profile": node.get("profile"),
        "address": resolved or address or fallback,
        "online": resolved is not None,
        "models": model_entries,
        "models_dir": None,  # filesystem-level info, only ever knowable for the controller
        "models_dir_size": None,
        "models_dir_free": None,
        "ollama_version": None,  # would need a live /api/version probe per remote node; not done here
    })

# ---------------------------------------------------------------------------
# Cloud / API-hosted models — from config.json's models[], no live call
# ---------------------------------------------------------------------------
cloud_report = []
for m in config.get("models", []):
    backend = m.get("backend")
    if backend not in CLOUD_BACKENDS:
        continue
    secret_name = m.get("api_key_secret", f"{backend}_api_key")
    cloud_report.append({
        "name": m["name"],
        "backend": backend,
        "registered": m["name"] in cloud_route_names,
        "secret_provisioned": secret_name in PROVISIONED_SECRETS,
        "secret_name": secret_name,
    })

report = {
    "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "nodes": nodes_report,
    "cloud": cloud_report,
}

if OUTPUT_FORMAT == "json":
    print(json.dumps(report, indent=2))
    sys.exit(0)

# ---------------------------------------------------------------------------
# Human-readable report — one aligned table per node, dim-red highlighting
# on anything not fully OK when --color is set.
# ---------------------------------------------------------------------------
def status_of(entry):
    if entry["available"] and entry["registered"]:
        return "ok", True
    if entry["available"] and not entry["registered"]:
        return "unregistered", False
    if entry["registered"] and not entry["available"]:
        return "stale", False
    return "unknown", False


NAME_W, BACKEND_W, STATUS_W = 42, 8, 14
SIZE_W, PARAMS_W, PULLED_W, LOAD_W = 9, 7, 10, 7

for i, node in enumerate(nodes_report):
    state = "online" if node["online"] else "offline"
    state_disp = colorize(state, node["online"])
    header = f"{node['node_id']} ({node['alias']}) — {state_disp} — {node['address']}"
    print(f"{BOLD}{header}{RESET}" if USE_COLOR else header)
    if VERBOSE and node.get("ollama_version"):
        print(f"  Ollama version: {node['ollama_version']}")
    if VERBOSE and node.get("models_dir"):
        free_part = f", free: {node['models_dir_free']}" if node.get("models_dir_free") else ""
        print(f"  model repository: {node['models_dir']}  (total size: {node['models_dir_size'] or '?'}{free_part})")

    if not node["models"]:
        print("  (no models available or registered)\n")
        continue

    print()
    header_line = f"  {'MODEL':<{NAME_W}} {'BACKEND':<{BACKEND_W}} {'STATUS':<{STATUS_W}}"
    if CPU_FLAG:
        header_line += f" {'LOAD':>{LOAD_W}}"
    if VERBOSE:
        header_line += f" {'SIZE':>{SIZE_W}} {'PARAMS':>{PARAMS_W}} {'PULLED':<{PULLED_W}}  TAGS"
    print(header_line)
    for entry in node["models"]:
        status, ok = status_of(entry)
        backend = entry["backend"] or "?"
        line = f"  {entry['name']:<{NAME_W}} {backend:<{BACKEND_W}} {status:<{STATUS_W}}"
        if CPU_FLAG:
            # "-" covers two different things: a model that isn't currently
            # loaded (most rows, most of the time — this is a live snapshot),
            # and a remote node, where this script has no way to see
            # processes at all (HTTP-only, no SSH/ps access).
            load = f"{entry['cpu_pct']}%" if entry.get("cpu_pct") is not None else "-"
            line += f" {load:>{LOAD_W}}"
        if VERBOSE:
            size = f"{entry['size_gb']}GB" if entry.get("size_gb") is not None else "-"
            params = entry.get("params") or "-"
            # PULLED is when THIS HOST downloaded the model (Ollama's own
            # modified_at) — not an upstream release/publication date, which
            # Ollama's API exposes nowhere (checked /api/tags and the
            # registry's manifest/config blobs — neither has one).
            pulled = entry.get("pulled_at") or "-"
            # One merged TAGS column (classification + modes together) — the
            # JSON output below keeps them as two separate keys, this is
            # purely a human-readability simplification (L-35). Modes are
            # stored pre-sorted by pull-models.sh, so this is already a
            # consistent order across models — nothing to re-sort here.
            merged_tags = ([entry["classification"]] if entry.get("classification") else []) + (entry.get("modes") or [])
            tags_display = ",".join(merged_tags) if merged_tags else "-"
            line += f" {size:>{SIZE_W}} {params:>{PARAMS_W}} {pulled:<{PULLED_W}}  {tags_display}"
        print(colorize(line, ok))
    print()

print(f"{BOLD}Cloud / API-hosted{RESET}" if USE_COLOR else "Cloud / API-hosted")
print(f"  {'MODEL':<{NAME_W-17}} {'BACKEND':<{BACKEND_W+2}} STATUS")
for entry in cloud_report:
    ok = entry["registered"] and entry["secret_provisioned"]
    if not entry["registered"]:
        status = "unregistered"
    elif not entry["secret_provisioned"]:
        status = f"no secret ({entry['secret_name']})"
    else:
        status = "ok"
    line = f"  {entry['name']:<{NAME_W-17}} {entry['backend']:<{BACKEND_W+2}} {status}"
    print(colorize(line, ok))
PYEOF
