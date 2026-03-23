#!/usr/bin/env bash
# scripts/status.sh — AI Stack health status
#
# Exit codes:
#   0  All services active
#   1  Deployed but one or more services not active (degraded/stopped/failed)
#   2  Not deployed (no quadlet .container files found in QUADLET_DIR)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"
NODE_PROFILE_FILE="${NODE_PROFILE_FILE:-$PROJECT_ROOT/configs/node_profile}"
QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"

_get_node_profile() {
    if [[ -f "$NODE_PROFILE_FILE" ]]; then
        local p; p=$(tr -d '[:space:]' < "$NODE_PROFILE_FILE")
        [[ -n "$p" ]] && { echo "$p"; return; }
    fi
    jq -r '.node_profile // "controller"' "$CONFIG_FILE" 2>/dev/null || echo "controller"
}

QUIET=false
CHECK_ONLY=false

usage() {
    cat <<'EOF'
Usage: status.sh [options]

Purpose:
  Show the health and running state of all AI stack services.
  Used by start.sh, stop.sh, and undeploy.sh to detect deployment state.

Options:
  --quiet       Suppress all output; rely on exit code only
  --check       Only check if stack is deployed (skips service state queries)
  -h, --help    Show this message

Exit codes:
  0   All services active
  1   Deployed but one or more services not active (degraded/stopped/failed)
  2   Not deployed (no quadlet files found in QUADLET_DIR)

Environment:
  CONFIG_FILE   Path to config.json  (default: ./configs/config.json)
  QUADLET_DIR   Quadlet directory    (default: ~/.config/containers/systemd)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)  QUIET=true ;;
        --check)  CHECK_ONLY=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
    esac
    shift
done

# ── Deployment check ──────────────────────────────────────────────────────────

quadlet_count=0
if [[ -d "$QUADLET_DIR" ]]; then
    quadlet_count=$(find "$QUADLET_DIR" -maxdepth 1 -name "*.container" 2>/dev/null | wc -l)
fi

if [[ $quadlet_count -eq 0 ]]; then
    if ! $QUIET; then
        echo "Stack is NOT DEPLOYED (no quadlet files found in $QUADLET_DIR)"
        echo "Run: ./scripts/deploy.sh"
    fi
    exit 2
fi

# If caller only wanted a deployment check, we're done
$CHECK_ONLY && exit 0

# ── Prerequisites ─────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2
    exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    exit 1
fi

# ── Gather service states ─────────────────────────────────────────────────────

net_name=$(jq -r '.network.name' "$CONFIG_FILE")

# Filter services to those expected for this node profile
case "$(_get_node_profile)" in
    inference-worker)  _profile_svcs='["ollama","promtail"]' ;;
    knowledge-worker)  _profile_svcs='["ollama","promtail","knowledge-index","qdrant"]' ;;
    *)                 _profile_svcs='null' ;;  # controller/peer: all services
esac

if [[ "$_profile_svcs" == "null" ]]; then
    mapfile -t services < <(jq -r '.services | keys[]' "$CONFIG_FILE")
else
    mapfile -t services < <(jq -r --argjson svcs "$_profile_svcs" \
        '.services | keys[] | select(. as $k | $svcs | index($k) != null)' "$CONFIG_FILE")
fi

total=${#services[@]}
active=0
failed_count=0
unhealthy_count=0

declare -A svc_states=()
declare -A svc_health=()
for svc in "${services[@]}"; do
    state=$(systemctl --user is-active "${svc}.service" 2>/dev/null || true)
    [[ -z "$state" ]] && state="unknown"
    svc_states[$svc]="$state"
    [[ "$state" == "active"  ]] && active=$((active + 1))
    [[ "$state" == "failed"  ]] && failed_count=$((failed_count + 1))

    # Container-level health (only meaningful when active)
    health=""
    if [[ "$state" == "active" ]]; then
        health=$(podman inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || true)
    fi
    svc_health[$svc]="$health"
    [[ "$health" == "unhealthy" ]] && unhealthy_count=$((unhealthy_count + 1))
done

# ── Print table ───────────────────────────────────────────────────────────────

if ! $QUIET; then
    # Column width = longest service name + 2
    max_len=7  # minimum width ("SERVICE")
    for svc in "${services[@]}"; do
        [[ ${#svc} -gt $max_len ]] && max_len=${#svc}
    done
    col=$((max_len + 2))

    echo ""
    echo "AI Stack Status"
    echo "════════════════════════════════════════"
    printf "  %-${col}s %s\n" "node profile" "$(_get_node_profile)"

    # Network
    if podman network exists "$net_name" 2>/dev/null; then
        printf "  %-${col}s %s\n" "network/${net_name}" "exists"
    else
        printf "  %-${col}s %s\n" "network/${net_name}" "MISSING"
    fi

    # Secrets summary — scoped to profile services
    if [[ "$_profile_svcs" == "null" ]]; then
        mapfile -t all_secrets < <(jq -r '[.services[].secrets[]?.name] | unique[]' "$CONFIG_FILE" 2>/dev/null || true)
    else
        mapfile -t all_secrets < <(jq -r --argjson svcs "$_profile_svcs" \
            '[.services | to_entries[] | select(.key as $k | $svcs | index($k) != null) | .value.secrets[]?.name] | unique[]' \
            "$CONFIG_FILE" 2>/dev/null || true)
    fi
    total_secrets=${#all_secrets[@]}
    present_secrets=0
    for secret in "${all_secrets[@]}"; do
        if podman secret inspect "$secret" &>/dev/null 2>&1; then
            present_secrets=$((present_secrets + 1))
        fi
    done
    printf "  %-${col}s %s\n" "secrets" "${present_secrets}/${total_secrets} present"

    echo ""
    printf "  %-${col}s %-10s %s\n" "SERVICE" "STATE" "HEALTH"
    printf "  %s\n" "$(printf '─%.0s' $(seq 1 $((col + 22))))"

    for svc in "${services[@]}"; do
        display="${svc_states[$svc]}"
        [[ "$display" == "inactive" ]] && display="stopped"
        health_display="${svc_health[$svc]:-}"
        [[ "$display" != "active" ]] && health_display="-"
        [[ -z "$health_display" ]] && health_display="-"
        printf "  %-${col}s %-10s %s\n" "$svc" "$display" "$health_display"
    done

    echo ""
    if [[ $active -eq $total && $unhealthy_count -eq 0 ]]; then
        echo "  Summary: ${active}/${total} active, all healthy  [OK]"
    elif [[ $failed_count -gt 0 ]]; then
        echo "  Summary: ${active}/${total} active, ${failed_count} failed, ${unhealthy_count} unhealthy  [FAILED]"
    elif [[ $unhealthy_count -gt 0 ]]; then
        echo "  Summary: ${active}/${total} active, ${unhealthy_count} unhealthy  [DEGRADED]"
    else
        echo "  Summary: ${active}/${total} active  [DEGRADED]"
    fi
    echo ""
fi

# ── Exit code ─────────────────────────────────────────────────────────────────

if [[ $active -eq $total && $unhealthy_count -eq 0 ]]; then
    exit 0
else
    exit 1
fi
