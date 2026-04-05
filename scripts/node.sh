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
#   purge   [--node-id <id>] [--older-than <minutes>] [--dry-run] [--force]
#                                 Hard-delete offline nodes (or a specific node) from the registry
#   rename  --node-id <id> [--new-id <id>] [--display-name <text>]
#                                 Rename a node's id and/or display name (admin)
#   pause                         (stub) Pause heartbeats without unjoining
#   list    [--controller <url>] [--api-key <key>] [-v] [-m]  List all registered nodes and their status
#   status  [--node-id <id>]      Show this node's status from the controller
#   suggestions list   [--node-id <id>]
#   suggestions show   <suggestion-id> [--node-id <id>]
#   suggestions apply  <suggestion-id> [--node-id <id>]
#                                 Manage controller suggestions for this node
#   harden-worker --node-id <id> [--controller-ip <ip>]
#                                 Print OS-appropriate firewall rules to restrict Ollama :11434
#                                 on an inference-worker to controller access only
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
          [--alias <alias>]      Stable alias matching configs/nodes/<alias>.json (optional)
          [--address <url>]      This node's KI base URL (default: auto-detect)
  unjoin  [--controller <url>]   Remove this node from controller routing
          [--node-id <id>]
  purge   [--node-id <id>]       Hard-delete a specific node regardless of status (prompts unless --force)
          [--older-than <min>]   Bulk: purge offline nodes last seen > N minutes ago (default: all offline)
          [--dry-run]            Show candidates without deleting
          [--force]              Skip confirmation prompt
  rename  --node-id <id>          Rename a node (at least one of --new-id or --display-name required)
          [--new-id <new>]        New node id (applied on next heartbeat via heartbeat.sh auto-update)
          [--display-name <text>] New display name (applied immediately)
  pause                          Stub: pause heartbeats temporarily
  list    [--controller <url>] \
          [--api-key <key>] [-v] [-m]  List nodes (-v: show messages, -m: names+messages only)
  status  [--node-id <id>]       Show node status from controller
  suggestions list               List pending suggestions
  suggestions show <id>          Show suggestion detail
  suggestions apply <id>         Mark suggestion consumed
  harden-worker --alias <alias> \
          [--controller-ip <ip>] Print OS-appropriate firewall rules to restrict Ollama :11434
                                 on the target inference-worker to controller access only
          [--node-id <id>]       Backward compat: locate node by node_id instead of alias
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
    local node_alias=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller) CONTROLLER_URL="$2"; shift 2 ;;
            --token)      token="$2";          shift 2 ;;
            --node-id)    NODE_ID="$2";        shift 2 ;;
            --alias)      node_alias="$2";     shift 2 ;;
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
    body=$(python3 -c "
import json, sys
obj = {'token': sys.argv[1], 'address': sys.argv[2]}
if sys.argv[3]:
    obj['alias'] = sys.argv[3]
print(json.dumps(obj))
" "$token" "$address" "${node_alias:-}")

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
    [[ -n "${node_alias:-}" ]] && printf '%s' "$node_alias" > "$STATE_DIR/alias"
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

cmd_purge() {
    _load_state
    local node_id_arg="" older_than="" dry_run=0 force=0

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller)   CONTROLLER_URL="$2"; shift 2 ;;
            --api-key)      API_KEY_STATE="$2";  shift 2 ;;
            --node-id)      node_id_arg="$2";    shift 2 ;;
            --older-than)   older_than="$2";     shift 2 ;;
            --dry-run)      dry_run=1;           shift   ;;
            --force)        force=1;             shift   ;;
            *)              echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    _require_controller

    # Fetch current node list
    local response http_code body_part
    response=$(_curl_admin GET "/admin/v1/nodes") || {
        echo "ERROR: Failed to reach controller at ${CONTROLLER_URL}" >&2; exit 1
    }
    http_code=$(echo "$response" | tail -1)
    body_part=$(echo "$response" | sed '$d')
    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: Could not fetch node list (HTTP $http_code)" >&2; exit 1
    fi

    local _tmp; _tmp=$(mktemp)
    echo "$body_part" > "$_tmp"
    local _node_id_arg="$node_id_arg"
    local _older_than="$older_than"

    # Build candidate list — tab-separated: node_id, display_name, status, last_seen
    local candidates
    candidates=$(python3 - "$_tmp" "$_node_id_arg" "$_older_than" <<'PYEOF' 2>&1
import json, sys, datetime

now  = datetime.datetime.now(datetime.timezone.utc)
data = json.load(open(sys.argv[1]))
nodes        = data.get('nodes', [])
node_id_arg  = sys.argv[2]
older_than   = sys.argv[3]  # minutes, or ""

def parse_ts(s):
    for fmt in ('%Y-%m-%d %H:%M:%S.%f', '%Y-%m-%d %H:%M:%S',
                '%Y-%m-%dT%H:%M:%S.%f', '%Y-%m-%dT%H:%M:%S'):
        try:
            return datetime.datetime.strptime(s[:26], fmt).replace(
                       tzinfo=datetime.timezone.utc)
        except ValueError:
            pass
    return None

results = []
if node_id_arg:
    match = next((n for n in nodes if n['node_id'] == node_id_arg), None)
    if not match:
        print('ERROR: node not found: ' + node_id_arg, file=sys.stderr)
        sys.exit(1)
    results.append(match)
else:
    for n in nodes:
        if n.get('status') != 'offline':
            continue
        if older_than:
            ls = n.get('last_seen', '')
            if not ls:
                continue
            dt = parse_ts(ls)
            if dt is None:
                continue
            if (now - dt).total_seconds() / 60 < float(older_than):
                continue
        results.append(n)

for n in results:
    ls = (n.get('last_seen') or '')[:19]
    print(n['node_id'] + '\t' + n.get('display_name', '') + '\t' +
          n.get('status', '') + '\t' + ls)
PYEOF
    )
    local py_exit=$?
    rm -f "$_tmp"
    if [[ $py_exit -ne 0 ]]; then echo "$candidates" >&2; exit 1; fi

    if [[ -z "$candidates" ]]; then
        echo "No nodes match the purge criteria."
        exit 0
    fi

    # Display candidates
    echo "Nodes to be purged:"
    echo ""
    printf "  %-24s  %-20s  %-12s  %s\n" "NODE ID" "DISPLAY NAME" "STATUS" "LAST SEEN"
    printf "  %-24s  %-20s  %-12s  %s\n" "------------------------" "--------------------" "------------" "-------------------"
    while IFS=$'\t' read -r nid dname status ls; do
        printf "  %-24s  %-20s  %-12s  %s\n" "$nid" "$dname" "$status" "$ls"
    done <<< "$candidates"
    echo ""

    if [[ $dry_run -eq 1 ]]; then
        echo "(dry-run — no changes made)"
        exit 0
    fi

    # Confirm unless --force
    if [[ $force -eq 0 ]]; then
        local count ans
        count=$(echo "$candidates" | wc -l | tr -d ' ')
        read -r -p "Permanently delete ${count} node(s)? This cannot be undone. [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
    fi

    # Execute purge
    local failed=0
    while IFS=$'\t' read -r nid _rest; do
        local del_resp del_http del_body
        del_resp=$(_curl_admin DELETE "/admin/v1/nodes/${nid}/purge") || {
            echo "  ERROR: request failed for ${nid}" >&2; failed=1; continue
        }
        del_http=$(echo "$del_resp" | tail -1)
        del_body=$(echo "$del_resp" | sed '$d')
        if [[ "$del_http" == "200" ]]; then
            echo "  purged: ${nid}"
        else
            echo "  ERROR: ${nid} — HTTP ${del_http}: ${del_body}" >&2
            failed=1
        fi
    done <<< "$candidates"

    [[ $failed -eq 0 ]] && echo "" && echo "Done."
    exit $failed
}

