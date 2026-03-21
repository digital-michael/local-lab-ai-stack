#!/usr/bin/env bash
set -euo pipefail

# scripts/register-node.sh
#
# Run this ON the remote node (M1, Alienware, etc.) after Ollama is set up.
# It introspects the local environment and prints a config block the operator
# can paste into the controller's config.json nodes[] and models[].
#
# No automatic writes are made to the controller (static config model, per D-020).
#
# Usage:
#   bash register-node.sh [--name <node-name>] [--help]
#
# Options:
#   --name <name>   Override the suggested node name in the printed config
#   --help          Show this message

NODE_NAME_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) NODE_NAME_OVERRIDE="$2"; shift 2 ;;
        --help|-h) sed -n '3,14p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Hardware detection
# ---------------------------------------------------------------------------
OS=$(uname -s)
ARCH=$(uname -m)

if [[ "$OS" == "Darwin" ]]; then
    RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
    RAM_GB=$(( RAM_BYTES / 1073741824 ))
    IS_ARM64=$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)
    CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
    DEPLOYMENT="bare_metal"
    NODE_OS="darwin"
    if [[ "$IS_ARM64" == "1" ]]; then
        GPU_SUMMARY="Apple Silicon (Metal)"
    else
        GPU_SUMMARY="Intel Mac (CPU-only)"
    fi
else
    RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
    CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
    if command -v nvidia-smi &>/dev/null; then
        GPU_SUMMARY=$(nvidia-smi --query-gpu=name,memory.total --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    else
        GPU_SUMMARY="CPU-only (no nvidia-smi)"
    fi
    DEPLOYMENT="podman"
    NODE_OS="linux"
fi

HOSTNAME_SHORT=$(hostname -s 2>/dev/null || hostname)

# ---------------------------------------------------------------------------
# Suggest node name
# ---------------------------------------------------------------------------
if [[ -n "$NODE_NAME_OVERRIDE" ]]; then
    SUGGESTED_NAME="$NODE_NAME_OVERRIDE"
else
    # Lowercase, strip domain, replace non-alphanumeric with -
    SUGGESTED_NAME=$(echo "$HOSTNAME_SHORT" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')
fi

# ---------------------------------------------------------------------------
# Probe Ollama
# ---------------------------------------------------------------------------
echo ""
echo "=== Node Registration Probe ==="
echo ""
echo "Hostname:    $HOSTNAME_SHORT"
echo "OS:          $OS / $ARCH"
echo "CPU:         $CPU_MODEL"
echo "RAM:         ${RAM_GB} GB"
echo "GPU:         $GPU_SUMMARY"
echo ""

OLLAMA_OK=false
MODELS_JSON=""
if curl -sf http://localhost:11434/api/tags &>/dev/null; then
    OLLAMA_OK=true
    MODELS_JSON=$(curl -sf http://localhost:11434/api/tags 2>/dev/null)
    echo "Ollama:      RUNNING on localhost:11434"
    MODEL_NAMES=$(echo "$MODELS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
for m in data.get('models', []):
    print('  -', m['name'])
" 2>/dev/null || echo "  (could not parse)")
    echo "Models:"
    echo "$MODEL_NAMES"
else
    echo "Ollama:      NOT RUNNING or not reachable on localhost:11434"
    echo "             Start with: ollama serve (or via LaunchAgent / systemd)"
fi
echo ""

# Build models[] list for config block
MODEL_LIST="[]"
if $OLLAMA_OK; then
    MODEL_LIST=$(echo "$MODELS_JSON" | python3 -c "
import json, sys
data = json.load(sys.stdin)
names = [m['name'] for m in data.get('models', [])]
print(json.dumps(names))
" 2>/dev/null || echo "[]")
fi

# ---------------------------------------------------------------------------
# Resolve outbound address candidates
# ---------------------------------------------------------------------------
# Try to find the primary LAN IP the controller might use to reach this node
PRIMARY_IP=""
if [[ "$OS" == "Darwin" ]]; then
    PRIMARY_IP=$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || echo "")
else
    PRIMARY_IP=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '/src/{print $NF}' | head -1 || hostname -I 2>/dev/null | awk '{print $1}' || echo "")
fi
FQDN=$(hostname -f 2>/dev/null || echo "")

echo "Network:"
[[ -n "$FQDN" ]]       && echo "  FQDN:    $FQDN"
[[ -n "$PRIMARY_IP" ]] && echo "  LAN IP:  $PRIMARY_IP"
echo ""

# ---------------------------------------------------------------------------
# Print config block
# ---------------------------------------------------------------------------
ADDRESS_VALUE="null"
FALLBACK_VALUE="null"
if [[ -n "$FQDN" && "$FQDN" != "$HOSTNAME_SHORT" ]]; then
    ADDRESS_VALUE="\"${FQDN}\""
    [[ -n "$PRIMARY_IP" ]] && FALLBACK_VALUE="\"${PRIMARY_IP}\""
elif [[ -n "$PRIMARY_IP" ]]; then
    ADDRESS_VALUE="\"${PRIMARY_IP}\""
fi

cat <<EOF
=== Paste into controller config.json nodes[] ===

{
  "name": "${SUGGESTED_NAME}",
  "profile": "inference-worker",
  "address": ${ADDRESS_VALUE},
  "address_fallback": ${FALLBACK_VALUE},
  "os": "${NODE_OS}",
  "deployment": "${DEPLOYMENT}",
  "models": ${MODEL_LIST}
}

=== Paste into controller config.json models[] (one entry per model) ===

EOF

if $OLLAMA_OK; then
    echo "$MODELS_JSON" | python3 -c "
import json, sys
node_name = '${SUGGESTED_NAME}'
data = json.load(sys.stdin)
for m in data.get('models', []):
    print(json.dumps({
        'name': m['name'],
        'backend': 'ollama',
        'device': 'gpu',
        'host': node_name
    }, indent=2))
    print(',')
" 2>/dev/null || echo "(no models found)"
else
    echo "(Ollama not running — start it first then re-run this script)"
fi

echo ""
echo "==> After updating config.json on the controller, run:"
echo "    bash scripts/configure.sh generate-litellm-config"
echo "    systemctl --user restart litellm.service"
