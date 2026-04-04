#!/usr/bin/env bash
# scripts/stop.sh — Stop all AI stack services via systemd user units
#
# Stops services in reverse dependency order (dependents before dependencies).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"

usage() {
    cat <<'EOF'
Usage: stop.sh [options]

Purpose:
  Stop all AI stack services via systemd user units in reverse dependency order.

Options:
  -h, --help    Show this message

Environment:
  CONFIG_FILE   Path to config.json  (default: ./configs/config.json)
  QUADLET_DIR   Quadlet directory    (default: ~/.config/containers/systemd)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# ── Deployment check via status.sh ────────────────────────────────────────────

deploy_check=0
"$SCRIPT_DIR/status.sh" --check --quiet 2>/dev/null || deploy_check=$?

if [[ $deploy_check -eq 2 ]]; then
    echo "Stack is not deployed — nothing to stop."
    exit 0
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2
    exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    exit 1
fi

# ── Build stop list (reverse topological order from config.json) ──────────────

declare -A _visited=()
start_order=()

_topo_visit() {
    local svc="$1"
    if [[ -v _visited[$svc] ]]; then return; fi
    _visited[$svc]=1
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        _topo_visit "$dep"
    done < <(jq -r --arg s "$svc" '.services[$s].depends_on[]?' "$CONFIG_FILE" 2>/dev/null || true)
    start_order+=("$svc")
}

while IFS= read -r svc; do
    _topo_visit "$svc"
done < <(jq -r '.services | keys[]' "$CONFIG_FILE")

# Reverse for stop order (dependents first)
stop_order=()
for (( i=${#start_order[@]}-1; i>=0; i-- )); do
    stop_order+=("${start_order[$i]}")
done

total=${#stop_order[@]}

# ── Stop services ─────────────────────────────────────────────────────────────

echo "Stopping AI stack ($total services)..."
echo ""

for svc in "${stop_order[@]}"; do
    printf "  Stopping %-20s" "$svc"
    if systemctl --user stop "${svc}.service" 2>/dev/null; then
        echo " OK"
    else
        echo " (not running)"
    fi
done

echo ""
echo "All services stopped."
echo ""
echo "Run 'bash scripts/status.sh' to verify."

# ── Sleep inhibitor ───────────────────────────────────────────────────────────
"$SCRIPT_DIR/inhibit.sh" stop || true
