#!/usr/bin/env bash
# scripts/start.sh — Start all AI stack services via systemd user units
#
# Checks that the stack is deployed (quadlet files present) before starting.
# If not deployed, offers to run deploy.sh first.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"
QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"

YES=false

usage() {
    cat <<'EOF'
Usage: start.sh [options]

Purpose:
  Start all AI stack services via systemd user units in dependency order.
  Detects whether the stack has been deployed; if not, offers to run deploy.sh.

Options:
  --yes, -y     Auto-confirm any prompts (e.g., run deploy.sh if not deployed)
  -h, --help    Show this message

Environment:
  CONFIG_FILE   Path to config.json  (default: ./configs/config.json)
  QUADLET_DIR   Quadlet directory    (default: ~/.config/containers/systemd)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes|-y)  YES=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

# ── Prerequisites ─────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2
    exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    exit 1
fi

# ── Deployment check via status.sh ────────────────────────────────────────────

deploy_check=0
"$SCRIPT_DIR/status.sh" --check --quiet 2>/dev/null || deploy_check=$?

if [[ $deploy_check -eq 2 ]]; then
    echo "Stack is not deployed — no quadlet files found in $QUADLET_DIR"
    echo ""
    if $YES; then
        echo "Running bash scripts/deploy.sh (--yes passed)..."
        "$SCRIPT_DIR/deploy.sh"
    else
        read -rp "Run deploy.sh now? [y/N] " answer
        case "$answer" in
            [Yy]*) "$SCRIPT_DIR/deploy.sh" ;;
            *)     echo "Aborted. Run: $SCRIPT_DIR/deploy.sh"; exit 1 ;;
        esac
    fi
fi

# ── Build start list (topological order from config.json) ────────────────────

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

total=${#start_order[@]}

# ── Start services ────────────────────────────────────────────────────────────

echo "Starting AI stack ($total services)..."
echo ""
systemctl --user daemon-reload

failed=0
for svc in "${start_order[@]}"; do
    printf "  Starting %-20s" "$svc"
    if systemctl --user start "${svc}.service" 2>/dev/null; then
        echo " OK"
    else
        echo " FAILED"
        failed=$((failed + 1))
    fi
done

echo ""
if [[ $failed -eq 0 ]]; then
    echo "All $total services started."
else
    echo "WARNING: $failed service(s) failed to start."
    echo "Check with: systemctl --user status <service>.service"
fi
echo ""
echo "Run 'bash scripts/status.sh' for a health summary."
echo ""
echo "First deployment? Run the following to detect and fix integration issues"
echo "(OpenWebUI DB Ollama URL, API key alignment, etc.):"
echo "  bash scripts/diagnose.sh --profile full --fix"

# ── Sleep inhibitor ───────────────────────────────────────────────────────────
"$SCRIPT_DIR/inhibit.sh" start || true
