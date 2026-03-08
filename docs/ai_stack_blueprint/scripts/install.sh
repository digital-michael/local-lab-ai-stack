
#!/usr/bin/env bash
set -euo pipefail

AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"

echo "Installing dependencies..."
sudo dnf install -y podman git python3

echo "Creating storage layout at $AI_STACK_DIR..."
mkdir -p "$AI_STACK_DIR"/{models,libraries,qdrant,postgres,logs,configs,scripts,backups}

echo "Install complete. AI_STACK_DIR=$AI_STACK_DIR"
