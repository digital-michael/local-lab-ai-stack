
#!/usr/bin/env bash
set -e
echo "Deploying AI stack..."
podman network create ai-stack-net || true
echo "Containers will start via quadlets."
