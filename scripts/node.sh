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
#   list    [--headscale-url <url>] [--headscale-key <key>]   List nodes (headscale backend, preferred)
#           [--controller <url>] [--api-key <key>]             List nodes (KI backend, legacy)
#           [--namespace <tag>] [--json] [-v] [-m]             Filter/format flags
#   status  [--node-id <id>]      Show this node's status from the controller
#   suggestions list   [--node-id <id>]
#   suggestions show   <suggestion-id> [--node-id <id>]
#   suggestions apply  <suggestion-id> [--node-id <id>]
#                                 Manage controller suggestions for this node
#   configure                      Write ~/.config/ai-stack/node-config.json from local state + Ollama
#   harden-worker --alias <alias> [--controller-ip <ip>]
#                                 Print OS-appropriate firewall rules to restrict Ollama :11434
#                                 on an inference-worker to controller access only
#                                 (--node-id <id> also accepted for backward compat)
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
  configure                      Write node-config.json from local environment (run on each worker)
  list    [--headscale-url <url>] [--headscale-key <key>]  List nodes from headscale (preferred)
          [--controller <url>] [--api-key <key>]           Or from KI controller (legacy)
          [--namespace <tag>]                              Filter by namespace tag
          [--refresh]                                      SSH-pull node-config.json from each online node
          [--cache-dir <dir>]                              Override cache dir (default: ~/.config/ai-stack/nodes/)
          [--json]                                         Machine-readable JSON output
          [-v] [-m]                                        -v: verbose, -m: names+messages only
  status  [--node-id <id>]       Show node status from controller
  suggestions list               List pending suggestions
  suggestions show <id>          Show suggestion detail
  suggestions apply <id>         Mark suggestion consumed
  configure                      Write node-config.json from local environment (run on each worker)
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

    local args=(-s -w "\n%{http_code}" -X "$method" --insecure)   # self-signed CA; API key provides endpoint auth
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

# ---------------------------------------------------------------------------
# cmd_configure — write node-config.json from local state
# ---------------------------------------------------------------------------

cmd_configure() {
    _load_state
    _require_node_id

    local out_file="$STATE_DIR/node-config.json"
    local _cli_controller_url=""
    local _cli_bearer_token=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller-url) _cli_controller_url="$2"; shift 2 ;;
            --bearer-token)   _cli_bearer_token="$2";   shift 2 ;;
            *) shift ;;
        esac
    done
    mkdir -p "$STATE_DIR"

    # --- Determine OS ---
    local os_type="linux"
    [[ "$(uname -s)" == "Darwin" ]] && os_type="darwin"

    # --- Load alias from state (written by node.sh join) ---
    local alias_val=""
    [[ -f "$STATE_DIR/alias" ]] && alias_val="$(cat "$STATE_DIR/alias" 2>/dev/null || true)"

    # --- Detect profile from state, then static node file, then default ---
    local profile_val="inference-worker"
    if [[ -f "$STATE_DIR/profile" ]]; then
        profile_val="$(cat "$STATE_DIR/profile" 2>/dev/null || true)"
    else
        # Try to match from configs/nodes/ by alias or node_id
        local _nodes_dir="$SCRIPT_DIR/../configs/nodes"
        local _matched_profile=""
        if [[ -d "$_nodes_dir" ]]; then
            _matched_profile=$(python3 - "$_nodes_dir" "${alias_val:-}" "${NODE_ID:-}" <<'PYEOF2' 2>/dev/null
import glob, json, sys
ndir, alias_val, nid = sys.argv[1], sys.argv[2], sys.argv[3]
for f in glob.glob(ndir + '/*.json'):
    try:
        d = json.load(open(f))
        if (alias_val and d.get('alias') == alias_val) or (nid and d.get('node_id') == nid):
            print(d.get('profile', ''))
            break
    except Exception:
        pass
PYEOF2
            )
        fi
        [[ -n "$_matched_profile" ]] && profile_val="$_matched_profile"
    fi

    # --- Detect deployment mode ---
    local deployment="bare_metal"
    if command -v systemctl &>/dev/null && systemctl --user list-units --type=service 2>/dev/null | grep -q 'knowledge-index'; then
        deployment="container"
    fi

    # --- Probe Ollama models ---
    local models_json="[]"
    if command -v curl &>/dev/null; then
        local ollama_resp
        ollama_resp=$(curl -s --connect-timeout 3 http://localhost:11434/api/tags 2>/dev/null || echo '')
        if [[ -n "$ollama_resp" ]]; then
            models_json=$(echo "$ollama_resp" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    print(json.dumps([m['name'] for m in d.get('models',[])]))
except:
    print('[]')
" 2>/dev/null || echo '[]')
        fi
    fi

    # --- Derive capabilities from profile ---
    local caps_json
    case "$profile_val" in
        controller)         caps_json='["inference","knowledge","routing"]' ;;
        knowledge-worker)   caps_json='["inference","knowledge"]' ;;
        inference-worker)   caps_json='["inference"]' ;;
        enhanced-worker)    caps_json='["inference","knowledge"]' ;;
        *)                  caps_json='[]' ;;
    esac

    local ts
    ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")

    # --- Resolve controller_url (BL-015) ---
    # Priority: --controller-url flag → config.json tailnet.controller_url → GET /v1/config discovery
    local controller_url_val=""
    if [[ -n "$_cli_controller_url" ]]; then
        controller_url_val="$_cli_controller_url"
    else
        # Try config.json (controller node only)
        local _cfg_controller_url=""
        local _cfg_path="$SCRIPT_DIR/../configs/config.json"
        if [[ -f "$_cfg_path" ]]; then
            _cfg_controller_url=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(d.get('tailnet', {}).get('controller_url', ''))
