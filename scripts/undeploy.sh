#!/usr/bin/env bash
# scripts/undeploy.sh — Tear down AI stack deployment
#
# Modes (select at least one):
#   --services   Stop running services and remove systemd quadlet files
#   --data       Wipe AI_STACK_DIR data directories (implies --services)
#   --hard       Remove services, data, network, and Podman secrets
#   --purge      Alias for --hard

# macOS ships bash 3.2; this script requires bash 4+ (mapfile, declare -A).
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
QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"

_detect_deploy_mode() {
    if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
        echo "podman"
    else
        echo "bare_metal"
    fi
}

# Returns "systemd" if systemctl --user is available, otherwise "none"
_detect_service_manager() {
    if command -v systemctl &>/dev/null && systemctl --user status &>/dev/null 2>&1; then
        echo "systemd"
    else
        echo "none"
    fi
}

MODE_SERVICES=false
MODE_DATA=false
MODE_HARD=false
YES=false

usage() {
    cat <<'EOF'
Usage: undeploy.sh <mode> [--yes]

Purpose:
  Tear down the AI stack. Select the desired scope of removal.

Modes (at least one required):
  --services   Stop all services and remove systemd quadlet files
  --data       Wipe $AI_STACK_DIR data directories (implies --services)
  --hard       Remove services, data, Podman network, and secrets (DESTRUCTIVE)
  --purge      Alias for --hard

Options:
  --yes, -y    Skip confirmation prompt (required for --data and --hard)
  -h, --help   Show this message

Examples:
  undeploy.sh --services             # clean teardown; data preserved
  undeploy.sh --data                 # stop + wipe data volumes (prompts first)
  undeploy.sh --hard --yes           # full wipe, no prompt

Environment:
  CONFIG_FILE   Path to config.json  (default: ./configs/config.json)
  QUADLET_DIR   Quadlet directory    (default: ~/.config/containers/systemd)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --services)      MODE_SERVICES=true ;;
        --data)          MODE_DATA=true ;;
        --hard|--purge)  MODE_HARD=true ;;
        --yes|-y)        YES=true ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
    shift
done

if ! $MODE_SERVICES && ! $MODE_DATA && ! $MODE_HARD; then
    echo "ERROR: Specify at least one mode (--services, --data, or --hard)." >&2
    echo ""
    usage >&2
    exit 1
fi

# --hard implies --data implies --services
$MODE_HARD    && MODE_DATA=true
$MODE_DATA    && MODE_SERVICES=true

# ── Prerequisites ─────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2
    exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    exit 1
fi

AI_STACK_DIR=$(jq -r '.ai_stack_dir' "$CONFIG_FILE")
AI_STACK_DIR="${AI_STACK_DIR//\$HOME/$HOME}"
NET_NAME=$(jq -r '.network.name' "$CONFIG_FILE")

# ── Backup prompt (data-destructive modes only) ───────────────────────────────
# Offer to run backup.sh before any operation that deletes data volumes.

if $MODE_DATA && [[ -d "$AI_STACK_DIR" ]]; then
    echo "WARNING: This operation will delete data under $AI_STACK_DIR."
    echo "         Chat history, user accounts, and knowledge indexes will be lost"
    echo "         unless backed up first."
    echo ""
    if $YES; then
        echo "NOTICE: --yes passed — skipping backup prompt. Running backup automatically..."
        "$SCRIPT_DIR/backup.sh" || echo "WARN: backup.sh exited non-zero — review output above before proceeding."
        echo ""
    else
        read -rp "Run backup.sh now before undeploying? [Y/n] " bk_answer
        case "${bk_answer:-Y}" in
            [Yy]*|"")
                "$SCRIPT_DIR/backup.sh" || {
                    echo ""
                    echo "ERROR: backup.sh failed. Aborting undeploy to protect data."
                    echo "       Fix the backup issue or re-run with --yes to skip backup."
                    exit 1
                }
                echo ""
                ;;
            *)
                echo "Backup skipped. Proceeding without backup — data will be permanently deleted."
                echo ""
                ;;
        esac
    fi
fi

# ── Confirmation prompt ───────────────────────────────────────────────────────

