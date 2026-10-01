#!/usr/bin/env bash
# scripts/loads.sh — CPU (and, where available, GPU) load per stack component
# and per currently loaded AI model.
#
# Two views:
#   1. By component — containerized services get their CPU%/MEM% straight
#      from `podman stats` (matches diagnose.sh's resource-pressure check).
#      Services with no container (e.g. a bare-metal macOS Ollama install)
#      fall back to summing `ps` CPU% across their matching processes.
#   2. By model — nested under their serving component ("ollama"/"vllm"),
#      sorted by CPU% descending, as "<hostname>/<model name>". Currently
#      loaded Ollama models (GET /api/ps) are each attributed their own CPU%
#      (and GPU% if nvidia-smi is present) by matching their runner
#      subprocess back to them. Ollama gives every loaded model its own
#      runner subprocess invoked with `--model <blob-path>`, and the blob
#      filename is the model's weights digest — but that digest has to be
#      read out of Ollama's own manifest file on disk, since /api/ps's
#      "digest" field is the *manifest's* digest, a different hash that
#      never matches the blob path (confirmed against this stack's own
#      manifests; see the big comment on resolve_weights_digest() below). A
#      single vLLM instance serves exactly one model in this stack, so its
#      component total is attributed to that model directly — no matching
#      needed. Each Ollama row also shows parameter count and on-disk file
#      size, straight from Ollama's own "details.parameter_size"/"size"
#      fields (GET /api/ps for loaded models, /api/tags for -v's unloaded
#      ones) — vLLM's plain OpenAI-compatible /v1/models has no such
#      metadata, so those rows show "-" rather than an approximation.
#
#      Each model row also shows which OpenWebUI user most recently got an
#      assistant turn from it, as "user (now)" / "user (12m ago)", looking
#      back up to ACTIVE_LOOKBACK_SECONDS (empty only if no one has, that
#      far back). This is read from OpenWebUI's own webui.db, not LiteLLM:
#      LiteLLM's request logs show every request from this stack's OpenWebUI
#      as the literal string "default_user_id" (real per-person identity
#      never reaches LiteLLM), so they're useless for this. OpenWebUI's
#      `user` table has it instead — populated with the real name/email from
#      Authentik at first SSO login — so "user" here means the
#      OpenWebUI/Authentik identity, not a Linux account. Same "last
#      completed turn, not true live" caveat as everywhere else in this
#      script that reports something as "active".
#
#      With -v/--all, models pulled but not currently loaded (GET /api/tags,
#      minus whatever /api/ps already reported) are listed too, marked
#      [not loaded] — they have no runner process, so there is genuinely no
#      CPU/GPU/user data for them, unlike a loaded model whose attribution
#      merely failed.
#
#   3. LiteLLM — nested under its own "litellm" component row: every model
#      it has registered (GET /model/info, local ollama/vllm routes and
#      cloud providers alike — this is "what's there"), each showing how
#      long since its last successful request ("last used: 12m ago"/"-"),
#      from GET /spend/logs/v2 filtered to the last ACTIVE_LOOKBACK_SECONDS
#      ("what's in use"). This is a genuinely different signal from the
#      OpenWebUI-based one above: OpenWebUI can talk to Ollama directly for
#      local models, bypassing LiteLLM entirely, so it's normal for a model
#      to show recent OpenWebUI activity while LiteLLM shows "last used: -"
#      for the very same model — that's not a bug, it's two different paths
#      into the same backend disagreeing honestly. Needs the
#      litellm_master_key Podman secret; skipped (not an error) if podman or
#      the secret aren't available.
#
#   When attribution genuinely isn't possible (manifest file not found —
#   e.g. a non-default Ollama models directory — or an unrecognized process
#   layout), the model's CPU/GPU columns show "-" rather than a guessed
#   split; the component table's "ollama"/"vllm" row still has the real
#   total. The component and model tables also use different measurement
#   methods (`podman stats`'s recent-window snapshot vs. `ps`'s
#   longer decaying average), so don't expect the two to sum neatly even
#   when attribution succeeds — both are real, just averaged differently.
#
#   4. Swap — usage (SwapTotal/SwapFree) plus a live swap-in/swap-out rate
#      sampled from /proc/vmstat over a short window. Usage alone can sit
#      high from old idle pages with no current pressure; the I/O rate is
#      what actually indicates a machine is thrashing right now, and gets
#      flagged [THRASHING] past SWAP_THRASH_THRESHOLD_MB_S.
#
# Local host only. For fleet-wide model placement across worker nodes, see
# model-inventory.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
CONFIG_FILE="${CONFIG_FILE:-$AI_STACK_DIR/configs/config.json}"
PROBE_TIMEOUT="${PROBE_TIMEOUT:-3}"
ACTIVE_WINDOW_SECONDS="${ACTIVE_WINDOW_SECONDS:-30}"
ACTIVE_LOOKBACK_SECONDS="${ACTIVE_LOOKBACK_SECONDS:-21600}"

