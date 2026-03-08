
#!/usr/bin/env bash
set -uo pipefail

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Purpose:
  Validate that the host environment meets the prerequisites for the AI stack:
  Podman installation, optional GPU availability, and storage directory existence.

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

ERRORS=0

echo "Validating environment..."

if ! command -v podman &>/dev/null; then
    echo "ERROR: Podman not installed"
    ERRORS=$((ERRORS + 1))
else
    echo "OK: $(podman --version)"
fi

if ! command -v nvidia-smi &>/dev/null; then
    echo "WARN: nvidia-smi not found (GPU node features unavailable)"
else
    echo "OK: GPU detected — $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
fi

AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
if [[ ! -d "$AI_STACK_DIR" ]]; then
    echo "ERROR: AI_STACK_DIR=$AI_STACK_DIR does not exist (run install.sh first)"
    ERRORS=$((ERRORS + 1))
else
    echo "OK: Storage directory exists at $AI_STACK_DIR"
fi

if [[ $ERRORS -gt 0 ]]; then
    echo "Validation FAILED with $ERRORS error(s)."
    exit 1
fi

echo "Validation passed."
