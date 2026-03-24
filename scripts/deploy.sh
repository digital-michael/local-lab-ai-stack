
#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Purpose:
  Deploy the AI stack by validating configuration, generating systemd quadlet
  files, and creating the Podman network. After running, reload systemd and
  start services manually.

Options:
  -h, --help    Show this help message and exit

Examples:
  $(basename "$0")
  $(basename "$0") --help
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"
NODE_PROFILE_FILE="${NODE_PROFILE_FILE:-$PROJECT_ROOT/configs/node_profile}"
AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
AI_STACK_CONFIGS="$AI_STACK_DIR/configs"

_get_node_profile() {
    if [[ -f "$NODE_PROFILE_FILE" ]]; then
        local p; p=$(tr -d '[:space:]' < "$NODE_PROFILE_FILE")
        [[ -n "$p" ]] && { echo "$p"; return; }
    fi
    jq -r '.node_profile // "controller"' "$CONFIG_FILE" 2>/dev/null || echo "controller"
}

# Returns "podman" or "bare_metal".
# Darwin (macOS) cannot run systemd quadlets — always bare_metal regardless of Podman.
_detect_deploy_mode() {
    if [[ "$(uname -s)" == "Darwin" ]]; then
        echo "bare_metal"
        return
    fi
    if command -v podman &>/dev/null && podman info &>/dev/null 2>&1; then
        echo "podman"
    else
        echo "bare_metal"
    fi
}

# Write a native promtail service file appropriate for the current OS.
# $1 = path to the deployed promtail config.yml
_setup_promtail_native() {
    local config_path="$1"
    local promtail_bin=""
    for _p in /opt/homebrew/bin/promtail /usr/local/bin/promtail /usr/bin/promtail; do
        [[ -x "$_p" ]] && { promtail_bin="$_p"; break; }
    done

    if [[ -z "$promtail_bin" ]]; then
        echo "  promtail: WARNING — binary not found; service file not written"
        echo "    macOS:  brew install promtail"
        echo "    Linux:  https://github.com/grafana/loki/releases"
        return
    fi

    mkdir -p "$AI_STACK_DIR/logs"
    local os; os=$(uname -s)

    if [[ "$os" == "Darwin" ]]; then
        local plist="$HOME/Library/LaunchAgents/com.ai-stack.promtail.plist"
        mkdir -p "$HOME/Library/LaunchAgents"
        cat > "$plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>             <string>com.ai-stack.promtail</string>
  <key>ProgramArguments</key>
  <array>
    <string>$promtail_bin</string>
    <string>-config.file=$config_path</string>
  </array>
  <key>RunAtLoad</key>         <true/>
  <key>KeepAlive</key>         <true/>
  <key>StandardOutPath</key>   <string>$AI_STACK_DIR/logs/promtail.log</string>
  <key>StandardErrorPath</key> <string>$AI_STACK_DIR/logs/promtail.err</string>
</dict>
</plist>
EOF
        echo "  promtail: launchd plist → $plist"
        echo "  promtail: to start:"
        echo "      launchctl load $plist"
    else
        local unit_dir="$HOME/.config/systemd/user"
        mkdir -p "$unit_dir"
        cat > "$unit_dir/promtail.service" <<EOF
[Unit]
Description=Promtail log shipper (AI Stack)
After=network.target

[Service]
ExecStart=$promtail_bin -config.file=$config_path
Restart=on-failure
RestartSec=5
StandardOutput=append:$AI_STACK_DIR/logs/promtail.log
StandardError=append:$AI_STACK_DIR/logs/promtail.err

[Install]
WantedBy=default.target
EOF
        echo "  promtail: systemd unit → $unit_dir/promtail.service"
        echo "  promtail: to start:"
        echo "      systemctl --user daemon-reload"
        echo "      systemctl --user enable --now promtail.service"
    fi
}

# ── Main ──────────────────────────────────────────────────────────────────────

NODE_PROFILE=$(_get_node_profile)
DEPLOY_MODE=$(_detect_deploy_mode)

echo "Deploying AI stack..."
echo "  node profile: $NODE_PROFILE"
echo "  deploy mode:  $DEPLOY_MODE"
echo ""

# ── Common: promtail config (all profiles, all deploy modes) ──────────────────

mkdir -p "$AI_STACK_CONFIGS/promtail"
mkdir -p "$AI_STACK_DIR/logs"
cp -r "$PROJECT_ROOT/configs/promtail/." "$AI_STACK_CONFIGS/promtail/"

# On worker nodes, repoint promtail at the controller's Loki (not local loki.ai-stack)
if [[ "$NODE_PROFILE" != "controller" ]]; then
    _nodes_dir="$(dirname "$CONFIG_FILE")/nodes"
    _controller_addr=$(for _f in "$_nodes_dir"/*.json; do [[ -f "$_f" ]] && jq -r 'select(.profile == "controller") | .address // .address_fallback // empty' "$_f"; done 2>/dev/null | head -1 || true)
    if [[ -n "$_controller_addr" ]]; then
        # sed -i.bak is portable across macOS (requires suffix) and Linux
        sed -i.bak "s|http://loki\.ai-stack:3100|http://${_controller_addr}:3100|g" \
            "$AI_STACK_CONFIGS/promtail/config.yml"
        rm -f "$AI_STACK_CONFIGS/promtail/config.yml.bak"
        echo "  promtail: loki URL → http://${_controller_addr}:3100 (controller)"
    else
        echo "  promtail: WARNING — no controller address found; loki URL unchanged"
    fi
fi

# ── Podman path: quadlets + network ───────────────────────────────────────────

if [[ "$DEPLOY_MODE" == "podman" ]]; then
    mkdir -p "$AI_STACK_CONFIGS/traefik/dynamic"
    mkdir -p "$AI_STACK_CONFIGS/loki"
    mkdir -p "$AI_STACK_CONFIGS/tls"
    mkdir -p "$AI_STACK_CONFIGS/prometheus"
    mkdir -p "$AI_STACK_CONFIGS/grafana/provisioning/datasources"
    mkdir -p "$AI_STACK_CONFIGS/grafana/provisioning/dashboards"
    mkdir -p "$AI_STACK_DIR/flowise"
    mkdir -p "$AI_STACK_DIR/openwebui"
    mkdir -p "$AI_STACK_DIR/grafana"

    cp -r "$PROJECT_ROOT/configs/traefik/."    "$AI_STACK_CONFIGS/traefik/"
    cp -r "$PROJECT_ROOT/configs/prometheus/." "$AI_STACK_CONFIGS/prometheus/"
    cp -r "$PROJECT_ROOT/configs/loki/."       "$AI_STACK_CONFIGS/loki/"
    cp -r "$PROJECT_ROOT/configs/grafana/."    "$AI_STACK_CONFIGS/grafana/"

    "$SCRIPT_DIR/configure.sh" validate
    "$SCRIPT_DIR/configure.sh" generate-quadlets

    podman network create ai-stack-net 2>/dev/null || echo "Network ai-stack-net already exists"

    echo ""
    echo "Quadlets generated. Start services with:"
    echo "  systemctl --user daemon-reload"
    echo "  systemctl --user start <service>.service"
    echo "See docs/ai_stack_blueprint/ai_stack_implementation.md for startup order."

# ── Bare-metal path: native service files ─────────────────────────────────────

else
    _setup_promtail_native "$AI_STACK_CONFIGS/promtail/config.yml"

    echo ""
    echo "Bare-metal deployment configured."
    echo "Ensure ollama is running:  ollama serve"
    echo "Logs:  $AI_STACK_DIR/logs/"
fi