usage() {
    cat <<'EOF'
Usage: loads.sh [options]

Purpose:
  Show current CPU load broken down two ways: per stack component
  (podman container, or bare-metal process where no container exists)
  and per currently-loaded AI model, nested under its serving component,
  each with parameter count and on-disk file size. Adds a GPU% column per
  model when nvidia-smi is present, and which
  OpenWebUI user last chatted with it, shown as "user (now)"/"user (12m
  ago)" rather than going blank the moment a conversation pauses. Also
  nests LiteLLM's full registered model catalog (local + cloud) under its
  own component row, each with how long since its last successful request
  through the proxy — a separate signal from OpenWebUI's, since OpenWebUI
  can talk to Ollama directly and bypass LiteLLM for local models. Also
  reports swap usage and live swap I/O rate, flagging [THRASHING] when a
  machine is actively swapping under memory pressure (as opposed to just
  sitting on old swapped-out pages).

Options:
  --json        Emit structured JSON instead of the human-readable report
  -v, --all     Also list Ollama models that are pulled but not currently
                loaded (from /api/tags), marked [not loaded] with no CPU/
                GPU/user data since nothing is running for them
  -h, --help    Show this message

Environment:
  CONFIG_FILE               Path to config.json  (default: $AI_STACK_DIR/configs/config.json)
  OLLAMA_URL                Ollama base URL      (default: http://localhost:<configured port, else 11434>)
  VLLM_URL                  vLLM base URL        (default: http://localhost:<configured port, else 8000>)
  LITELLM_URL               LiteLLM base URL     (default: http://localhost:<configured port, else 9000>)
  OLLAMA_MODELS             Ollama models dir, for per-model CPU/GPU attribution
                            (default: $AI_STACK_DIR/ollama/models, else ~/.ollama/models)
  PROBE_TIMEOUT             Seconds per HTTP probe (default: 3)
  SWAP_THRASH_THRESHOLD_MB_S  Swap I/O rate (MB/s) that triggers the [THRASHING] flag (default: 1.0)
  ACTIVE_WINDOW_SECONDS     How recent an OpenWebUI chat turn must be to display as
                            "(now)" rather than an age like "12m ago" (default: 30)
  ACTIVE_LOOKBACK_SECONDS   How far back to search OpenWebUI's chat history for a
                            model's last user before giving up and showing blank
                            (default: 21600 = 6h)
EOF
}

OUTPUT_FORMAT="text"
SHOW_ALL_MODELS=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --json)     OUTPUT_FORMAT="json"; shift ;;
        -v|--all)   SHOW_ALL_MODELS=1; shift ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

for cmd in python3 ps; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

OLLAMA_PORT=11434
VLLM_PORT=8000
LITELLM_PORT=9000
if [[ -f "$CONFIG_FILE" ]] && command -v jq &>/dev/null; then
    OLLAMA_PORT="$(jq -r '.services.ollama.ports[0].host // 11434' "$CONFIG_FILE" 2>/dev/null || echo 11434)"
    VLLM_PORT="$(jq -r '.services.vllm.ports[0].host // 8000' "$CONFIG_FILE" 2>/dev/null || echo 8000)"
    LITELLM_PORT="$(jq -r '.services.litellm.ports[0].host // 9000' "$CONFIG_FILE" 2>/dev/null || echo 9000)"
fi
OLLAMA_URL="${OLLAMA_URL:-http://localhost:$OLLAMA_PORT}"
VLLM_URL="${VLLM_URL:-http://localhost:$VLLM_PORT}"
LITELLM_URL="${LITELLM_URL:-http://localhost:$LITELLM_PORT}"

