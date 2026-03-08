
#!/usr/bin/env bash
set -euo pipefail

echo "Deploying AI stack..."

podman network create ai-stack-net 2>/dev/null || echo "Network ai-stack-net already exists"

echo "Network ready. Deploy containers using quadlet unit files."
echo "See ai_stack_implementation.md for quadlet definitions and service startup order."
