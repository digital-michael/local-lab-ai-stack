#!/usr/bin/env bash
set -euo pipefail

# node.sh — Node lifecycle management for AI Stack workers
#
# Usage: node.sh <command> [options]
#
# Commands:
#   deploy                        Deploy the knowledge-index container on this worker
#   join    --controller <url> --token <token> [--node-id <id>] [--address <url>]
#                                 Register this worker with the controller
#   unjoin  [--controller <url>] [--node-id <id>]
#                                 Remove this worker from the controller
#   pause                         (stub) Pause heartbeats without unjoining
#   list    [--controller <url>] [--api-key <key>] [-v] [-m]  List all registered nodes and their status
#   status  [--node-id <id>]      Show this node's status from the controller
#   suggestions list   [--node-id <id>]
#   suggestions show   <suggestion-id> [--node-id <id>]
#   suggestions apply  <suggestion-id> [--node-id <id>]
#                                 Manage controller suggestions for this node
#   undeploy                      Remove the knowledge-index container
#   help                          Show this message

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AI_STACK_NODE_DIR:-$HOME/.config/ai-stack}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: node.sh <command> [options]

Commands:
  deploy                         Deploy knowledge-index on this worker node
  join    --controller <url> \
          --token <token>        Register with the controller (token from generate-join-token)
          [--node-id <id>]       Node ID (default: hostname -s)
          [--address <url>]      This node's KI base URL (default: auto-detect)
  unjoin  [--controller <url>]   Remove this node from controller routing
          [--node-id <id>]
  pause                          Stub: pause heartbeats temporarily
  list    [--controller <url>] \
          [--api-key <key>] [-v] [-m]  List nodes (-v: show messages, -m: names+messages only)
  status  [--node-id <id>]       Show node status from controller
  suggestions list               List pending suggestions
  suggestions show <id>          Show suggestion detail
  suggestions apply <id>         Mark suggestion consumed
  undeploy                       Stop and remove knowledge-index container
  help                           This message

State file: ~/.config/ai-stack/{controller_url,node_id,api_key}
EOF
}

_load_state() {
    CONTROLLER_URL="${CONTROLLER_URL:-}"
    NODE_ID="${NODE_ID:-}"
    API_KEY_STATE="${API_KEY_STATE:-}"

    if [[ -f "$STATE_DIR/controller_url" ]]; then
        CONTROLLER_URL="${CONTROLLER_URL:-$(cat "$STATE_DIR/controller_url")}"
    fi
    if [[ -f "$STATE_DIR/node_id" ]]; then
        NODE_ID="${NODE_ID:-$(cat "$STATE_DIR/node_id")}"
    fi
    if [[ -f "$STATE_DIR/api_key" ]]; then
        API_KEY_STATE="${API_KEY_STATE:-$(cat "$STATE_DIR/api_key")}"
    fi
}

_save_state() {
    mkdir -p "$STATE_DIR"
    [[ -n "${CONTROLLER_URL:-}" ]] && printf '%s' "$CONTROLLER_URL" > "$STATE_DIR/controller_url"
    [[ -n "${NODE_ID:-}"        ]] && printf '%s' "$NODE_ID"        > "$STATE_DIR/node_id"
    [[ -n "${API_KEY_STATE:-}"  ]] && printf '%s' "$API_KEY_STATE"  > "$STATE_DIR/api_key"
}

_require_controller() {
    if [[ -z "${CONTROLLER_URL:-}" ]]; then
        echo "ERROR: --controller required (or set CONTROLLER_URL env var)" >&2
        exit 1
    fi
}

_require_node_id() {
    if [[ -z "${NODE_ID:-}" ]]; then
        NODE_ID="$(hostname -s)"
    fi
}

_api_key_header() {
    if [[ -n "${API_KEY_STATE:-}" ]]; then
        echo "Authorization: Bearer $API_KEY_STATE"
    else
        echo ""
    fi
}