# LiteLLM's registered model catalog (what's configured, local + cloud) and
# recent successful-request recency per target model (what's actually seeing
# traffic) — same master-key-via-podman-secret pattern as model-inventory.sh's
# _resolve_litellm_key(). Degrades to "no LiteLLM data" if podman or the
# secret aren't available (e.g. a bare-metal-only worker node).
LITELLM_MODEL_INFO_RAW="{}"
LITELLM_SPEND_RAW="{}"
if command -v podman &>/dev/null; then
    _litellm_key="$(podman run --rm --secret litellm_master_key docker.io/library/alpine:latest \
        sh -c 'cat /run/secrets/litellm_master_key' 2>/dev/null || true)"
    if [[ -n "$_litellm_key" ]]; then
        LITELLM_MODEL_INFO_RAW="$(curl -s --max-time "$PROBE_TIMEOUT" \
            -H "Authorization: Bearer $_litellm_key" "$LITELLM_URL/model/info" 2>/dev/null || echo '{}')"
        # start_date/end_date are mandatory on /spend/logs/v2 and must be
        # 'YYYY-MM-DD HH:MM:SS' — built via python3 (already a hard dependency)
        # rather than GNU-vs-BSD `date -d`/`date -r` differences.
        _now_str="$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%d %H:%M:%S"))')"
        _start_str="$(python3 -c "import datetime; print((datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(seconds=${ACTIVE_LOOKBACK_SECONDS})).strftime('%Y-%m-%d %H:%M:%S'))")"
        LITELLM_SPEND_RAW="$(curl -s --max-time "$PROBE_TIMEOUT" -G \
            -H "Authorization: Bearer $_litellm_key" "$LITELLM_URL/spend/logs/v2" \
            --data-urlencode "start_date=$_start_str" --data-urlencode "end_date=$_now_str" \
            --data-urlencode "page_size=100" --data-urlencode "sort_by=startTime" \
            --data-urlencode "sort_order=desc" --data-urlencode "status_filter=success" \
            2>/dev/null || echo '{}')"
    fi
fi

PODMAN_STATS_RAW=""
PODMAN_NAMES_RAW=""
if command -v podman &>/dev/null; then
    PODMAN_NAMES_RAW="$(podman ps --format '{{.Names}}' 2>/dev/null || true)"
    PODMAN_STATS_RAW="$(podman stats --no-stream --no-trunc \
        --format '{{.Name}}	{{.CPUPerc}}	{{.MemPerc}}' 2>/dev/null || true)"
fi

# Host-wide snapshot — on Linux this includes containerized processes too
# (podman doesn't hide PIDs from the host's own /proc), so one snapshot
# covers bare-metal and containerized services alike.
PS_SNAPSHOT_RAW="$(ps -A -o pid,ppid,pcpu,args 2>/dev/null || true)"

NVIDIA_PMON_RAW=""
if command -v nvidia-smi &>/dev/null; then
    NVIDIA_PMON_RAW="$(nvidia-smi pmon -c 1 2>/dev/null || true)"
fi

# Which OpenWebUI user most recently got an assistant turn from each model,
# looking back up to ACTIVE_LOOKBACK_SECONDS. Read directly out of OpenWebUI's
# own webui.db (same podman-exec-a-python-one-liner convention as
# check-provisioning.py's fetch_openwebui_users()) rather than LiteLLM's spend
# logs: this stack's OpenWebUI→LiteLLM calls all show up there as the literal
# string "default_user_id" (LiteLLM never gets told who the real person is),
# so LiteLLM has no usable per-person identity at all. OpenWebUI's own `user`
# table does — it's populated with the real name/email from Authentik at
# first SSO login — and each chat's `history.messages` already records which
# model answered and when. This is still a look at the last *completed* turn,
# not a true live/in-flight signal (same caveat as everywhere else in this
# script that reports "active") — the Python side below turns the returned
# timestamp into a "(now)" / "(12m ago)" age instead of a hard cutoff, since a
# short fixed window went blank mid-conversation whenever someone paused more
# than a few seconds to read a response.
OPENWEBUI_ACTIVE_RAW="[]"
if command -v podman &>/dev/null && podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "openwebui"; then
    _owui_query='
import json, os, sqlite3, time
cutoff = int(time.time()) - int(os.environ.get("ACTIVE_LOOKBACK_SECONDS", "21600"))
conn = sqlite3.connect("/app/backend/data/webui.db")
cur = conn.cursor()
cur.execute("SELECT chat, user_id FROM chat WHERE updated_at >= ?", (cutoff,))
rows = cur.fetchall()
user_cache = {}
results = []
for chat_json, user_id in rows:
    try:
        data = json.loads(chat_json)
    except Exception:
        continue
    msgs = (data.get("history") or {}).get("messages") or {}
    for m in msgs.values():
        if m.get("role") != "assistant":
            continue
        model = m.get("model")
        ts = m.get("timestamp")
        if not model or not ts or ts < cutoff:
            continue
        if user_id not in user_cache:
            cur.execute("SELECT name, email FROM user WHERE id=?", (user_id,))
            r = cur.fetchone()
            user_cache[user_id] = (r[1] or r[0]) if r else None
        results.append({"model": model, "ts": ts, "user": user_cache[user_id]})
print(json.dumps(results))
'
    OPENWEBUI_ACTIVE_RAW="$(podman exec -e ACTIVE_LOOKBACK_SECONDS="$ACTIVE_LOOKBACK_SECONDS" openwebui \
        python3 -c "$_owui_query" 2>/dev/null || echo '[]')"
fi

