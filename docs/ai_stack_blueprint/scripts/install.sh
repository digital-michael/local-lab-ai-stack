
#!/usr/bin/env bash
set -e
echo "Installing dependencies..."
sudo dnf install -y podman git python3
sudo mkdir -p /opt/ai-stack/{models,libraries,qdrant,postgres,logs,configs,scripts,backups}
echo "Install complete."