_curl_admin() {
    # _curl_admin <method> <path> [body]
    local method="$1"
    local path="$2"
    local body="${3:-}"
    local hdr
    hdr=$(_api_key_header)

    local args=(-s -w "\n%{http_code}" -X "$method")
    [[ -n "$hdr" ]] && args+=(-H "$hdr")
    [[ -n "$body" ]] && args+=(-H "Content-Type: application/json" -d "$body")

    curl "${args[@]}" "${CONTROLLER_URL}${path}"
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_deploy() {
    echo "Deploying knowledge-index on this worker..."
    if ! command -v podman &>/dev/null; then
        echo "ERROR: podman not found" >&2; exit 1
    fi
    # Source NODE_PROFILE so the container knows it's a worker
    local image
    image=$(podman images --format '{{.Repository}}:{{.Tag}}' \
            | grep "knowledge-index" | head -1 || true)
    if [[ -z "$image" ]]; then
        echo "ERROR: No knowledge-index image found. Build it first:" >&2
        echo "  podman build -t knowledge-index services/knowledge-index/" >&2
        exit 1
    fi
    echo "  Image: $image"
    podman run -d --name knowledge-index \
        -p 8100:8100 \
        -e NODE_PROFILE=knowledge-worker \
        -e NODE_NAME="$(hostname -s)" \
        "$image"
    echo "knowledge-index deployed."
}

cmd_join() {
    local token=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller) CONTROLLER_URL="$2"; shift 2 ;;
            --token)      token="$2";          shift 2 ;;
            --node-id)    NODE_ID="$2";        shift 2 ;;
            --address)    local address="$2";  shift 2 ;;
            *)            echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    _require_controller
    _require_node_id
    [[ -z "$token" ]] && { echo "ERROR: --token required" >&2; exit 1; }

    # Auto-detect address if not provided
    if [[ -z "${address:-}" ]]; then
        local ip
        if [[ "$(uname -s)" == "Darwin" ]]; then
            # macOS: hostname -I not available; use ipconfig getifaddr or route
            ip=$(ipconfig getifaddr en0 2>/dev/null \
                 || ipconfig getifaddr en1 2>/dev/null \
                 || route -n get default 2>/dev/null | awk '/interface:/{print $2}' \
                 || echo "127.0.0.1")
        else
            ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
        fi
        address="http://${ip}:8100"
    fi

    local body
    body=$(printf '{"token":"%s","address":"%s"}' "$token" "$address")

    local response http_code body_part
    response=$(_curl_admin POST "/admin/v1/nodes/${NODE_ID}/join" "$body") || {
        echo "ERROR: Failed to reach controller at ${CONTROLLER_URL}" >&2; exit 1
    }
    http_code=$(echo "$response" | tail -1)
    body_part=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: Join failed (HTTP $http_code):" >&2
        echo "$body_part" >&2
        exit 1
    fi

    echo "Joined controller successfully:"
    echo "$body_part" | python3 -m json.tool 2>/dev/null || echo "$body_part"
    echo ""

    # Extract and persist the per-node API key issued by the controller
    local node_api_key
    node_api_key=$(echo "$body_part" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('node_api_key',''))" \
        2>/dev/null || true)
    [[ -n "$node_api_key" ]] && API_KEY_STATE="$node_api_key"

    _save_state
    echo "State saved to $STATE_DIR"
}

cmd_unjoin() {
    _load_state
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller) CONTROLLER_URL="$2"; shift 2 ;;
            --node-id)    NODE_ID="$2";        shift 2 ;;
            *)            echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    _require_controller
    _require_node_id

    local response http_code body_part
    response=$(_curl_admin DELETE "/admin/v1/nodes/${NODE_ID}") || {
        echo "ERROR: Failed to reach controller at ${CONTROLLER_URL}" >&2; exit 1
    }
    http_code=$(echo "$response" | tail -1)
    body_part=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: Unjoin failed (HTTP $http_code):" >&2
        echo "$body_part" >&2
        exit 1
    fi

    echo "Node unjoined:"
    echo "$body_part" | python3 -m json.tool 2>/dev/null || echo "$body_part"
}

cmd_pause() {
    echo "(stub) pause — heartbeat suspension not yet implemented" >&2
    echo "To stop this node from routing: node.sh unjoin"
}

cmd_list() {
    _load_state
    local verbose=0
    local msg_only=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller) CONTROLLER_URL="$2"; shift 2 ;;
            --api-key)    API_KEY_STATE="$2";  shift 2 ;;
            -v)           verbose=1;           shift   ;;
            -m)           msg_only=1;          shift   ;;
            *)            echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    _require_controller

    local response http_code body_part
    response=$(_curl_admin GET "/admin/v1/nodes") || {
        echo "ERROR: Failed to reach controller at ${CONTROLLER_URL}" >&2; exit 1
    }
    http_code=$(echo "$response" | tail -1)
    body_part=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: List failed (HTTP $http_code):" >&2
        echo "$body_part" >&2
        exit 1
    fi

    local nodes_dir="$SCRIPT_DIR/../configs/nodes"
    local _tmp; _tmp=$(mktemp)
    echo "$body_part" > "$_tmp"

    python3 - "$_tmp" "$nodes_dir" "$verbose" "$msg_only" <<'PYEOF'
