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
#   list    [--controller <url>] [--api-key <key>]  List all registered nodes and their status
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
          [--api-key <key>]       List all registered nodes and their status
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
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller) CONTROLLER_URL="$2"; shift 2 ;;
            --api-key)    API_KEY_STATE="$2";  shift 2 ;;
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

    echo "$body_part" | python3 -m json.tool 2>/dev/null || echo "$body_part"
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