# Where Ollama keeps its model manifests/blobs — needed to resolve a loaded
# model's actual weights-blob digest (see the big comment above runner_re in
# the Python below for why /api/ps's own "digest" field can't be used for this).
# $AI_STACK_DIR/ollama is where config.json.example bind-mounts it for a
# podman-managed ollama; bare-metal installs use $OLLAMA_MODELS or ~/.ollama.
OLLAMA_MODELS_DIR=""
for _candidate in "${OLLAMA_MODELS:-}" "$AI_STACK_DIR/ollama/models" "$HOME/.ollama/models"; do
    if [[ -n "$_candidate" && -d "$_candidate" ]]; then
        OLLAMA_MODELS_DIR="$_candidate"
        break
    fi
done

export CONFIG_FILE OLLAMA_URL VLLM_URL PROBE_TIMEOUT OUTPUT_FORMAT OLLAMA_MODELS_DIR ACTIVE_WINDOW_SECONDS SHOW_ALL_MODELS
export PODMAN_STATS_RAW PODMAN_NAMES_RAW PS_SNAPSHOT_RAW NVIDIA_PMON_RAW OPENWEBUI_ACTIVE_RAW
export LITELLM_MODEL_INFO_RAW LITELLM_SPEND_RAW

python3 <<'PYEOF'
import json
import os
import re
import sys
import time
import urllib.request

OLLAMA_URL = os.environ["OLLAMA_URL"]
VLLM_URL = os.environ["VLLM_URL"]
PROBE_TIMEOUT = float(os.environ["PROBE_TIMEOUT"])
OUTPUT_FORMAT = os.environ["OUTPUT_FORMAT"]

# Mirrors status.sh's _svc_category taxonomy so the same mental model
# (and the same CENTAURI-playbook §2.2 service inventory) applies here too.
CATEGORY = {
    "openwebui": "Applications", "flowise": "Applications", "homepage": "Applications",
    "traefik": "Edge & Routing",
    "litellm": "Model Serving", "ollama": "Model Serving", "vllm": "Model Serving",
    "knowledge-index": "Knowledge / RAG",
    "postgres": "Storage & Data", "qdrant": "Storage & Data", "minio": "Storage & Data",
    "redis": "Storage & Data",
    "grafana": "Observability & Metrics", "prometheus": "Observability & Metrics",
    "loki": "Observability & Metrics", "promtail": "Observability & Metrics",
}
CATEGORY_ORDER = [
    "Edge & Routing", "Applications", "Model Serving",
    "Knowledge / RAG", "Storage & Data", "Observability & Metrics", "Other",
]

BARE_METAL_PATTERNS = {
    "ollama": re.compile(r"\bollama\b", re.IGNORECASE),
    "vllm": re.compile(r"\bvllm\b", re.IGNORECASE),
}


def http_get_json(url, timeout):
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return json.loads(resp.read().decode())
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Parse podman stats / ps / nvidia-smi snapshots
# ---------------------------------------------------------------------------

def parse_podman_stats(raw):
    stats = {}
    for line in raw.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        name, cpu, mem = parts
        stats[name] = {
            "cpu_pct": float(cpu.rstrip("%") or 0),
            "mem_pct": float(mem.rstrip("%") or 0),
        }
    return stats


def parse_ps_snapshot(raw):
    rows = []
    lines = raw.splitlines()
    if lines:
        lines = lines[1:]  # header
    for line in lines:
        line = line.strip()
        if not line:
            continue
        fields = line.split(None, 3)
        if len(fields) < 4:
            continue
        pid, ppid, pcpu, args = fields
        try:
            rows.append({"pid": int(pid), "ppid": int(ppid), "pcpu": float(pcpu), "args": fields[3]})
        except ValueError:
            continue
    return rows


def parse_nvidia_pmon(raw):
    """pid -> {'sm_pct': float, 'mem_pct': float}. Tolerates '-' for unsupported fields."""
    by_pid = {}
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        cols = line.split()
        if len(cols) < 5:
            continue
        try:
            pid = int(cols[1])
        except ValueError:
            continue

        def _num(x):
            try:
                return float(x)
            except ValueError:
                return 0.0

        by_pid[pid] = {"sm_pct": _num(cols[3]), "mem_pct": _num(cols[4])}
    return by_pid


podman_stats = parse_podman_stats(os.environ.get("PODMAN_STATS_RAW", ""))
podman_names = {n for n in os.environ.get("PODMAN_NAMES_RAW", "").splitlines() if n}
ps_rows = parse_ps_snapshot(os.environ.get("PS_SNAPSHOT_RAW", ""))
gpu_by_pid = parse_nvidia_pmon(os.environ.get("NVIDIA_PMON_RAW", ""))
has_gpu = bool(gpu_by_pid) or bool(os.environ.get("NVIDIA_PMON_RAW", "").strip())