except Exception:
    print('')
" "$_cfg_path" 2>/dev/null || true)
        fi
        if [[ -n "$_cfg_controller_url" ]]; then
            controller_url_val="$_cfg_controller_url"
        else
            # Attempt GET /v1/config discovery from hardcoded bootstrap IP
            local _discovery_resp
            _discovery_resp=$(curl -sk --connect-timeout 5 \
                https://100.64.0.4:8443/v1/config 2>/dev/null || true)
            if [[ -n "$_discovery_resp" ]]; then
                controller_url_val=$(echo "$_discovery_resp" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('controller_url', ''))
except: print('')
" 2>/dev/null || true)
            fi
        fi
    fi

    # Write bearer token to state if provided (workers provision this manually)
    if [[ -n "$_cli_bearer_token" ]]; then
        printf '%s' "$_cli_bearer_token" > "$STATE_DIR/network_bearer_token"
    fi
    # Read saved bearer token for inclusion in node-config.json
    local network_bearer_token_val=""
    [[ -f "$STATE_DIR/network_bearer_token" ]] && \
        network_bearer_token_val="$(cat "$STATE_DIR/network_bearer_token" 2>/dev/null || true)"

    python3 - > "$out_file" <<PYEOF
import json
out = {
    "schema_version": "1.2",
    "node_id":    "${NODE_ID}",
    "alias":      "${alias_val}",
    "profile":    "${profile_val}",
    "os":         "$os_type",
    "deployment": "$deployment",
    "capabilities": ${caps_json},
    "models":     ${models_json},
    "version":    "1",
    "updated_at": "$ts",
    "network": {
        "controller_url":  "${controller_url_val}",
        "bearer_token":    "${network_bearer_token_val}",
    },
}
print(json.dumps(out, indent=2))
PYEOF

    echo "[configure] wrote $out_file"
    cat "$out_file"
}

# ---------------------------------------------------------------------------
# cmd_list
# ---------------------------------------------------------------------------