if ! $YES; then
    echo "This will:"
    $MODE_SERVICES && echo "  - Stop all services and remove quadlet files from $QUADLET_DIR"
    $MODE_DATA     && echo "  - DELETE all data volumes under $AI_STACK_DIR"
    $MODE_HARD     && echo "  - Remove Podman network '$NET_NAME' and all Podman secrets"
    echo ""
    read -rp "Proceed? [y/N] " answer
    case "$answer" in
        [Yy]*) ;;
        *) echo "Aborted."; exit 0 ;;
    esac
fi

# ── Stop services ─────────────────────────────────────────────────────────────

if $MODE_SERVICES; then
    deploy_check=0
    "$SCRIPT_DIR/status.sh" --check --quiet 2>/dev/null || deploy_check=$?

    _deploy_mode=$(_detect_deploy_mode)
    _svc_mgr=$(_detect_service_manager)

    if [[ "$_deploy_mode" == "podman" ]]; then
        if [[ $deploy_check -ne 2 ]]; then
            echo "Stopping services..."
            mapfile -t services < <(jq -r '.services | keys[]' "$CONFIG_FILE")
            for svc in "${services[@]}"; do
                if [[ "$_svc_mgr" == "systemd" ]]; then
                    systemctl --user stop "${svc}.service" 2>/dev/null || true
                else
                    podman stop "$svc" 2>/dev/null || true
                fi
            done
            echo "Services stopped."
        else
            echo "No running services found — skipping stop."
        fi
        echo "Removing quadlet files from $QUADLET_DIR ..."
        find "$QUADLET_DIR" -maxdepth 1 \( -name "*.container" -o -name "ai-stack.network" \) \
            -delete 2>/dev/null || true
        if [[ "$_svc_mgr" == "systemd" ]]; then
            systemctl --user daemon-reload
        fi
        echo "Quadlets removed."
    else
        # Bare-metal: unload and remove native service files
        _os=$(uname -s)
        if [[ "$_os" == "Darwin" ]]; then
            _plist="$HOME/Library/LaunchAgents/com.ai-stack.promtail.plist"
            if [[ -f "$_plist" ]]; then
                launchctl unload "$_plist" 2>/dev/null || true
                rm -f "$_plist"
                echo "  Removed launchd plist: $_plist"
            else
                echo "  No promtail plist found — skipping."
            fi
        else
            _unit="$HOME/.config/systemd/user/promtail.service"
            if [[ -f "$_unit" ]]; then
                systemctl --user stop promtail.service 2>/dev/null || true
                systemctl --user disable promtail.service 2>/dev/null || true
                rm -f "$_unit"
                systemctl --user daemon-reload
                echo "  Removed systemd unit: $_unit"
            else
                echo "  No promtail unit found — skipping."
            fi
        fi
    fi
fi

# ── Wipe data volumes ─────────────────────────────────────────────────────────

if $MODE_DATA; then
    if [[ ! -d "$AI_STACK_DIR" ]]; then
        echo "AI_STACK_DIR=$AI_STACK_DIR not found — skipping data wipe."
    else
        echo "Wiping data volumes under $AI_STACK_DIR ..."
        for subdir in postgres qdrant grafana flowise openwebui ollama libraries logs; do
            target="${AI_STACK_DIR}/${subdir}"
            if [[ -d "$target" ]]; then
                rm -rf "$target"
                echo "  Removed $target"
            fi
        done
        echo "Data volumes removed."
    fi
fi

# ── Hard: network + secrets ───────────────────────────────────────────────────

if $MODE_HARD; then
    if [[ "$(_detect_deploy_mode)" == "podman" ]]; then
        echo "Removing Podman network '$NET_NAME' ..."
        if podman network rm "$NET_NAME" 2>/dev/null; then
            echo "  Network removed."
        else
            echo "  Network not found — skipping."
        fi

        echo "Removing Podman secrets ..."
        mapfile -t secrets < <(jq -r '[.services[].secrets[]?.name] | unique[]' "$CONFIG_FILE" 2>/dev/null || true)
        for secret in "${secrets[@]}"; do
            if [[ -z "$secret" ]]; then continue; fi
            if podman secret rm "$secret" 2>/dev/null; then
                echo "  Removed secret: $secret"
            else
                echo "  Not found: $secret — skipping"
            fi
        done
    else
        echo "Bare-metal node — no Podman network or secrets to remove."
    fi
fi

echo ""
echo "Undeploy complete."