# model name -> the OpenWebUI user (name/email) whose chat most recently got
# an assistant turn from it, looking back up to ACTIVE_LOOKBACK_SECONDS (see
# the big comment in the bash section above on why this comes from
# OpenWebUI's own webui.db rather than LiteLLM).
active_user_by_model = {}
try:
    for entry in json.loads(os.environ.get("OPENWEBUI_ACTIVE_RAW", "[]")):
        model, ts, user = entry.get("model"), entry.get("ts"), entry.get("user")
        if not model or not user:
            continue
        prev = active_user_by_model.get(model)
        if prev is None or ts > prev[1]:
            active_user_by_model[model] = (user, ts)
except Exception:
    pass

ACTIVE_WINDOW_SECONDS = float(os.environ.get("ACTIVE_WINDOW_SECONDS", "30"))


def resolve_active_user(model_name):
    """(user, seconds_ago) for a model's last known OpenWebUI chatter, or
    ("", None) if nothing was found within ACTIVE_LOOKBACK_SECONDS."""
    hit = active_user_by_model.get(model_name)
    if not hit:
        return "", None
    user, ts = hit
    return user, round(time.time() - ts)


def humanize_age(seconds_ago):
    if seconds_ago is None:
        return ""
    if seconds_ago <= ACTIVE_WINDOW_SECONDS:
        return "now"
    seconds_ago = int(seconds_ago)
    if seconds_ago < 3600:
        return f"{seconds_ago // 60}m ago"
    if seconds_ago < 86400:
        return f"{seconds_ago // 3600}h ago"
    return f"{seconds_ago // 86400}d ago"


HOSTNAME = __import__("socket").gethostname()

# ---------------------------------------------------------------------------
# Components — one row per containerized service, plus bare-metal services
# (ollama/vllm) that have no container but do have matching processes.
# ---------------------------------------------------------------------------

components = []
for name in sorted(podman_names):
    stat = podman_stats.get(name, {"cpu_pct": 0.0, "mem_pct": 0.0})
    components.append({
        "name": name, "mode": "container",
        "category": CATEGORY.get(name, "Other"),
        "cpu_pct": stat["cpu_pct"], "mem_pct": stat["mem_pct"],
    })

bare_metal_pids = {}  # svc -> [pid, ...], for model-level GPU/CPU attribution below
for svc, pattern in BARE_METAL_PATTERNS.items():
    if svc in podman_names:
        continue  # already covered by podman stats above
    matches = [r for r in ps_rows if pattern.search(r["args"])]
    if not matches:
        continue
    bare_metal_pids[svc] = [r["pid"] for r in matches]
    components.append({
        "name": svc, "mode": "bare-metal",
        "category": CATEGORY.get(svc, "Other"),
        "cpu_pct": round(sum(r["pcpu"] for r in matches), 1), "mem_pct": None,
    })

# For containerized ollama/vllm, model-level attribution still needs their
# runner PIDs — host `ps` sees them regardless of container boundaries.
for svc, pattern in BARE_METAL_PATTERNS.items():
    if svc not in bare_metal_pids:
        matches = [r for r in ps_rows if pattern.search(r["args"])]
        if matches:
            bare_metal_pids[svc] = [r["pid"] for r in matches]

# ---------------------------------------------------------------------------
# Models — currently loaded Ollama models, attributed to their runner PID
# via digest (blob filename == content digest, sha256-prefixed on disk).
# ---------------------------------------------------------------------------

models = []

ollama_ps = http_get_json(f"{OLLAMA_URL}/api/ps", PROBE_TIMEOUT)
loaded = (ollama_ps or {}).get("models", [])

OLLAMA_MODELS_DIR = os.environ.get("OLLAMA_MODELS_DIR", "")


def resolve_weights_digest(name):
    """The digest /api/ps reports is the model *manifest*'s own digest, not
    the weights blob a runner subprocess is invoked with — those are two
    different hashes (verified directly against this stack's own manifests:
    /api/ps digest 'ca06e9e4...9074' vs. the model-layer digest '30e51a7c...
    2ffb' that the running `ollama runner --model .../sha256-30e51a7c...`
    actually used). So the only reliable way to get the weights digest is to
    read it out of the manifest file Ollama itself writes to disk.
    """
    if not OLLAMA_MODELS_DIR or not name:
        return None
    repo, _, tag = name.partition(":")
    tag = tag or "latest"
    namespace, _, model = repo.rpartition("/")
    namespace = namespace or "library"
    manifest_path = os.path.join(OLLAMA_MODELS_DIR, "manifests", "registry.ollama.ai", namespace, model, tag)
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except Exception:
        return None
    for layer in manifest.get("layers", []):
        if layer.get("mediaType") == "application/vnd.ollama.image.model":
            return layer.get("digest", "").rsplit(":", 1)[-1].lower()
    return None


