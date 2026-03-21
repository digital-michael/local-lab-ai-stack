#!/usr/bin/env bash
set -euo pipefail

# scripts/bare_metal/setup-macos.sh
#
# Set up bare-metal Ollama on macOS (Apple Silicon) as an inference worker.
# Run this on the target Mac — it installs Ollama via Homebrew, detects
# hardware to select the right quantized model, pulls it, and configures
# a LaunchAgent so Ollama starts on login and listens on 0.0.0.0:11434.
#
# Usage:
#   bash setup-macos.sh [--model <ollama-tag>] [--help]
#
# Options:
#   --model <tag>   Override the auto-selected model (e.g. llama3.1:8b-instruct-q4_K_M)
#   --dry-run       Print what would happen without making changes
#   --help          Show this message
#
# Environment:
#   OLLAMA_HOST     Override listen address (default: 0.0.0.0:11434)

OLLAMA_HOST_ADDR="${OLLAMA_HOST:-0.0.0.0:11434}"
LAUNCHAGENT_LABEL="com.ollama.server"
LAUNCHAGENT_PLIST="$HOME/Library/LaunchAgents/${LAUNCHAGENT_LABEL}.plist"
MODEL_OVERRIDE=""
DRY_RUN=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --model) MODEL_OVERRIDE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            sed -n '3,14p' "$0"
            exit 0
            ;;
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
if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "ERROR: This script is for macOS only." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Hardware detection
# ---------------------------------------------------------------------------
step "Detecting hardware"
RAM_BYTES=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
RAM_GB=$(( RAM_BYTES / 1073741824 ))
IS_ARM64=$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)
CPU_MODEL=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
CPU_CORES=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "?")

info "CPU:  $CPU_MODEL ($CPU_CORES cores)"
info "RAM:  ${RAM_GB} GB unified"
if [[ "$IS_ARM64" == "1" ]]; then
    info "GPU:  Apple Silicon (Metal — shared unified memory)"
else
    info "GPU:  Intel/x86 Mac"
    warn "Metal GPU acceleration unavailable on Intel Macs — inference will be CPU-only."
fi

# Auto-select model tier (~40% of unified RAM as soft target)
TARGET_GB=$(( RAM_GB * 40 / 100 ))
if [[ -n "$MODEL_OVERRIDE" ]]; then
    RECOMMENDED_MODEL="$MODEL_OVERRIDE"
    info "Model: $RECOMMENDED_MODEL (user override)"
elif [[ $TARGET_GB -ge 8 ]]; then
    RECOMMENDED_MODEL="llama3.1:8b-instruct-q4_K_M"
    info "Model: $RECOMMENDED_MODEL (target ${TARGET_GB} GB of ${RAM_GB} GB)"
elif [[ $TARGET_GB -ge 5 ]]; then
    RECOMMENDED_MODEL="llama3.1:8b-instruct-q4_K_M"
    info "Model: $RECOMMENDED_MODEL (tight fit — Ollama may page; target ${TARGET_GB} GB of ${RAM_GB} GB)"
elif [[ $TARGET_GB -ge 3 ]]; then
    RECOMMENDED_MODEL="llama3.2:3b-q4_K_M"
    info "Model: $RECOMMENDED_MODEL (target ${TARGET_GB} GB of ${RAM_GB} GB)"
else
    RECOMMENDED_MODEL="qwen2.5:1.5b-q8_0"
    info "Model: $RECOMMENDED_MODEL (low RAM — target ${TARGET_GB} GB of ${RAM_GB} GB)"
fi

# ---------------------------------------------------------------------------
# Homebrew check
# ---------------------------------------------------------------------------
step "Checking Homebrew"
if ! command -v brew &>/dev/null; then
    echo "ERROR: Homebrew not found. Install from https://brew.sh then re-run this script." >&2
    exit 1
fi
info "Homebrew: $(brew --version | head -1)"

# ---------------------------------------------------------------------------
# Install / upgrade Ollama
# ---------------------------------------------------------------------------
step "Installing Ollama"
if brew list --cask ollama &>/dev/null 2>&1; then
    info "Ollama cask already installed — upgrading if needed"
    run brew upgrade --cask ollama 2>/dev/null || info "Already up to date"