cmd_list() {
    _load_state
    local verbose=0
    local msg_only=0
    local json_out=0
    local namespace_filter=""
    local do_refresh=0
    local cache_dir="$STATE_DIR/nodes"
    local HS_URL="${HS_URL:-}"
    local HS_KEY="${HS_KEY:-}"

    # Load headscale state if saved
    if [[ -f "$STATE_DIR/headscale_url" ]]; then
        HS_URL="${HS_URL:-$(cat "$STATE_DIR/headscale_url")}"
    fi
    if [[ -f "$STATE_DIR/headscale_key" ]]; then
        HS_KEY="${HS_KEY:-$(cat "$STATE_DIR/headscale_key")}"
    fi

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --controller)    CONTROLLER_URL="$2";    shift 2 ;;
            --api-key)       API_KEY_STATE="$2";     shift 2 ;;
            --headscale-url) HS_URL="$2";            shift 2 ;;
            --headscale-key) HS_KEY="$2";            shift 2 ;;
            --namespace)     namespace_filter="$2";  shift 2 ;;
            --refresh)       do_refresh=1;           shift   ;;
            --cache-dir)     cache_dir="$2";         shift 2 ;;
            --json)          json_out=1;             shift   ;;
            -v)              verbose=1;              shift   ;;
            -m)              msg_only=1;             shift   ;;
            *)               echo "Unknown option: $1" >&2; exit 1 ;;
        esac
    done

    local response http_code body_part use_headscale=0

    if [[ -n "$HS_URL" ]]; then
        use_headscale=1
        local hs_args=(-s -w "\n%{http_code}" -X GET)
        [[ -n "$HS_KEY" ]] && hs_args+=(-H "Authorization: Bearer $HS_KEY")
        response=$(curl "${hs_args[@]}" "${HS_URL}/api/v1/node") || {
            echo "ERROR: Failed to reach headscale at ${HS_URL}" >&2; exit 1
        }
    else
        _require_controller
        response=$(_curl_admin GET "/admin/v1/nodes") || {
            echo "ERROR: Failed to reach controller at ${CONTROLLER_URL}" >&2; exit 1
        }
    fi

    http_code=$(echo "$response" | tail -1)
    body_part=$(echo "$response" | sed '$d')

    if [[ "$http_code" != "200" ]]; then
        echo "ERROR: List failed (HTTP $http_code):" >&2
        echo "$body_part" >&2
        exit 1
    fi

    # ---------------------------------------------------------------------------
    # --refresh: SSH-pull node-config.json from each online headscale node
    # ---------------------------------------------------------------------------
    if [[ "$do_refresh" -eq 1 ]]; then
        if [[ "$use_headscale" -eq 0 ]]; then
            echo "ERROR: --refresh requires --headscale-url (or saved headscale state)" >&2
            exit 1
        fi
        mkdir -p "$cache_dir"
        local ts_stale
        ts_stale=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || python3 -c "import datetime; print(datetime.datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ'))")
        echo "[refresh] cache dir: $cache_dir"
        # Extract online node names from the headscale response
        local online_names
        online_names=$(echo "$body_part" | python3 -c "
import json,sys
data=json.load(sys.stdin)
for n in data.get('nodes',[]):
    name=n.get('givenName') or n.get('given_name') or n.get('name','')
    if n.get('online',False) and name:
        print(name)
" 2>/dev/null || true)
        local refreshed=0 failed=0
        local local_hostname; local_hostname=$(hostname -s 2>/dev/null | tr '[:upper:]' '[:lower:]' || true)
        while IFS= read -r node_name; do
            [[ -z "$node_name" ]] && continue
            local dest="$cache_dir/${node_name}.json"
            local node_lower; node_lower=$(echo "$node_name" | tr '[:upper:]' '[:lower:]')
            # Self: copy local node-config.json directly without SSH
            if [[ "$node_lower" == "$local_hostname" ]] || tailscale ip -4 2>/dev/null | grep -qF "$(tailscale ip -4 2>/dev/null | head -1)"; then
                # More precise self-check: compare tailscale self name
                local self_name; self_name=$(tailscale status --json 2>/dev/null | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('Self',{}).get('HostName',''))" 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo '')
                if [[ "$node_lower" == "$self_name" ]]; then
                    if [[ -f "$STATE_DIR/node-config.json" ]]; then
                        cp "$STATE_DIR/node-config.json" "$dest"
                        echo "[refresh] $node_name local-copy OK → $dest"
                        (( refreshed++ )) || true
                    else
                        echo "[refresh] $node_name local-copy SKIPPED (run: node.sh configure first)"
                        (( failed++ )) || true
                    fi
                    continue
                fi
            fi
            if tailscale ssh "${node_name}" cat '~/.config/ai-stack/node-config.json' > "$dest" 2>/dev/null; then
                echo "[refresh] $node_name OK → $dest"
                (( refreshed++ )) || true
            else
                echo "[refresh] $node_name FAILED (node-config.json absent or SSH denied)"
                (( failed++ )) || true
            fi
        done <<< "$online_names"
        echo "[refresh] done: $refreshed refreshed, $failed failed"
        # Write a staleness marker
        printf '%s' "$ts_stale" > "$cache_dir/.refreshed_at"
    fi

    local nodes_dir="$SCRIPT_DIR/../configs/nodes"
    local _tmp; _tmp=$(mktemp)
    echo "$body_part" > "$_tmp"

    python3 - "$_tmp" "$nodes_dir" "$verbose" "$msg_only" "$namespace_filter" "$json_out" "$use_headscale" "$cache_dir" <<'PYEOF'
import glob, json, sys

data_file     = sys.argv[1]
nodes_dir     = sys.argv[2]
verbose       = len(sys.argv) > 3 and sys.argv[3] == '1'
msg_only      = len(sys.argv) > 4 and sys.argv[4] == '1'
namespace_raw = sys.argv[5] if len(sys.argv) > 5 else ''
json_out      = len(sys.argv) > 6 and sys.argv[6] == '1'
use_headscale = len(sys.argv) > 7 and sys.argv[7] == '1'
cache_dir     = sys.argv[8] if len(sys.argv) > 8 else ''

data = json.load(open(data_file))

# ------------------------------------------------------------------
# Namespace filter normalization
# Accepts: 'ecotone-000-01', 'net-ecotone-000-01', 'tag:net-ecotone-000-01'
# ------------------------------------------------------------------
def normalize_ns_tag(raw):
    if not raw:
        return None
    s = raw.strip()
    if s.startswith('tag:'):
        s = s[4:]
    if not s.startswith('net-'):
        s = 'net-' + s
    return 'tag:' + s

ns_tag = normalize_ns_tag(namespace_raw)

# ------------------------------------------------------------------
# Load node-file data: build lookup maps
#   Priority order: cache dir (from --refresh) > configs/nodes/ (static fallback)
#   nf_alias_map    — keyed by .alias  (stable — preferred for KI)
#   nf_nodeid_map   — keyed by .node_id (backward compat)
#   nf_hostname_map — keyed by .node_id.lower() (headscale name match)
# ------------------------------------------------------------------
import os, datetime as dt

nf_alias_map    = {}
nf_nodeid_map   = {}
nf_hostname_map = {}

# Check staleness of cache
cache_stale_warn = ''
if cache_dir and os.path.isfile(os.path.join(cache_dir, '.refreshed_at')):
    try:
        ts_raw = open(os.path.join(cache_dir, '.refreshed_at')).read().strip()
        ts     = dt.datetime.fromisoformat(ts_raw.replace('Z', '+00:00'))
        age    = dt.datetime.now(dt.timezone.utc) - ts
        if age.total_seconds() > 600:
            mins = int(age.total_seconds() / 60)
            cache_stale_warn = f'[warn] node cache is {mins}m old — run: node.sh list --refresh'
    except Exception:
        pass

# Load: cache dir first, then static configs/nodes/
search_paths = []
if cache_dir and os.path.isdir(cache_dir):
    search_paths.append(cache_dir)
search_paths.append(nodes_dir)

for sdir in search_paths:
    for path in sorted(glob.glob(sdir + '/*.json')):
        try:
            nf = json.load(open(path))
        except Exception:
            continue
        a   = nf.get('alias', '')
        nid = nf.get('node_id', '')
        # Cache takes priority — do not overwrite with static file
        if a and a not in nf_alias_map:
            nf_alias_map[a] = nf
        if nid and nid not in nf_nodeid_map:
            nf_nodeid_map[nid] = nf
            nf_hostname_map[nid.lower()] = nf
        # Also index by the filename stem (headscale givenName is the hostname)
        stem = os.path.splitext(os.path.basename(path))[0].lower()
        if stem and stem not in nf_hostname_map:
            nf_hostname_map[stem] = nf

def fmt_list(lst):
    return ", ".join(str(x) for x in lst) if lst else "-"

# ------------------------------------------------------------------
# Build rows — headscale path
# ------------------------------------------------------------------
rows = []
ctrl_count = 0

if use_headscale:
    hs_nodes = data.get('nodes', [])
    for n in hs_nodes:
        # headscale v0.28 REST API field names (verified against /api/v1/node)
        name      = n.get('givenName') or n.get('given_name') or n.get('name', '')
        ips       = n.get('ipAddresses') or n.get('ip_addresses') or []
        # REST API returns merged tag list as 'tags'; proto path uses validTags/forcedTags
        tags      = (n.get('tags') or
                     n.get('validTags') or n.get('valid_tags') or
                     n.get('forcedTags') or n.get('forced_tags') or [])
        online    = n.get('online', False)
        last_seen = (n.get('lastSeen') or n.get('last_seen') or '')[:19]

        # Match node config by hostname (case-insensitive node_id comparison)
        nf      = nf_hostname_map.get(name.lower()) or nf_alias_map.get(name) or {}
        profile = nf.get('profile', '')
        if profile == 'controller':
            ctrl_count += 1

        rows.append({
            'node_id':      name,
            'display_name': nf.get('name', name),
            'profile':      profile,
            'ip_addresses': ips,
            'tags':         tags,
            'status':       'online' if online else 'offline',
            'last_seen':    last_seen,
            'capabilities': nf.get('capabilities', []),
            'models':       nf.get('models', []),
            'last_message': '',
        })

else:
    # ------------------------------------------------------------------
    # Build rows — KI controller path (original)
    # ------------------------------------------------------------------
    db_nodes  = data.get('nodes', [])

    ctrl_rows = []
    for path in sorted(glob.glob(nodes_dir + "/*.json")):
        try:
            nf = json.load(open(path))
        except Exception:
            continue
        if nf.get("profile") == "controller":
            a   = nf.get("alias", "")
            nid = nf.get("node_id", "")
            ctrl_rows.append({
                "node_id":      nid or a,
                "display_name": nf.get("name", nid or a),
                "profile":      "controller",
                "ip_addresses": [],
                "tags":         [],
                "status":       "local",
                "last_seen":    "",
                "capabilities": nf.get("capabilities", []),
                "models":       nf.get("models", []),
                "last_message": "",
            })
    ctrl_count = len(ctrl_rows)

    worker_rows = []
    for n in db_nodes:
        nid        = n.get("node_id", "")
        node_alias = n.get("alias", "")
        nf = (nf_alias_map.get(node_alias) or nf_nodeid_map.get(nid)) or {}
        caps = n.get("capabilities", [])
        if isinstance(caps, dict):
            caps = list(caps.keys())
        worker_rows.append({
            "node_id":      nid,
            "display_name": n.get("display_name", ""),
            "profile":      n.get("profile", ""),
            "ip_addresses": [],
            "tags":         [],
            "status":       n.get("status", ""),
            "last_seen":    (n.get("last_seen") or "")[:19],
            "capabilities": caps,
            "models":       nf.get("models", []),
            "last_message": n.get("last_message", ""),
        })

    rows = ctrl_rows + worker_rows

# ------------------------------------------------------------------
# Namespace filter (meaningful only with headscale data; tags=[] in KI mode)
# ------------------------------------------------------------------
if ns_tag:
    rows = [r for r in rows if ns_tag in r.get('tags', [])]

if cache_stale_warn:
    print(cache_stale_warn)
    print()

if not rows:
    suffix = f" (filter: {ns_tag})" if ns_tag else ""
    print(f"No nodes found.{suffix}")
    sys.exit(0)

# ------------------------------------------------------------------
# JSON output
# ------------------------------------------------------------------
if json_out:
    out = []
    for r in rows:
        out.append({
            'name':         r['node_id'],
            'display_name': r['display_name'],
            'profile':      r['profile'],
            'ip_addresses': r['ip_addresses'],
            'tags':         r['tags'],
            'status':       r['status'],
            'last_seen':    r['last_seen'],
            'capabilities': r['capabilities'],
            'models':       r['models'],
        })
    print(json.dumps(out, indent=2))
    sys.exit(0)

# ------------------------------------------------------------------
# msg_only output
# ------------------------------------------------------------------
if msg_only:
    for r in rows:
        name = r.get('display_name') or r.get('node_id', '')
        msg  = r.get('last_message', '')
        print(f"{name}")
        if msg:
            print(f"   Message: {msg}")
        print()
    sys.exit(0)

# ------------------------------------------------------------------
# Stanza output (human-readable)
# ------------------------------------------------------------------
for r in rows:
    label = r.get('display_name') or r.get('node_id', '')
    print(label)
    if r.get('profile'):
        print(f"  profile:      {r['profile']}")
    if r.get('ip_addresses'):
        print(f"  ip:           {fmt_list(r['ip_addresses'])}")
    if r.get('tags'):
        print(f"  tags:         {fmt_list(r['tags'])}")
    print(f"  status:       {r['status']}")
    if r.get('last_seen'):
        print(f"  last_seen:    {r['last_seen']}")
    if r.get('capabilities'):
        print(f"  capabilities: {fmt_list(r['capabilities'])}")
    if r.get('models'):
        mnames = [m if isinstance(m, str) else m.get('name', str(m)) for m in r['models']]
        print(f"  models:       {fmt_list(mnames)}")
    if verbose and r.get('last_message'):
        print(f"  message:      {r['last_message']}")
    print()

worker_count = len(rows) - ctrl_count
print(f"Total: {len(rows)} node(s)  ({ctrl_count} controller, {worker_count} registered)")
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
# Usage: node.sh harden-worker --alias <alias> [--controller-ip <ip>]
#              or: node.sh harden-worker --node-id <id> [--controller-ip <ip>]  (backward compat)
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
    deploy)         cmd_deploy ;;
    configure)      cmd_configure "$@" ;;
    join)           shift; cmd_join "$@" ;;
    unjoin)         shift; cmd_unjoin "$@" ;;
    pause)          cmd_pause ;;
    purge)          shift; cmd_purge "$@" ;;
    rename)         shift; cmd_rename "$@" ;;
    list)           shift; cmd_list "$@" ;;
    status)         shift; cmd_status "$@" ;;
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