runner_re = re.compile(r"--model\s+(\S+)")
runners = []  # {pid, pcpu, digest}
for row in ps_rows:
    if not BARE_METAL_PATTERNS["ollama"].search(row["args"]):
        continue
    m = runner_re.search(row["args"])
    if not m:
        continue
    blob = os.path.basename(m.group(1))
    digest = re.sub(r"^sha256[:\-]", "", blob).lower()
    runners.append({"pid": row["pid"], "pcpu": row["pcpu"], "digest": digest})

matched_pids = set()
for m in loaded:
    weights_digest = resolve_weights_digest(m.get("name", ""))
    hits = [r for r in runners if weights_digest and r["digest"] == weights_digest]
    cpu_pct = None
    gpu_pct = None
    if hits:
        cpu_pct = round(sum(h["pcpu"] for h in hits), 1)
        matched_pids.update(h["pid"] for h in hits)
        gpu_vals = [gpu_by_pid[h["pid"]]["sm_pct"] for h in hits if h["pid"] in gpu_by_pid]
        if gpu_vals:
            gpu_pct = round(sum(gpu_vals), 1)
    elif len(loaded) == 1 and "ollama" in bare_metal_pids:
        # Sole loaded model — the whole ollama process total is unambiguously
        # its load, even if the runner subprocess didn't match on digest.
        cpu_pct = next((c["cpu_pct"] for c in components if c["name"] == "ollama"), None)
        gpu_vals = [v["sm_pct"] for pid, v in gpu_by_pid.items() if pid in bare_metal_pids["ollama"]]
        if gpu_vals:
            gpu_pct = round(sum(gpu_vals), 1)

    active_user, active_age_s = resolve_active_user(m.get("name", ""))
    models.append({
        "name": m.get("name", "?"), "backend": "ollama", "host": HOSTNAME, "loaded": True,
        "cpu_pct": cpu_pct, "gpu_pct": gpu_pct,
        "size_gb": round(m.get("size", 0) / 1e9, 2),
        "vram_gb": round(m.get("size_vram", 0) / 1e9, 2),
        "params": (m.get("details") or {}).get("parameter_size"),
        "expires_at": m.get("expires_at"),
        "user": active_user, "user_active_age_s": active_age_s,
        "target": None, "last_used_age_s": None,
    })

unattributed = [r for r in runners if r["pid"] not in matched_pids]
if unattributed and len(loaded) != 1:
    models.append({
        "name": f"(unattributed — {len(unattributed)} ollama runner process(es))",
        "backend": "ollama", "host": HOSTNAME, "loaded": True,
        "cpu_pct": round(sum(r["pcpu"] for r in unattributed), 1), "gpu_pct": None,
        "size_gb": None, "vram_gb": None, "params": None, "expires_at": None,
        "user": "", "user_active_age_s": None,
        "target": None, "last_used_age_s": None,
    })

# vLLM — one instance serves exactly one model in this stack, so its
# component total attributes directly; no digest matching needed. Its
# OpenAI-compatible /v1/models has no size/parameter metadata at all, unlike
# Ollama's — left blank rather than approximated from config.json.
vllm_models = http_get_json(f"{VLLM_URL}/v1/models", PROBE_TIMEOUT)
for entry in (vllm_models or {}).get("data", []):
    cpu_pct = next((c["cpu_pct"] for c in components if c["name"] == "vllm"), None)
    gpu_vals = [v["sm_pct"] for pid, v in gpu_by_pid.items() if pid in bare_metal_pids.get("vllm", [])]
    active_user, active_age_s = resolve_active_user(entry.get("id", ""))
    models.append({
        "name": entry.get("id", "?"), "backend": "vllm", "host": HOSTNAME, "loaded": True,
        "cpu_pct": cpu_pct, "gpu_pct": round(sum(gpu_vals), 1) if gpu_vals else None,
        "size_gb": None, "vram_gb": None, "params": None, "expires_at": None,
        "user": active_user, "user_active_age_s": active_age_s,
        "target": None, "last_used_age_s": None,
    })

# -v/--all — also list Ollama models that are pulled but not currently
# loaded (GET /api/tags is every locally-pulled model; /api/ps above is only
# the ones actually resident). These have no runner process at all, so there
# is genuinely nothing to report for CPU/GPU/user — shown as "-" plus a
# [not loaded] marker so it reads distinctly from a *loaded* model whose
# attribution merely failed (see resolve_weights_digest() above).
if os.environ.get("SHOW_ALL_MODELS") == "1":
    ollama_tags = http_get_json(f"{OLLAMA_URL}/api/tags", PROBE_TIMEOUT)
    loaded_names = {m.get("name") for m in loaded}
    for m in (ollama_tags or {}).get("models", []):
        if m.get("name") in loaded_names:
            continue
        models.append({
            "name": m.get("name", "?"), "backend": "ollama", "host": HOSTNAME, "loaded": False,
            "cpu_pct": None, "gpu_pct": None,
            "size_gb": round(m.get("size", 0) / 1e9, 2), "vram_gb": 0.0,
            "params": (m.get("details") or {}).get("parameter_size"), "expires_at": None,
            "user": "", "user_active_age_s": None,
            "target": None, "last_used_age_s": None,
        })

