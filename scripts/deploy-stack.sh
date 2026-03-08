
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

echo "Deploying AI stack..."

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