cmd_rename() {
    _load_state
    local target_node_id="" new_id="" display_name=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller)    CONTROLLER_URL="$2"; shift 2 ;;
            --api-key)       API_KEY_STATE="$2";  shift 2 ;;
            --node-id)       target_node_id="$2"; shift 2 ;;
            --new-id)        new_id="$2";         shift 2 ;;
            --display-name)  display_name="$2";   shift 2 ;;
            *)               echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    _require_controller

    if [[ -z "$target_node_id" ]]; then
        echo "ERROR: --node-id required" >&2; exit 1
    fi
    if [[ -z "$new_id" && -z "$display_name" ]]; then
        echo "ERROR: at least one of --new-id or --display-name required" >&2; exit 1
    fi

    # Show summary of what will change
    echo "Node rename summary:"
    echo "  Current node-id:    $target_node_id"
    [[ -n "$new_id" ]]       && echo "  New node-id:        $new_id"
    [[ -n "$display_name" ]] && echo "  New display name:   $display_name"
    if [[ -n "$new_id" ]]; then
        echo ""
        echo "  NOTE: the id change takes effect on the node's next heartbeat (≤30s)."
        echo "        heartbeat.sh will update ~/.config/ai-stack/node_id automatically."
    fi
    echo ""

    local ans
    read -r -p "Apply rename? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

    # Build JSON payload safely
    local payload
    payload=$(python3 -c "
import json, sys
obj = {}
new_id       = sys.argv[1]
display_name = sys.argv[2]
if new_id:       obj['new_id']       = new_id
if display_name: obj['display_name'] = display_name
print(json.dumps(obj))
" "$new_id" "$display_name")

    local response http_code body_part
    response=$(_curl_admin PATCH "/admin/v1/nodes/${target_node_id}/rename" "$payload") || {
        echo "ERROR: request failed" >&2; exit 1
    }
    http_code=$(echo "$response" | tail -1)
    body_part=$(echo "$response" | sed '$d')

    if [[ "$http_code" == "200" ]]; then
        echo "Done."
        [[ -n "$new_id" ]] && echo "  Waiting for node to pick up rename on next heartbeat..."
    else
        echo "ERROR: rename failed (HTTP $http_code):" >&2
        echo "$body_part" >&2
        exit 1
    fi
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
# Load node-file data: build two lookup maps
#   nf_alias_map  — keyed by .alias  (stable — preferred)
#   nf_nodeid_map — keyed by .node_id (backward compat for un-aliased nodes)
# ------------------------------------------------------------------
nf_alias_map  = {}
nf_nodeid_map = {}
ctrl_rows = []
for path in sorted(glob.glob(nodes_dir + "/*.json")):
    try:
        nf = json.load(open(path))
    except Exception:
        continue
    a   = nf.get("alias", "")
    nid = nf.get("node_id", "")
    if a:
        nf_alias_map[a] = nf
    if nid:
        nf_nodeid_map[nid] = nf
    if nf.get("profile") == "controller":
        caps = nf.get("capabilities", [])
        ctrl_rows.append({
            "node_id":      nid or a,
            "display_name": nf.get("name", nid or a),
            "profile":      "controller",
            "status":       "local",
            "last_seen":    "",
            "capabilities": caps,
            "models":       nf.get("models", []),
        })

# Merge DB rows with node-file models.
# Prefer alias-based lookup; fall back to node_id for nodes that haven't
# sent their alias yet (pre-upgrade heartbeat).
all_rows = []
for n in db_nodes:
    nid        = n.get("node_id", "")
    node_alias = n.get("alias", "")
    nf = (nf_alias_map.get(node_alias) or nf_nodeid_map.get(nid)) or {}
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
# harden-worker — Print firewall commands to restrict Ollama port 11434
#                 on an inference-worker node to controller access only.
#
# Usage: node.sh harden-worker --node-id <id> [--controller-ip <ip>]
#
# Reads node config from configs/nodes/<alias>.json to determine OS and
# deployment type, then prints OS-appropriate firewall instructions.
# The operator copies these commands and runs them on the target worker.
# ---------------------------------------------------------------------------

_harden_worker_linux() {
    local node_id="$1" controller_ip="$2"
    local port="11434"

    cat <<EOF
Linux (nftables / firewalld) — run on worker node: $node_id
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Option A — nftables (Fedora / RHEL 9+ default):

  # Allow Ollama from controller only; drop all other inbound traffic on 11434
  sudo nft add rule inet filter input ip saddr $controller_ip tcp dport $port accept comment '"ai-stack allow controller"'
  sudo nft add rule inet filter input tcp dport $port drop comment '"ai-stack block ollama"'

  # Persist across reboots:
  sudo sh -c 'nft list ruleset > /etc/nftables.conf'
  sudo systemctl enable --now nftables

Option B — firewalld (if active instead of raw nftables):

  sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" source address="$controller_ip" port port="$port" protocol="tcp" accept'
  sudo firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port port="$port" protocol="tcp" drop'
  sudo firewall-cmd --reload

Verify from the controller after applying:
  bash scripts/configure.sh security-audit   # WORKER-OLLAMA-${node_id^^} should show OK

EOF
}

_harden_worker_macos() {
    local node_id="$1" controller_ip="$2"
    local port="11434"

    cat <<EOF
macOS (pf) — run on worker node: $node_id
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

Step 1 — Create the pf anchor file:

  sudo tee /etc/pf.anchors/ai-stack-ollama <<'PFRULES'
  # Allow Ollama from controller only
  pass  in quick proto tcp from $controller_ip to any port $port
  block in quick proto tcp to any port $port
  PFRULES

Step 2 — Load it immediately:

  sudo pfctl -a ai-stack-ollama -f /etc/pf.anchors/ai-stack-ollama
  sudo pfctl -e

Step 3 — Persist across reboots:
  Add the following line to /etc/pf.conf (before the 'anchor "com.apple/*"' line):

    anchor "ai-stack-ollama" from file "/etc/pf.anchors/ai-stack-ollama"

Verify from the controller after applying:
  bash scripts/configure.sh security-audit   # WORKER-OLLAMA-${node_id^^} should show OK

EOF
}

cmd_harden_worker() {
    local node_id="" node_alias="" controller_ip_override=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --node-id)       node_id="$2";               shift 2 ;;
            --alias)         node_alias="$2";             shift 2 ;;
            --controller-ip) controller_ip_override="$2"; shift 2 ;;
            -h|--help)
                echo "Usage: node.sh harden-worker --alias <alias> [--controller-ip <ip>]"
                echo "            or: node.sh harden-worker --node-id <id> [--controller-ip <ip>]"
                echo ""
                echo "Prints OS-appropriate firewall instructions to restrict Ollama port 11434"
                echo "on the target inference-worker to the controller IP only."
                echo ""
                echo "Options:"
                echo "  --alias         <alias>  Worker alias, e.g. inference-worker-1 (preferred)"
                echo "  --node-id       <id>     Worker node_id, e.g. TC25 (backward compat)"
                echo "  --controller-ip <ip>     Override auto-detected controller IP"
                return 0 ;;
            *) echo "ERROR: unknown flag: $1" >&2; usage >&2; exit 1 ;;
        esac
    done

    if [[ -z "$node_id" && -z "$node_alias" ]]; then
        echo "ERROR: --alias or --node-id is required" >&2
        usage >&2
        exit 1
    fi

    # --- Locate node in configs/nodes/ ---
    local nodes_dir="$SCRIPT_DIR/../configs/nodes"
    local node_file=""
    local f
    while IFS= read -r -d '' f; do
        if [[ -n "$node_alias" ]]; then
            local a
            a=$(jq -r '.alias // empty' "$f")
            if [[ "$a" == "$node_alias" ]]; then
                node_file="$f"
                break
            fi
        else
            local nid
            nid=$(jq -r '.node_id // empty' "$f")
            if [[ "$nid" == "$node_id" ]]; then
                node_file="$f"
                break
            fi
        fi
    done < <(find "$nodes_dir" -maxdepth 1 -name '*.json' -print0 2>/dev/null)

    local lookup_id="${node_alias:-$node_id}"
    if [[ -z "$node_file" ]]; then
        if [[ -n "$node_alias" ]]; then
            echo "ERROR: No node with alias='$node_alias' found in configs/nodes/" >&2
        else
            echo "ERROR: No node with node_id='$node_id' found in configs/nodes/" >&2
        fi
        echo "       Available aliases:" >&2
        jq -r '.alias // .node_id' "$nodes_dir"/*.json 2>/dev/null | sed 's/^/         /' >&2
        exit 1
    fi

    local profile os_type
    profile=$(jq -r '.profile // ""' "$node_file")
    os_type=$(jq -r '.os // "linux"' "$node_file")

    if [[ "$profile" != "inference-worker" ]]; then
        echo "ERROR: node '$node_id' has profile '$profile' — only inference-worker nodes run Ollama" >&2
        exit 1
    fi

    # --- Resolve controller IP ---
    local controller_ip="$controller_ip_override"
    if [[ -z "$controller_ip" ]]; then
        local ctrl_addr ctrl_fallback
        ctrl_addr=$(for cf in "$nodes_dir"/*.json; do
            [[ -f "$cf" ]] && jq -r 'select(.profile == "controller") | .address // empty' "$cf"
        done 2>/dev/null | grep -v '^$' | head -1 || true)
        ctrl_fallback=$(for cf in "$nodes_dir"/*.json; do
            [[ -f "$cf" ]] && jq -r 'select(.profile == "controller") | .address_fallback // empty' "$cf"
        done 2>/dev/null | grep -v '^null$\|^$' | head -1 || true)

        # Resolve DNS to IP — firewall rules need an IP, not a hostname
        if [[ -n "$ctrl_addr" && "$ctrl_addr" != "null" ]]; then
            local resolved
            resolved=$(getent hosts "$ctrl_addr" 2>/dev/null | awk '{print $1}' | head -1 || true)
            controller_ip="${resolved:-$ctrl_fallback}"
        fi
        if [[ -z "$controller_ip" || "$controller_ip" == "null" ]]; then
            controller_ip="$ctrl_fallback"
        fi
    fi

    if [[ -z "$controller_ip" || "$controller_ip" == "null" ]]; then
        echo "ERROR: Cannot determine controller IP." >&2
        echo "       Set address_fallback on the controller node in configs/nodes/, or use --controller-ip <ip>" >&2
        exit 1
    fi

    local worker_addr
    worker_addr=$(jq -r '.address // .address_fallback // "unknown"' "$node_file")

    echo ""
    echo "Inference Worker Hardening Plan"
    echo "================================"
    echo "  Node:           $lookup_id  ($worker_addr)"
    echo "  OS:             $os_type"
    echo "  Controller IP:  $controller_ip"
    echo "  Goal:           Restrict Ollama :11434 to controller access only"
    echo ""

    if [[ "$os_type" == "darwin" ]]; then
        _harden_worker_macos "$lookup_id" "$controller_ip"
    else
        _harden_worker_linux "$lookup_id" "$controller_ip"
    fi
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
    purge)       shift; cmd_purge "$@" ;;
    rename)      shift; cmd_rename "$@" ;;
    list)        shift; cmd_list "$@" ;;
    status)      shift; cmd_status "$@" ;;
    suggestions)    shift; cmd_suggestions "$@" ;;
    undeploy)       cmd_undeploy ;;
    harden-worker)  shift; cmd_harden_worker "$@" ;;
    help|--help|-h) usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
