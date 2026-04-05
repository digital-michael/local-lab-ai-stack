#!/usr/bin/env bash
# heartbeat.sh — AI Stack worker node heartbeat sender
#
# Reads state from ~/.config/ai-stack/ (written by node.sh join / bootstrap.sh)
# and POSTs a heartbeat every invocation.
#
# Designed to be called by a systemd timer every 30s.
# Run once manually to verify:
#   bash scripts/heartbeat.sh [--controller <url>] [--node-id <id>]

set -euo pipefail

STATE_DIR="${AI_STACK_NODE_DIR:-$HOME/.config/ai-stack}"
LOG_TAG="ai-stack-heartbeat"

# ---------------------------------------------------------------------------
# Load state
# ---------------------------------------------------------------------------

CONTROLLER_URL="${CONTROLLER_URL:-}"
NODE_ID="${NODE_ID:-}"
API_KEY_STATE="${API_KEY_STATE:-}"

[[ -f "$STATE_DIR/controller_url" ]] && CONTROLLER_URL="${CONTROLLER_URL:-$(cat "$STATE_DIR/controller_url" 2>/dev/null || echo '')}"
[[ -f "$STATE_DIR/node_id"        ]] && NODE_ID="${NODE_ID:-$(cat "$STATE_DIR/node_id" 2>/dev/null || echo '')}"
[[ -f "$STATE_DIR/api_key"        ]] && API_KEY_STATE="${API_KEY_STATE:-$(cat "$STATE_DIR/api_key" 2>/dev/null || echo '')}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --controller) CONTROLLER_URL="$2"; shift 2 ;;
        --node-id)    NODE_ID="$2";        shift 2 ;;
        *)            shift ;;
    esac
done

if [[ -z "$CONTROLLER_URL" || -z "$NODE_ID" ]]; then
    echo "[$LOG_TAG] ERROR: CONTROLLER_URL and NODE_ID must be set (run node.sh join first)" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Resolve alias (stable node identity matching configs/nodes/<alias>.json)
# ---------------------------------------------------------------------------

ALIAS="${ALIAS:-}"
if [[ -f "$STATE_DIR/alias" ]]; then
    ALIAS="${ALIAS:-$(cat "$STATE_DIR/alias" 2>/dev/null || echo '')}"
fi
# One-time backfill: derive alias from configs/nodes/ by matching node_id.
# Written to state once so subsequent heartbeats skip the file scan.
if [[ -z "$ALIAS" ]]; then
    _hb_script_dir="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
    _nodes_dir_hb="$_hb_script_dir/../configs/nodes"
    if [[ -d "$_nodes_dir_hb" ]]; then
        ALIAS=$(python3 - "$_nodes_dir_hb" "$NODE_ID" <<'PYEOF' 2>/dev/null
import glob, json, sys
nodes_dir, nid = sys.argv[1], sys.argv[2]
for f in glob.glob(nodes_dir + '/*.json'):
    try:
        d = json.load(open(f))
        if d.get('node_id') == nid:
            print(d.get('alias', ''))
            break
    except Exception:
        pass
PYEOF
        )
        [[ -n "$ALIAS" ]] && printf '%s' "$ALIAS" > "$STATE_DIR/alias"
    fi
fi

# ---------------------------------------------------------------------------
# Collect metrics
# ---------------------------------------------------------------------------

_int()  { printf '%d'   "${1:-0}" 2>/dev/null || echo 0; }
_float(){ printf '%.1f' "${1:-0}" 2>/dev/null || echo 0; }

# CPU usage (1-second sample)
cpu_percent=0
if command -v top &>/dev/null; then
    cpu_idle=$(top -bn1 2>/dev/null | grep -E "^%?Cpu" | head -1 \
               | awk '{for(i=1;i<=NF;i++) if($i~/id,?/) print $(i-1)}' || echo 100)
    cpu_percent=$(awk "BEGIN{printf \"%.1f\", 100 - ${cpu_idle:-100}}")
fi

# Memory
mem_used_gb=0; mem_total_gb=0
if [[ -f /proc/meminfo ]]; then
    mem_total_kb=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    mem_avail_kb=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    mem_total_gb=$(awk "BEGIN{printf \"%.2f\", ${mem_total_kb:-0}/1048576}")
    mem_used_kb=$(( ${mem_total_kb:-0} - ${mem_avail_kb:-0} ))
    mem_used_gb=$(awk "BEGIN{printf \"%.2f\", ${mem_used_kb:-0}/1048576}")
