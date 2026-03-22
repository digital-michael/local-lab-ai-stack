#!/usr/bin/env bash
set -euo pipefail

# scripts/podman/setup-worker.sh
#
# Set up an inference-worker node on Linux using Podman.
# Run this on the target machine (e.g. Alienware).
#
# It detects hardware, generates ollama + promtail quadlets for the
# inference-worker profile, pulls the recommended quantized model,
# and enables the ollama service.
#
# Prerequisites on target:
#   - Podman installed
#   - This repo cloned (or at minimum configs/config.json present)
#   - For GPU: NVIDIA CDI configured (nvidia-ctk cdi generate)
#
# Usage:
#   bash setup-worker.sh [--model <ollama-tag>] [--dry-run] [--help]
#
# Options:
#   --model <tag>   Override auto-selected model
#   --dry-run       Print what would happen without making changes
#   --help          Show this message

MODEL_OVERRIDE=""
DRY_RUN=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CONFIGURE="$PROJECT_ROOT/scripts/configure.sh"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL_OVERRIDE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h) sed -n '3,22p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

step() { echo ""; echo "==> $*"; }
info() { echo "    $*"; }
warn() { echo "    WARN: $*" >&2; }
run()  { if $DRY_RUN; then echo "    [dry-run] $*"; else "$@"; fi; }

# ---------------------------------------------------------------------------
# OS check
# ---------------------------------------------------------------------------
if [[ "$(uname -s)" != "Linux" ]]; then
    echo "ERROR: This script is for Linux only. Use scripts/bare_metal/setup-macos.sh on macOS." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
step "Checking prerequisites"
for cmd in podman curl; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done
info "Podman: $(podman --version)"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: config.json not found at $CONFIG_FILE" >&2
    echo "       Clone the repo or copy configs/config.json to this machine." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Hardware detection
# ---------------------------------------------------------------------------
step "Detecting hardware"
CPU_MODEL=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
CPU_CORES=$(nproc 2>/dev/null || echo "?")
RAM_GB=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
info "CPU:  $CPU_MODEL ($CPU_CORES cores)"
info "RAM:  ${RAM_GB} GB"

VRAM_FREE_INT=0
if command -v nvidia-smi &>/dev/null; then
    GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
    VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    VRAM_FREE=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    VRAM_TOTAL_GB=$(awk "BEGIN{printf \"%.1f\", $VRAM_TOTAL/1024}")
    VRAM_FREE_GB=$(awk "BEGIN{printf \"%.1f\", $VRAM_FREE/1024}")
    VRAM_FREE_INT=$(echo "$VRAM_FREE_GB" | cut -d. -f1)
    info "GPU:  $GPU_NAME"
    info "VRAM: ${VRAM_TOTAL_GB} GB total, ${VRAM_FREE_GB} GB free"

    if ls /etc/cdi/nvidia.yaml &>/dev/null || ls /run/cdi/nvidia.yaml &>/dev/null; then
        info "CDI:  nvidia.yaml found — GPU passthrough available"
    else
        warn "CDI not configured. GPU will not be available inside containers."
        warn "Run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    fi
else
    info "GPU:  No NVIDIA GPU detected (cpu-only inference)"
fi

# ---------------------------------------------------------------------------
# Model selection
# ---------------------------------------------------------------------------
if [[ -n "$MODEL_OVERRIDE" ]]; then
    RECOMMENDED_MODEL="$MODEL_OVERRIDE"
    info "Model: $RECOMMENDED_MODEL (user override)"
elif [[ $VRAM_FREE_INT -ge 8 ]]; then
    RECOMMENDED_MODEL="llama3.1:8b-instruct-q4_K_M"
elif [[ $VRAM_FREE_INT -ge 4 ]]; then
    RECOMMENDED_MODEL="mistral:7b-q4_K_M"
elif [[ $VRAM_FREE_INT -ge 3 ]]; then
    RECOMMENDED_MODEL="llama3.2:3b-q4_K_M"
elif [[ $RAM_GB -ge 8 ]]; then
    RECOMMENDED_MODEL="llama3.2:3b-q4_K_M"
else
    RECOMMENDED_MODEL="qwen2.5:1.5b-q8_0"
fi
info "Model: $RECOMMENDED_MODEL"

# ---------------------------------------------------------------------------
# Set node_profile = inference-worker and generate quadlets
# ---------------------------------------------------------------------------
step "Configuring as inference-worker"

# Temporarily set node_profile to inference-worker for quadlet generation
CURRENT_PROFILE=$(python3 -c "import json; print(json.load(open('$CONFIG_FILE')).get('node_profile','controller'))")
if [[ "$CURRENT_PROFILE" != "inference-worker" ]]; then
    warn "config.json node_profile is '$CURRENT_PROFILE' — generating quadlets as inference-worker"
    warn "Update config.json node_profile to 'inference-worker' on this machine if this is permanent."
    TMPCONFIG=$(mktemp /tmp/config_worker_XXXXXX.json)
    python3 -c "
import json
with open('$CONFIG_FILE') as f:
    cfg = json.load(f)
cfg['node_profile'] = 'inference-worker'
with open('$TMPCONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
"
    run env CONFIG_FILE="$TMPCONFIG" bash "$CONFIGURE" generate-quadlets
    rm -f "$TMPCONFIG"
else
    run bash "$CONFIGURE" generate-quadlets
fi
info "Quadlets generated: ollama + promtail only"

# ---------------------------------------------------------------------------
# Create required data directories
# ---------------------------------------------------------------------------
step "Creating data directories"
AI_STACK_DIR=$(python3 -c "import json,os; print(json.load(open('$CONFIG_FILE'))['ai_stack_dir'].replace('\$HOME', os.environ['HOME']))")
run mkdir -p "$AI_STACK_DIR/ollama"
run mkdir -p "$AI_STACK_DIR/models"
info "AI_STACK_DIR: $AI_STACK_DIR"

# ---------------------------------------------------------------------------
# Reload systemd and start Ollama
# ---------------------------------------------------------------------------
step "Enabling Ollama service"
run systemctl --user daemon-reload
run systemctl --user start ollama.service
info "Waiting for Ollama to be ready (up to 120s — image pull on first run)..."
for i in $(seq 1 120); do
    if curl -sf http://localhost:11434/ &>/dev/null; then
        info "Ollama ready (attempt $i)"
        break
    fi
    if [[ $i -eq 120 ]]; then
        echo "ERROR: Ollama did not become ready after 120 seconds." >&2
        echo "       Check: journalctl --user -u ollama.service -n 50" >&2
        exit 1
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# Pull model
# ---------------------------------------------------------------------------
step "Pulling model: $RECOMMENDED_MODEL"
info "This may take a while on first run..."
run podman exec ollama ollama pull "$RECOMMENDED_MODEL"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
step "Verification"
info "Ollama service:  $(systemctl --user is-active ollama.service 2>/dev/null || echo unknown)"
info "Models present:"
podman exec ollama ollama list 2>/dev/null | sed 's/^/      /' || true

echo ""
echo "==> Setup complete."
echo "    Recommended model pulled: $RECOMMENDED_MODEL"
echo ""
echo "    Next: run scripts/register-node.sh to print the config block"
echo "    for the controller's config.json, then restart LiteLLM on the controller."