import glob, json, sys

data      = json.load(open(sys.argv[1]))
db_nodes  = data.get('nodes', [])
nodes_dir = sys.argv[2]
verbose   = len(sys.argv) > 3 and sys.argv[3] == '1'
msg_only  = len(sys.argv) > 4 and sys.argv[4] == '1'

# ------------------------------------------------------------------
# Load node-file data: node_id -> {models, display_name, capabilities}
# ------------------------------------------------------------------
nf_map = {}
ctrl_rows = []
for path in sorted(glob.glob(nodes_dir + "/*.json")):
    try:
        nf = json.load(open(path))
    except Exception:
        continue
    nid = nf.get("node_id")
    if not nid:
        continue
    nf_map[nid] = nf
    if nf.get("profile") == "controller":
        caps = nf.get("capabilities", [])
        ctrl_rows.append({
            "node_id":      nid,
            "display_name": nf.get("name", nid),
            "profile":      "controller",
            "status":       "local",
            "last_seen":    "",
            "capabilities": caps,
            "models":       nf.get("models", []),
        })

# Merge DB rows with node-file models
all_rows = []
for n in db_nodes:
    nid  = n.get("node_id", "")
    nf   = nf_map.get(nid, {})
    caps = n.get("capabilities", [])
    if isinstance(caps, dict):
        caps = list(caps.keys())
    all_rows.append({
        "node_id":      nid,
        "display_name": n.get("display_name", ""),
        "profile":      n.get("profile", ""),
        "status":       n.get("status", ""),
        "last_seen":    (n.get("last_seen") or "")[:19],
        "capabilities": caps,
        "models":       nf.get("models", []),
        "last_message": n.get("last_message", ""),
    })

# Controller row(s) prepended (not in DB)
rows = ctrl_rows + all_rows

if not rows:
    print("No nodes found.")
    sys.exit(0)

if msg_only:
    for r in rows:
        name = r.get("display_name") or r.get("node_id", "")
        msg  = r.get("last_message", "")
        print(f"{name}")
        if msg:
            print(f"   Message: {msg}")
        print()
    sys.exit(0)

def fmt_list(lst):
    return ",".join(lst) if lst else "-"

COLS = [
    ("NODE ID",       "node_id",      16),
    ("DISPLAY NAME",  "display_name", 16),
    ("PROFILE",       "profile",      16),
    ("STATUS",        "status",        9),
    ("CAPABILITIES",  "capabilities", 28),
    ("MODELS",        "models",       28),
]
SEP = "  "

def wrap_cell(text, width):
    """Split comma-delimited text into lines of at most width chars.
    Breaks preferentially at comma boundaries; falls back to hard breaks
    only when a single token exceeds width."""
    if len(text) <= width:
        return [text] if text else [""]
    tokens = text.split(",")
    lines = []
    current = ""
    for tok in tokens:
        candidate = current + ("," if current else "") + tok
        if len(candidate) <= width:
            current = candidate
        else:
            if current:
                lines.append(current + ",")
            # Token itself may exceed width — hard-break it
            while len(tok) > width:
                lines.append(tok[:width])
                tok = tok[width:]
            current = tok
    if current:
        lines.append(current)
    return lines or [""]

hdr = SEP.join(f"{h:<{w}}" for h, _, w in COLS)
sep = SEP.join("-" * w     for _, _, w in COLS)
print(hdr)
print(sep)
for r in rows:
    # Build wrapped lines per column
    col_lines = []
    for _, key, w in COLS:
        v = r.get(key, "")
        if isinstance(v, list):
            v = fmt_list(v)
        col_lines.append(wrap_cell(str(v), w))
    row_height = max(len(lines) for lines in col_lines)
    for line_idx in range(row_height):
        parts = []
        for i, (_, _, w) in enumerate(COLS):
            chunk = col_lines[i][line_idx] if line_idx < len(col_lines[i]) else ""
            parts.append(f"{chunk:<{w}}")
        print(SEP.join(parts))
    msg = r.get("last_message", "")
    if verbose and msg:
        print(f"   Message: {msg}")
    print()