fi

# GPU VRAM (nvidia-smi only; 0 if absent)
gpu_vram_used_mb=0
if command -v nvidia-smi &>/dev/null; then
    gpu_vram_used_mb=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits \
                       2>/dev/null | head -1 | tr -d ' ' || echo 0)
fi

# Models loaded (check Ollama API if running; empty list otherwise)
models_loaded="[]"
if command -v curl &>/dev/null; then
    ollama_resp=$(curl -s --connect-timeout 2 http://localhost:11434/api/tags 2>/dev/null || echo "")
    if [[ -n "$ollama_resp" ]]; then
        models_loaded=$(echo "$ollama_resp" | python3 -c "
import json,sys
try:
    d = json.load(sys.stdin)
    names = [m['name'] for m in d.get('models', [])]
    print(json.dumps(names))
except:
    print('[]')
" 2>/dev/null || echo "[]")
    fi
fi

# ---------------------------------------------------------------------------
# Optional message — run $STATE_DIR/heartbeat-message.sh if present
# ---------------------------------------------------------------------------

hb_message=""
_msg_script="$STATE_DIR/heartbeat-message.sh"
if [[ -f "$_msg_script" && -x "$_msg_script" ]]; then
    hb_message=$("$_msg_script" 2>/dev/null || true)
fi

# ---------------------------------------------------------------------------
# Build payload and POST
# ---------------------------------------------------------------------------

_hb_msg_file=$(mktemp)
printf '%s' "$hb_message" | head -c 512 > "$_hb_msg_file"

payload=$(python3 - "$_hb_msg_file" <<PYEOF 2>/dev/null
import json, sys
message = open(sys.argv[1]).read() if len(sys.argv) > 1 else ""
print(json.dumps({
    'node_id':  '${NODE_ID}',
    'alias':    '${ALIAS:-}',
    'timestamp': __import__('datetime').datetime.utcnow().isoformat() + 'Z',
    'metrics': {
        'cpu_percent':       float('${cpu_percent:-0}'),
        'mem_used_gb':       float('${mem_used_gb:-0}'),
        'mem_total_gb':      float('${mem_total_gb:-0}'),
        'gpu_vram_used_mb':  int('${gpu_vram_used_mb:-0}'),
        'models_loaded':     ${models_loaded},
        'requests_last_60s': 0,
    },
    'message':  message,
    'messages': [],
}))
PYEOF
)
rm -f "$_hb_msg_file"

auth_header=""
[[ -n "${API_KEY_STATE:-}" ]] && auth_header="Authorization: Bearer $API_KEY_STATE"

curl_args=(-s -f -X POST \
    -H "Content-Type: application/json" \
    -d "$payload" \
    --connect-timeout 10 \
    --max-time 15)
[[ -n "$auth_header" ]] && curl_args+=(-H "$auth_header")

response=$(curl "${curl_args[@]}" "$CONTROLLER_URL/admin/v1/nodes/$NODE_ID/heartbeat" 2>&1) || {
    logger -t "$LOG_TAG" "WARNING: heartbeat POST failed — $response" 2>/dev/null || true
    echo "[$LOG_TAG] WARNING: heartbeat POST failed" >&2
    exit 0  # non-fatal: timer will retry in 30s
}

# Check for pending suggestions
pending=$(echo "$response" | python3 -c "
import json,sys
try: print(json.load(sys.stdin).get('pending_suggestions', 0))
except: print(0)
" 2>/dev/null || echo 0)

if [[ "$pending" -gt 0 ]]; then
    logger -t "$LOG_TAG" "INFO: $pending pending suggestion(s) — run: node.sh suggestions list" 2>/dev/null || true
    echo "[$LOG_TAG] $pending pending suggestion(s) available (run: node.sh suggestions list)"
fi

# Check for a pending rename — applied atomically by the server on this heartbeat
rename_to=$(echo "$response" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('rename_to') or '')
except: print('')
" 2>/dev/null || echo "")

if [[ -n "$rename_to" ]]; then
    printf '%s' "$rename_to" > "$STATE_DIR/node_id"
    NODE_ID="$rename_to"
    logger -t "$LOG_TAG" "INFO: node_id renamed to $rename_to" 2>/dev/null || true
    echo "[$LOG_TAG] INFO: node_id renamed to $rename_to"
fi