# ---------------------------------------------------------------------------
# LiteLLM — its registered model catalog (what's configured — local ollama/
# vllm routes and cloud providers alike) plus recency of the last successful
# request against each target model, i.e. "what's there and what's actually
# in use" as seen by the proxy itself, independent of whether OpenWebUI
# happens to talk to Ollama directly for that same model (see the big
# comment on the OpenWebUI query above — that signal and this one can
# legitimately disagree, since they're watching different paths into the
# same backend).
# ---------------------------------------------------------------------------

try:
    litellm_routes = json.loads(os.environ.get("LITELLM_MODEL_INFO_RAW", "{}")).get("data", [])
except Exception:
    litellm_routes = []
try:
    litellm_spend = json.loads(os.environ.get("LITELLM_SPEND_RAW", "{}")).get("data", [])
except Exception:
    litellm_spend = []

# target model string (litellm_params.model, e.g. "ollama_chat/llama3.1:8b")
# -> epoch seconds of its most recent successful request.
litellm_last_used = {}
for entry in litellm_spend:
    target, start = entry.get("model"), entry.get("startTime")
    if not target or not start:
        continue
    try:
        ts = __import__("datetime").datetime.fromisoformat(start.replace("Z", "+00:00")).timestamp()
    except Exception:
        continue
    if target not in litellm_last_used or ts > litellm_last_used[target]:
        litellm_last_used[target] = ts

for r in litellm_routes:
    target = (r.get("litellm_params") or {}).get("model", "")
    last_ts = litellm_last_used.get(target)
    models.append({
        "name": r.get("model_name", "?"), "backend": "litellm", "host": HOSTNAME, "loaded": True,
        "cpu_pct": None, "gpu_pct": None,
        "size_gb": None, "vram_gb": None, "params": None, "expires_at": None,
        "user": "", "user_active_age_s": None,
        "target": target, "last_used_age_s": round(time.time() - last_ts) if last_ts else None,
    })

# ---------------------------------------------------------------------------
# Overall system load — /proc/loadavg, a short live CPU-busy sample, and swap
# activity (a machine can look fine on CPU% alone while it's actually
# thrashing — swapping is what tells you that's happening, not swap *usage*,
# which can sit high from long-idle pages with no active pressure at all).
# ---------------------------------------------------------------------------

SWAP_THRASH_THRESHOLD_MB_S = float(os.environ.get("SWAP_THRASH_THRESHOLD_MB_S", "1.0"))


def sample_deltas():
    """One combined before/after sample for both CPU-busy% and swap I/O rate,
    so this only costs a single sleep instead of two."""
    def read():
        with open("/proc/stat") as f:
            cpu_vals = [int(x) for x in f.readline().split()[1:]]
        vmstat = {}
        try:
            with open("/proc/vmstat") as f:
                for line in f:
                    key, _, val = line.partition(" ")
                    if key in ("pswpin", "pswpout"):
                        vmstat[key] = int(val)
        except Exception:
            pass
        return cpu_vals, vmstat

    try:
        cpu1, vm1 = read()
        interval = 0.2
        time.sleep(interval)
        cpu2, vm2 = read()
    except Exception:
        return None, None

    total1, total2 = sum(cpu1), sum(cpu2)
    idle1, idle2 = cpu1[3] + cpu1[4], cpu2[3] + cpu2[4]  # idle + iowait
    dtotal, didle = total2 - total1, idle2 - idle1
    cpu_busy = round(100 * (1 - didle / dtotal), 1) if dtotal > 0 else None

    swap_io_mb_s = None
    if "pswpin" in vm1 and "pswpout" in vm1 and "pswpin" in vm2:
        pages = (vm2["pswpin"] - vm1["pswpin"]) + (vm2["pswpout"] - vm1["pswpout"])
        swap_io_mb_s = round(pages * 4096 / 1048576 / interval, 2)  # 4096-byte pages -> MB/s

    return cpu_busy, swap_io_mb_s


