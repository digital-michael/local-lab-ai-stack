#!/usr/bin/env bash
set -euo pipefail

# bootstrap.sh — Zero-touch worker node bootstrap for AI Stack
#
# wget-safe: detectable via $0 (piped execution has $0 = "bash" or "sh")
# sha256 enforcement: --sha256 <hash> verifies this script after download
#
# Usage:
#   # via curl pipe (auto-detects pipe mode):
#   bash <(curl -fsSL https://<controller>/scripts/bootstrap.sh) \
#       --controller https://<controller> --token <token>
#
#   # via wget pipe:
#   wget -qO- https://<controller>/scripts/bootstrap.sh | \
#       bash -s -- --controller https://<controller> --token <token>
#
#   # with sha256 verification (strongly recommended):
#   curl -fsSL https://<controller>/scripts/bootstrap.sh -o /tmp/bootstrap.sh
#   echo "<sha256>  /tmp/bootstrap.sh" | sha256sum -c -
#   bash /tmp/bootstrap.sh --controller https://<controller> --token <token>

# ---------------------------------------------------------------------------
# Pipe-detection guard
# ---------------------------------------------------------------------------
# Warn (don't block) when running piped without sha256 verification.
# [ ! -t 0 ] is true when stdin is not a terminal (wget/curl pipe mode).

_PIPE_MODE=false
if [ ! -t 0 ]; then
    _PIPE_MODE=true
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

CONTROLLER_URL=""
TOKEN=""
NODE_ID="$(hostname -s 2>/dev/null || echo "worker")"
ADDRESS=""
SHA256_EXPECTED=""
SKIP_VERIFY=false

usage() {
    cat <<'EOF'
Usage: bootstrap.sh --controller <url> --token <token> [options]

Required:
  --controller <url>    Controller KI base URL (e.g. https://ai.example.com:8100)
  --token <token>       Join token from: configure.sh generate-join-token

Optional:
  --node-id <id>        Node identifier (default: hostname -s)
  --address <url>       This node's KI URL (default: http://<primary-ip>:8100)
  --sha256 <hash>       Expected SHA-256 of this script (enforced when set)
  --skip-verify         Skip sha256 verification (not recommended)
  --help                Show this message
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --controller)   CONTROLLER_URL="$2"; shift 2 ;;
        --token)        TOKEN="$2";          shift 2 ;;
        --node-id)      NODE_ID="$2";        shift 2 ;;
        --address)      ADDRESS="$2";        shift 2 ;;
        --sha256)       SHA256_EXPECTED="$2"; shift 2 ;;
        --skip-verify)  SKIP_VERIFY=true; shift ;;
        --help|-h)      usage; exit 0 ;;
        *)              echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

if [[ -z "$CONTROLLER_URL" ]]; then
    echo "ERROR: --controller is required" >&2
    echo "  Example: --controller https://ai.example.com:8100" >&2
    usage >&2
    exit 1
fi

if [[ -z "$TOKEN" ]]; then
    echo "ERROR: --token is required" >&2
    echo "  Generate on controller: bash scripts/configure.sh generate-join-token" >&2
    usage >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# SHA-256 verification
# ---------------------------------------------------------------------------

if [[ -n "$SHA256_EXPECTED" ]]; then
    if [[ "$_PIPE_MODE" == "true" ]]; then
        echo "WARNING: Running in pipe mode — sha256 of this script cannot be verified." >&2
        echo "  To verify: download the script first, run sha256sum, then execute." >&2
    elif command -v sha256sum &>/dev/null; then
        actual=$(sha256sum "${BASH_SOURCE[0]}" | awk '{print $1}')
        if [[ "$actual" != "$SHA256_EXPECTED" ]]; then
            echo "ERROR: SHA-256 mismatch!" >&2
            echo "  Expected: $SHA256_EXPECTED" >&2
            echo "  Actual:   $actual" >&2
            exit 1
        fi
        echo "SHA-256 verified."
    elif command -v shasum &>/dev/null; then
        actual=$(shasum -a 256 "${BASH_SOURCE[0]}" | awk '{print $1}')
        if [[ "$actual" != "$SHA256_EXPECTED" ]]; then
            echo "ERROR: SHA-256 mismatch!" >&2
            echo "  Expected: $SHA256_EXPECTED" >&2
            echo "  Actual:   $actual" >&2
            exit 1
        fi
        echo "SHA-256 verified."
    else
        if [[ "$SKIP_VERIFY" != "true" ]]; then
            echo "ERROR: sha256sum/shasum not found; cannot verify script integrity." >&2
            echo "  Install: sudo apt-get install coreutils" >&2
            echo "  Or bypass with --skip-verify (not recommended)" >&2
            exit 1
        fi
        echo "WARNING: Skipping sha256 verification (sha256sum not available)." >&2
    fi