print(f"Total: {len(rows)} node(s)  ({len(ctrl_rows)} controller, {len(all_rows)} registered)")
PYEOF
    rm -f "$_tmp"
}

cmd_status() {
    _load_state
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node-id) NODE_ID="$2"; shift 2 ;;
            *)         echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    _require_controller
    _require_node_id

    local response http_code body_part
    response=$(_curl_admin GET "/admin/v1/nodes/${NODE_ID}") || {
        echo "ERROR: Failed to reach controller at ${CONTROLLER_URL}" >&2; exit 1
    }
    http_code=$(echo "$response" | tail -1)
    body_part=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: Status check failed (HTTP $http_code):" >&2
        echo "$body_part" >&2
        exit 1
    fi

    echo "$body_part" | python3 -m json.tool 2>/dev/null || echo "$body_part"
}

cmd_suggestions() {
    _load_state
    local subcmd="${1:-list}"
    shift || true
    local suggestion_id=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node-id) NODE_ID="$2"; shift 2 ;;
            *)         suggestion_id="$1"; shift ;;
        esac
    done

    _require_controller
    _require_node_id

    case "$subcmd" in
        list)
            local response http_code body_part
            response=$(_curl_admin GET "/admin/v1/nodes/${NODE_ID}/suggestions") || {
                echo "ERROR: Cannot reach $CONTROLLER_URL" >&2; exit 1
            }
            http_code=$(echo "$response" | tail -1)
            body_part=$(echo "$response" | sed '$d')
            [[ "$http_code" != "200" ]] && { echo "ERROR HTTP $http_code: $body_part" >&2; exit 1; }
            echo "$body_part" | python3 -m json.tool 2>/dev/null || echo "$body_part"
            ;;
        show)
            [[ -z "$suggestion_id" ]] && { echo "Usage: node.sh suggestions show <id>" >&2; exit 1; }
            local response http_code body_part
            response=$(_curl_admin GET "/admin/v1/nodes/${NODE_ID}/suggestions") || {
                echo "ERROR: Cannot reach $CONTROLLER_URL" >&2; exit 1
            }
            http_code=$(echo "$response" | tail -1)
            body_part=$(echo "$response" | sed '$d')
            [[ "$http_code" != "200" ]] && { echo "ERROR HTTP $http_code: $body_part" >&2; exit 1; }
            echo "$body_part" | python3 -c "
import json, sys
data = json.load(sys.stdin)
sid = '$suggestion_id'
for s in data.get('suggestions', []):
    if s['id'] == sid:
        print(json.dumps(s, indent=2))
        sys.exit(0)
print('Suggestion not found: ' + sid, file=sys.stderr)
sys.exit(1)
"
            ;;
        apply)
            [[ -z "$suggestion_id" ]] && { echo "Usage: node.sh suggestions apply <id>" >&2; exit 1; }
            local response http_code body_part
            response=$(_curl_admin POST "/admin/v1/nodes/${NODE_ID}/suggestions/${suggestion_id}/consume") || {
                echo "ERROR: Cannot reach $CONTROLLER_URL" >&2; exit 1
            }
            http_code=$(echo "$response" | tail -1)
            body_part=$(echo "$response" | sed '$d')
            [[ "$http_code" != "200" ]] && { echo "ERROR HTTP $http_code: $body_part" >&2; exit 1; }
            echo "Applied:"
            echo "$body_part" | python3 -m json.tool 2>/dev/null || echo "$body_part"
            ;;
        *)
            echo "Unknown suggestions subcommand: $subcmd" >&2
            echo "  node.sh suggestions list|show <id>|apply <id>" >&2
            exit 1
            ;;
    esac
}

cmd_undeploy() {
    echo "Stopping and removing knowledge-index container..."
    podman stop knowledge-index 2>/dev/null || true
    podman rm   knowledge-index 2>/dev/null || true
    echo "Removed."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

_load_state

case "${1:-help}" in
    deploy)      cmd_deploy ;;
    join)        shift; cmd_join "$@" ;;
    unjoin)      shift; cmd_unjoin "$@" ;;
    pause)       cmd_pause ;;
    list)        shift; cmd_list "$@" ;;
    status)      shift; cmd_status "$@" ;;
    suggestions) shift; cmd_suggestions "$@" ;;
    undeploy)    cmd_undeploy ;;
    help|--help|-h) usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
