
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

_get_node_profile() {
    if [[ -f "$NODE_PROFILE_FILE" ]]; then
        local p; p=$(tr -d '[:space:]' < "$NODE_PROFILE_FILE")
        [[ -n "$p" ]] && { echo "$p"; return; }
    fi
    jq -r '.node_profile // "controller"' "$CONFIG_FILE" 2>/dev/null || echo "controller"
}

echo "Deploying AI stack..."

# Create required directories
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/configs/traefik/dynamic"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/configs/loki"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/configs/tls"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/configs/prometheus"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/configs/grafana/provisioning/datasources"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/configs/grafana/provisioning/dashboards"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/configs/promtail"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/flowise"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/openwebui"
mkdir -p "${AI_STACK_DIR:-$HOME/ai-stack}/grafana"

# Sync service configuration files from repo to AI_STACK_DIR
# (excludes config.json and generated run/ env files)
AI_STACK_CONFIGS="${AI_STACK_DIR:-$HOME/ai-stack}/configs"
cp -r "$PROJECT_ROOT/configs/traefik/." "$AI_STACK_CONFIGS/traefik/"
cp -r "$PROJECT_ROOT/configs/prometheus/." "$AI_STACK_CONFIGS/prometheus/"
cp -r "$PROJECT_ROOT/configs/loki/." "$AI_STACK_CONFIGS/loki/"
cp -r "$PROJECT_ROOT/configs/promtail/." "$AI_STACK_CONFIGS/promtail/"

# On worker nodes, repoint promtail at the controller's Loki (not local loki.ai-stack)
_node_profile=$(_get_node_profile)
if [[ "$_node_profile" != "controller" ]]; then
    _controller_addr=$(jq -r '
        .nodes[] | select(.profile == "controller") |
        .address // .address_fallback // empty
    ' "$CONFIG_FILE" 2>/dev/null | head -1)
    if [[ -n "$_controller_addr" ]]; then
        sed -i "s|http://loki\.ai-stack:3100|http://${_controller_addr}:3100|g" \
            "$AI_STACK_CONFIGS/promtail/config.yml"
        echo "  promtail: loki URL → http://${_controller_addr}:3100 (controller)"
    else
        echo "  promtail: WARNING — no controller address found; loki URL unchanged"
    fi
fi
cp -r "$PROJECT_ROOT/configs/grafana/." "$AI_STACK_CONFIGS/grafana/"
# Validate configuration
"$SCRIPT_DIR/configure.sh" validate

# Generate quadlet files from config
"$SCRIPT_DIR/configure.sh" generate-quadlets

# Create network (quadlet handles this, but ensure it exists)
podman network create ai-stack-net 2>/dev/null || echo "Network ai-stack-net already exists"

echo ""
echo "Quadlets generated. Start services with:"
echo "  systemctl --user daemon-reload"
echo "  systemctl --user start postgres.service"
echo "See docs/ai_stack_blueprint/ai_stack_implementation.md for startup order."