elif [[ "$_PIPE_MODE" == "true" && "$SKIP_VERIFY" != "true" ]]; then
    echo "WARNING: Running in pipe mode without --sha256 <hash>." >&2
    echo "  For secure bootstrap, provide --sha256 to enforce script integrity." >&2
fi

# ---------------------------------------------------------------------------
# Auto-detect address
# ---------------------------------------------------------------------------

if [[ -z "$ADDRESS" ]]; then
    primary_ip=$(hostname -I 2>/dev/null | awk '{print $1}' || echo "127.0.0.1")
    ADDRESS="http://${primary_ip}:8100"
fi

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------

for dep in curl python3; do
    if ! command -v "$dep" &>/dev/null; then
        echo "ERROR: $dep is required but not found" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Join the controller
# ---------------------------------------------------------------------------

echo ""
echo "AI Stack Worker Bootstrap"
echo "========================="
echo "  Controller:  $CONTROLLER_URL"
echo "  Node ID:     $NODE_ID"
echo "  Address:     $ADDRESS"
echo ""

body=$(printf '{"token":"%s","address":"%s"}' "$TOKEN" "$ADDRESS")

response=$(curl -s -w "\n%{http_code}" \
    -X POST "$CONTROLLER_URL/admin/v1/nodes/$NODE_ID/join" \
    -H "Content-Type: application/json" \
    -d "$body") || {
    echo "ERROR: Cannot reach controller at $CONTROLLER_URL" >&2
    exit 1
}

http_code=$(echo "$response" | tail -1)
body_part=$(echo "$response" | head -n -1)

if [[ "$http_code" != "200" ]]; then
    echo "ERROR: Join failed (HTTP $http_code):" >&2
    echo "$body_part" >&2
    exit 1
fi

echo "Joined successfully:"
echo "$body_part" | python3 -m json.tool 2>/dev/null || echo "$body_part"
echo ""

# ---------------------------------------------------------------------------
# Persist state for node.sh commands
# ---------------------------------------------------------------------------

STATE_DIR="${AI_STACK_NODE_DIR:-$HOME/.config/ai-stack}"
mkdir -p "$STATE_DIR"
printf '%s' "$CONTROLLER_URL" > "$STATE_DIR/controller_url"
printf '%s' "$NODE_ID"        > "$STATE_DIR/node_id"

echo "State saved: $STATE_DIR"
echo ""

# ---------------------------------------------------------------------------
# Install heartbeat systemd timer
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || echo "$HOME/ai-stack/scripts")"
QUADLET_TMPL_DIR="$(cd "$SCRIPT_DIR/../configs/quadlets" 2>/dev/null && pwd || echo "")"

SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_USER_DIR"

_install_unit() {
    local unit_name="$1"
    local dest="$SYSTEMD_USER_DIR/$unit_name"
    if [[ -n "$QUADLET_TMPL_DIR" && -f "$QUADLET_TMPL_DIR/$unit_name" ]]; then
        cp "$QUADLET_TMPL_DIR/$unit_name" "$dest"
    else
        # Fallback: emit inline if template dir not available (wget pipe mode)
        case "$unit_name" in
            ai-stack-heartbeat.service)
                cat > "$dest" <<EOF
[Unit]
Description=AI Stack worker node heartbeat
After=network.target
ConditionPathExists=%h/.config/ai-stack/controller_url
[Service]
Type=oneshot
ExecStart=/bin/bash %h/ai-stack/scripts/heartbeat.sh
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=default.target
EOF
                ;;
            ai-stack-heartbeat.timer)
                cat > "$dest" <<EOF
[Unit]
Description=AI Stack worker node heartbeat (every 30s)
After=network.target
[Timer]
OnUnitActiveSec=30s
RandomizedDelaySec=5s
AccuracySec=1s
Persistent=true
[Install]
WantedBy=timers.target
EOF
                ;;
        esac
    fi
}

_install_unit "ai-stack-heartbeat.service"
_install_unit "ai-stack-heartbeat.timer"

if command -v systemctl &>/dev/null; then
    systemctl --user daemon-reload 2>/dev/null && \
    systemctl --user enable --now ai-stack-heartbeat.timer 2>/dev/null && \
    echo "Heartbeat timer installed and started (every 30s)." || \
    echo "WARNING: Could not enable heartbeat timer — start manually:" && \
    echo "  systemctl --user enable --now ai-stack-heartbeat.timer"
else
    echo "WARNING: systemctl not found — start heartbeats manually:"
    echo "  bash scripts/heartbeat.sh"
fi

echo ""
echo "Next steps:"
echo "  • Check node status: bash scripts/node.sh status"
echo "  • View suggestions:  bash scripts/node.sh suggestions list"
echo "  • Timer status:      systemctl --user status ai-stack-heartbeat.timer"
echo ""
echo "Bootstrap complete."
