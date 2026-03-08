
#!/usr/bin/env bash
set -euo pipefail

AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Purpose:
  Install system dependencies (podman, git, python3) and create the AI stack
  storage layout under \$AI_STACK_DIR.

Options:
  -h, --help    Show this help message and exit

Environment:
  AI_STACK_DIR  Base directory for the stack (default: \$HOME/ai-stack)

Examples:
  $(basename "$0")
  AI_STACK_DIR=/opt/ai-stack $(basename "$0")
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

echo "Installing dependencies..."
sudo dnf install -y podman git python3

echo "Creating storage layout at $AI_STACK_DIR..."
mkdir -p "$AI_STACK_DIR"/{models,libraries,qdrant,postgres,flowise,openwebui,grafana,backups}
mkdir -p "$AI_STACK_DIR"/logs/loki
mkdir -p "$AI_STACK_DIR"/configs/{traefik/dynamic,loki,tls,run,prometheus,grafana,promtail}

echo "Install complete. AI_STACK_DIR=$AI_STACK_DIR"