def swap_usage():
    total_kb = free_kb = None
    try:
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith("SwapTotal:"):
                    total_kb = int(line.split()[1])
                elif line.startswith("SwapFree:"):
                    free_kb = int(line.split()[1])
    except Exception:
        return None
    if not total_kb:
        return {"used_gb": 0.0, "total_gb": 0.0, "pct": 0.0}
    used_kb = total_kb - (free_kb or 0)
    return {
        "used_gb": round(used_kb / 1048576, 2),
        "total_gb": round(total_kb / 1048576, 2),
        "pct": round(100 * used_kb / total_kb, 1),
    }


loadavg = None
try:
    loadavg = list(os.getloadavg())
except Exception:
    pass
cpu_count = os.cpu_count() or 1
cpu_busy, swap_io_mb_s = sample_deltas()
swap = swap_usage()
thrashing = swap_io_mb_s is not None and swap_io_mb_s >= SWAP_THRASH_THRESHOLD_MB_S

report = {
    "generated_at": __import__("datetime").datetime.now(__import__("datetime").timezone.utc)
        .strftime("%Y-%m-%dT%H:%M:%SZ"),
    "system": {
        "cpu_count": cpu_count,
        "cpu_busy_pct": cpu_busy,
        "loadavg_1_5_15": loadavg,
        "swap": swap,
        "swap_io_mb_s": swap_io_mb_s,
        "thrashing": thrashing,
    },
    "components": components,
    "models": models,
    "gpu_detected": has_gpu,
}

if OUTPUT_FORMAT == "json":
    print(json.dumps(report, indent=2))
    sys.exit(0)

# ---------------------------------------------------------------------------
# Human-readable report
# ---------------------------------------------------------------------------

def fmt_pct(v):
    return "-" if v is None else f"{v:.1f}%"


print()
print("AI Stack Load")
print("════════════════════════════════════════")
la = report["system"]["loadavg_1_5_15"]
la_str = "  ".join(f"{x:.2f}" for x in la) if la else "n/a"
print(f"  {'cpu count':<14} {cpu_count}")
print(f"  {'cpu busy':<14} {fmt_pct(cpu_busy)}")
print(f"  {'load avg 1/5/15m':<14} {la_str}")
if swap is None:
    print(f"  {'swap':<14} n/a (no /proc/meminfo)")
elif swap["total_gb"] == 0:
    print(f"  {'swap':<14} none configured")
else:
    io_str = f"{swap_io_mb_s:.2f} MB/s" if swap_io_mb_s is not None else "n/a"
    flag = "  [THRASHING]" if thrashing else ""
    print(f"  {'swap':<14} {swap['used_gb']:.2f}/{swap['total_gb']:.2f}GB "
          f"({swap['pct']:.1f}%)  io {io_str}{flag}")
if not has_gpu:
    print(f"  {'gpu':<14} not detected (no nvidia-smi, or no compute processes running)")
print()

print("  By component")
name_w = max([len("SERVICE")] + [len(c["name"]) for c in components] + [7])
models_by_backend = {}
for m in models:
    models_by_backend.setdefault(m["backend"], []).append(m)

if models:
    mname_w = max(len(f"{m['host']}/{m['name']}") for m in models)
else:
    mname_w = 0

for cat in CATEGORY_ORDER:
    rows = [c for c in components if c["category"] == cat]
    if not rows:
        continue
    print(f"    {cat}")
    for c in sorted(rows, key=lambda r: r["name"]):
        mem = fmt_pct(c["mem_pct"])
        print(f"      {c['name']:<{name_w}} {c['mode']:<10} cpu {fmt_pct(c['cpu_pct']):>7}  mem {mem:>7}")
        def _model_sort_key(r):
            if r["backend"] == "litellm":
                age = r["last_used_age_s"]
                return (0, age) if age is not None else (1, 0)
            return (0, -(r["cpu_pct"] if r["cpu_pct"] is not None else -1))

        for m in sorted(models_by_backend.get(c["name"], []), key=_model_sort_key):
            label = f"{m['host']}/{m['name']}"
            if m["backend"] == "litellm":
                age = humanize_age(m["last_used_age_s"])
                last_used = f"last used: {age}" if m["last_used_age_s"] is not None else "last used: -"
                print(f"        {label:<{mname_w}} -> {m['target']:<40} {last_used}")
            else:
                age = humanize_age(m["user_active_age_s"])
                user_str = f"{m['user']} ({age})" if m["user"] else ""
                tail = "" if m.get("loaded", True) else "  [not loaded]"
                params = m.get("params") or "-"
                size = f"{m['size_gb']}GB" if m.get("size_gb") is not None else "-"
                print(f"        {label:<{mname_w}} {params:>6}  {size:>9}  "
                      f"cpu {fmt_pct(m['cpu_pct']):>7}  gpu {fmt_pct(m['gpu_pct']):>7}  "
                      f"user: {user_str}{tail}")
    print()

if not components:
    print("    (no running components found)\n")
PYEOF
