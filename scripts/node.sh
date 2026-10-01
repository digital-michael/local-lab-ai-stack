#!/usr/bin/env bash
set -euo pipefail

# node.sh — Node operations for AI Stack workers
#
# Usage: node.sh <command> [options]
#
# Commands:
#   list    [--headscale-url <url>] [--headscale-key <key>]   List nodes (headscale)
#           [--namespace <tag>] [--refresh] [--json] [-v] [-m] Filter/format flags
#   remote  <node> <cmd> [args...]
#                                 Run a command on a worker via SSH (tailnet → LAN fallback)
#   harden-worker --alias <alias> [--controller-ip <ip>]
#                                 Print OS-appropriate firewall rules to restrict Ollama :11434
#                                 on an inference-worker to controller access only
#                                 (--node-id <id> also accepted for backward compat)
#   help                          Show this message
#
# The controller node registry (join/unjoin/purge/rename/status/suggestions,
# configure, deploy/undeploy, heartbeats) lived in the Python Knowledge Index
# and was removed with it on 2026-09-30 (D-045).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${AI_STACK_NODE_DIR:-$HOME/.config/ai-stack}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: node.sh <command> [options]

Commands:
  list    [--headscale-url <url>] [--headscale-key <key>]  List nodes from headscale
          [--namespace <tag>]                              Filter by namespace tag
          [--refresh]                                      SSH-pull node-config.json from each online node
          [--cache-dir <dir>]                              Override cache dir (default: ~/.config/ai-stack/nodes/)
          [--json]                                         Machine-readable JSON output
          [-v] [-m]                                        -v: verbose, -m: names+messages only
  remote  <node> <cmd> [args...] Run a command on a remote worker via SSH
                                  Primary: tailnet IP (tailscale status); fallback: LAN IP
  harden-worker --alias <alias> \
          [--controller-ip <ip>] Print OS-appropriate firewall rules to restrict Ollama :11434
                                 on the target inference-worker to controller access only
          [--node-id <id>]       Backward compat: locate node by node_id instead of alias
  help                           This message

Headscale state: ~/.config/ai-stack/{headscale_url,headscale_key}
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
        echo "ERROR: --headscale-url required (or saved headscale state in $STATE_DIR/headscale_url)" >&2
        exit 1
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
# cmd_remote — SSH command delivery to a worker node
#
# Usage: node.sh remote <node> <cmd> [args...]
#
# Resolves <node> (alias, node_id, or hostname — case-insensitive) to a
# tailnet peer IP via `tailscale status`, then runs the command over SSH.
# Falls back to the node's LAN IP (address_fallback in configs/nodes/) if
# the tailnet connection fails (exit 255).
# SSH user is read from the node file's "ssh_user" field.
# StrictHostKeyChecking disabled — headscale does not serve SSH host keys.
# ---------------------------------------------------------------------------

cmd_remote() {
    if [[ $# -lt 2 ]]; then
        echo "Usage: node.sh remote <node> <cmd> [args...]" >&2
        exit 1
    fi

    local node_arg="$1"
    shift
    local remote_cmd=("$@")

    local nodes_dir="$SCRIPT_DIR/../configs/nodes"
    local cache_dir="$STATE_DIR/nodes"

    # ------------------------------------------------------------------
    # Resolve tailnet peer IP from `tailscale status --json`
    # ------------------------------------------------------------------
    local tailnet_ip=""
    tailnet_ip=$(tailscale status --json 2>/dev/null | python3 -c "import json, sys
try:
    d   = json.load(sys.stdin)
    arg = sys.argv[1].lower()
    for peer in d.get('Peer', {}).values():
        hn  = (peer.get('HostName') or '').lower()
        ips = peer.get('TailscaleIPs', [])
        if hn == arg and ips:
            print(ips[0])
            break
except Exception:
    pass
" "$node_arg" 2>/dev/null || true)

    # ------------------------------------------------------------------
    # Resolve LAN IP and ssh_user from node files (cache dir first, then static)
    # ------------------------------------------------------------------
    local lan_ip="" ssh_user=""
    local _info
    _info=$(python3 - "$nodes_dir" "$cache_dir" "$node_arg" <<'PYEOF' 2>/dev/null
import glob, json, os, sys

nodes_dir = sys.argv[1]
cache_dir = sys.argv[2]
target    = sys.argv[3].lower()

def match(d):
    return target in (
        (d.get('node_id') or '').lower(),
        (d.get('alias')   or '').lower(),
        (d.get('name')    or '').lower(),
    )

for sdir in [cache_dir, nodes_dir]:
    for path in sorted(glob.glob(sdir + '/*.json')):
        try:
            d = json.load(open(path))
        except Exception:
            continue
        stem = os.path.splitext(os.path.basename(path))[0].lower()
        if match(d) or stem == target:
            print(json.dumps({
                'lan_ip':   d.get('address_fallback') or '',
                'ssh_user': d.get('ssh_user') or '',
            }))
            break
    else:
        continue
    break
PYEOF
    )

    if [[ -n "$_info" ]]; then
        lan_ip=$(  echo "$_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('lan_ip',''))"   2>/dev/null || true)
        ssh_user=$(echo "$_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('ssh_user',''))" 2>/dev/null || true)
    fi

    if [[ -z "$tailnet_ip" && -z "$lan_ip" ]]; then
        echo "ERROR: cannot resolve node '${node_arg}' — not in tailscale peers or node files" >&2
        exit 1
    fi

    local _ssh_opts=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10)

    # ------------------------------------------------------------------
    # Primary: tailnet IP
    # SSH exit 255 = connection-level failure; any other code = remote exit code
    # ------------------------------------------------------------------
    if [[ -n "$tailnet_ip" ]]; then
        local _t="$tailnet_ip"
        [[ -n "$ssh_user" ]] && _t="${ssh_user}@${tailnet_ip}"
        local _rc=0
        ssh "${_ssh_opts[@]}" "$_t" "${remote_cmd[@]}" || _rc=$?
        if [[ $_rc -ne 255 ]]; then
            return $_rc   # connected; propagate remote exit code
        fi
        echo "[remote] tailnet SSH to ${_t} failed (connection error) — trying LAN fallback" >&2
    fi

    # ------------------------------------------------------------------
    # Fallback: LAN IP
    # ------------------------------------------------------------------
    if [[ -n "$lan_ip" ]]; then
        local _t="$lan_ip"
        [[ -n "$ssh_user" ]] && _t="${ssh_user}@${lan_ip}"
        local _rc=0
        ssh "${_ssh_opts[@]}" "$_t" "${remote_cmd[@]}" || _rc=$?
        return $_rc
    fi

    echo "ERROR: all SSH paths exhausted for node '${node_arg}'" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

_load_state

case "${1:-help}" in
    list)           shift; cmd_list "$@" ;;
    remote)         shift; cmd_remote "$@" ;;
    harden-worker)  shift; cmd_harden_worker "$@" ;;
    help|--help|-h) usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