elif brew list ollama &>/dev/null 2>&1; then
    info "Ollama formula already installed — upgrading if needed"
    run brew upgrade ollama 2>/dev/null || info "Already up to date"
else
    info "Installing Ollama..."
    # Try cask first (GUI app bundle with CLI), fall back to formula
    if run brew install --cask ollama; then
        info "Installed via cask"
    else
        run brew install ollama
        info "Installed via formula"
    fi
fi

# Locate ollama binary
OLLAMA_BIN=""
for candidate in /opt/homebrew/bin/ollama /usr/local/bin/ollama /Applications/Ollama.app/Contents/Resources/ollama; do
    if [[ -x "$candidate" ]]; then
        OLLAMA_BIN="$candidate"
        break
    fi
done
if [[ -z "$OLLAMA_BIN" ]]; then
    OLLAMA_BIN=$(command -v ollama 2>/dev/null || true)
fi
if [[ -z "$OLLAMA_BIN" ]]; then
    echo "ERROR: ollama binary not found after install. Check PATH or Homebrew output." >&2
    exit 1
fi
info "Binary: $OLLAMA_BIN ($(${OLLAMA_BIN} --version 2>/dev/null || echo 'version unknown'))"

# ---------------------------------------------------------------------------
# LaunchAgent — Ollama server on 0.0.0.0:11434
# ---------------------------------------------------------------------------
step "Configuring LaunchAgent ($LAUNCHAGENT_LABEL)"
mkdir -p "$HOME/Library/LaunchAgents"

# Stop existing agent if running
if launchctl list | grep -q "$LAUNCHAGENT_LABEL" 2>/dev/null; then
    info "Stopping existing LaunchAgent..."
    run launchctl unload "$LAUNCHAGENT_PLIST" 2>/dev/null || true
fi

if ! $DRY_RUN; then
cat > "$LAUNCHAGENT_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LAUNCHAGENT_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>${OLLAMA_BIN}</string>
        <string>serve</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>OLLAMA_HOST</key>
        <string>${OLLAMA_HOST_ADDR}</string>
    </dict>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${HOME}/Library/Logs/ollama.log</string>
    <key>StandardErrorPath</key>
    <string>${HOME}/Library/Logs/ollama.log</string>
</dict>
</plist>
EOF
fi
info "Plist: $LAUNCHAGENT_PLIST"
info "OLLAMA_HOST=$OLLAMA_HOST_ADDR"

run launchctl load -w "$LAUNCHAGENT_PLIST"

# Give Ollama a moment to start
step "Waiting for Ollama to be ready"
for i in $(seq 1 20); do
    if curl -sf http://localhost:11434/ &>/dev/null; then
        info "Ollama is ready (attempt $i)"
        break
    fi
    if [[ $i -eq 20 ]]; then
        echo "ERROR: Ollama did not become ready after 20 seconds." >&2
        echo "       Check logs: tail -f ~/Library/Logs/ollama.log" >&2
        exit 1
    fi
    sleep 1
done

# ---------------------------------------------------------------------------
# Pull recommended model
# ---------------------------------------------------------------------------
step "Pulling model: $RECOMMENDED_MODEL"
info "This may take a while on first run (downloading model weights)..."
run "$OLLAMA_BIN" pull "$RECOMMENDED_MODEL"

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
step "Verification"
info "Ollama version: $("$OLLAMA_BIN" --version 2>/dev/null || echo 'unknown')"
info "Listening on:   $OLLAMA_HOST_ADDR"
info "Models present:"
"$OLLAMA_BIN" list 2>/dev/null | sed 's/^/      /' || true
echo ""
info "LaunchAgent loaded: $(launchctl list | grep "$LAUNCHAGENT_LABEL" || echo 'NOT FOUND')"

echo ""
echo "==> Setup complete."
echo "    Ollama is listening on $OLLAMA_HOST_ADDR"
echo "    Model pulled: $RECOMMENDED_MODEL"
echo ""
echo "    Next: run scripts/register-node.sh to print the config block"
echo "    for the controller's config.json."
