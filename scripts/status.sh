#!/usr/bin/env bash
# scripts/status.sh — AI Stack health status
#
# Exit codes:
#   0  All services active
#   1  Deployed but one or more services not active (degraded/stopped/failed)
#   2  Not deployed (no quadlet .container files found in QUADLET_DIR)

# macOS ships bash 3.2; this script requires bash 4+ (mapfile, declare -A).
# Re-exec automatically with a newer bash if one is available.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for _b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$_b" ]] && [[ "$("$_b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]]; then
            exec "$_b" "$0" "$@"
        fi
    done
    echo "ERROR: bash 4+ required (found $BASH_VERSION)." >&2
    echo "  Install: brew install bash" >&2
    exit 1
fi

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

# ── Service state helpers ────────────────────────────────────────────────────
# Returns: active | inactive | failed | unknown
# Uses systemctl when a quadlet file exists; falls back to HTTP probe otherwise.
_svc_state() {
    local svc="$1"
    if [[ -f "$QUADLET_DIR/${svc}.container" ]]; then
        local s; s=$(systemctl --user is-active "${svc}.service" 2>/dev/null || true)
        echo "${s:-unknown}"
    else
        local port path
        case "$svc" in
            ollama)          port=11434; path="" ;;
            promtail)        port=9080;  path="/ready" ;;
            knowledge-index) port=$(jq -r '.services["knowledge-index"].ports[0].host // 8000' "$CONFIG_FILE" 2>/dev/null || echo 8000); path="/health" ;;
            qdrant)          port=6333;  path="/healthz" ;;
            *)               echo "unknown"; return ;;
        esac
        if curl -sf --max-time 2 "http://localhost:${port}${path}" >/dev/null 2>&1; then
            echo "active"
        else
            echo "inactive"
        fi
    fi
}

# Returns container health (only for quadlet-managed active containers)
_svc_health() {
    local svc="$1" state="$2"
    if [[ "$state" == "active" && -f "$QUADLET_DIR/${svc}.container" ]]; then
        podman inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || true
    fi
}

# ── Deployment check ──────────────────────────────────────────────────────────

quadlet_count=0
if [[ -d "$QUADLET_DIR" ]]; then
    quadlet_count=$(find "$QUADLET_DIR" -maxdepth 1 -name "*.container" 2>/dev/null | wc -l)
fi

# Bare-metal nodes have no quadlets but ollama runs natively
if [[ $quadlet_count -eq 0 ]] && ! command -v ollama &>/dev/null; then
    if ! $QUIET; then
        echo "Stack is NOT DEPLOYED (no quadlet files found in $QUADLET_DIR, no bare-metal ollama found)"
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

# Determine deploy mode: per-service, check whether a quadlet file exists
_quadlet_svc_count=0
_bare_svc_count=0
for svc in "${services[@]}"; do
    if [[ -f "$QUADLET_DIR/${svc}.container" ]]; then
        _quadlet_svc_count=$((_quadlet_svc_count + 1))
    else
        _bare_svc_count=$((_bare_svc_count + 1))
    fi
done
if [[ $_quadlet_svc_count -gt 0 && $_bare_svc_count -gt 0 ]]; then
    _deploy_mode="mixed (podman + bare metal)"
elif [[ $_quadlet_svc_count -gt 0 ]]; then
    _deploy_mode="podman (quadlets)"
else
    _deploy_mode="bare metal"
fi

total=${#services[@]}
active=0
failed_count=0
unhealthy_count=0

declare -A svc_states=()
declare -A svc_health=()
for svc in "${services[@]}"; do
    state=$(_svc_state "$svc")
    svc_states[$svc]="$state"
    [[ "$state" == "active"  ]] && active=$((active + 1))
    [[ "$state" == "failed"  ]] && failed_count=$((failed_count + 1))

    health=$(_svc_health "$svc" "$state")
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
    printf "  %-${col}s %s\n" "deploy mode" "$_deploy_mode"

    # Network and secrets — only relevant when podman is in use
    if [[ $_quadlet_svc_count -gt 0 ]]; then
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
    fi

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
