#!/usr/bin/env bash
# scripts/inhibit.sh — Sleep/hibernation inhibitor for AI Stack worker nodes
#
# Prevents the OS from sleeping or hibernating while the AI stack is running.
# Uses caffeinate(1) on macOS and systemd-inhibit(1) on Linux.
#
# The inhibitor is opt-in: set "sleep_inhibit": true in config.json, or export
# SLEEP_INHIBIT=true.  Controller nodes are always skipped — they manage their
# own power policy through the system sleep settings.
#
# Usage:
#   inhibit.sh start    Acquire sleep inhibitor
#   inhibit.sh stop     Release sleep inhibitor
#   inhibit.sh status   Show inhibitor state
#
# Called automatically by start.sh (start) and stop.sh (stop).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"
NODE_PROFILE_FILE="${NODE_PROFILE_FILE:-$PROJECT_ROOT/configs/node_profile}"
STATE_DIR="${AI_STACK_NODE_DIR:-$HOME/.config/ai-stack}"
PID_FILE="$STATE_DIR/inhibit.pid"

usage() {
    cat <<'EOF'
Usage: inhibit.sh <command>

Commands:
  start    Acquire sleep inhibitor (prevents idle/suspend while stack is running)
  stop     Release sleep inhibitor
  status   Show inhibitor state

Purpose:
  Prevents macOS or Linux from sleeping/hibernating while the AI stack is active.
  Only activates when sleep_inhibit is true in config.json, or when
  SLEEP_INHIBIT=true is set in the environment.
  Controller nodes are always skipped — they manage their own power policy.

Platform:
  macOS  — uses caffeinate (built-in, no sudo required)
  Linux  — uses systemd-inhibit (part of systemd)

Environment:
  CONFIG_FILE    Path to config.json (default: ./configs/config.json)
  SLEEP_INHIBIT  "true" or "false" — overrides config.json setting
EOF
}

# ── Helpers ───────────────────────────────────────────────────────────────────

_get_node_profile() {
    if [[ -f "$NODE_PROFILE_FILE" ]]; then
        local p; p=$(tr -d '[:space:]' < "$NODE_PROFILE_FILE")
        [[ -n "$p" ]] && { echo "$p"; return; }
    fi
    jq -r '.node_profile // "controller"' "$CONFIG_FILE" 2>/dev/null || echo "controller"
}

_sleep_inhibit_enabled() {
    # Env var takes precedence over config.json
    if [[ "${SLEEP_INHIBIT:-}" == "true"  ]]; then return 0; fi
    if [[ "${SLEEP_INHIBIT:-}" == "false" ]]; then return 1; fi
    local val
    val=$(jq -r '.sleep_inhibit // false' "$CONFIG_FILE" 2>/dev/null || echo "false")
    [[ "$val" == "true" ]]
}

_pid_alive() {
    kill -0 "$1" 2>/dev/null
}

_read_pid() {
    [[ -f "$PID_FILE" ]] && cat "$PID_FILE" || echo ""
}

# ── Commands ──────────────────────────────────────────────────────────────────

cmd_start() {
    local profile; profile=$(_get_node_profile)

    if [[ "$profile" == "controller" ]]; then
        echo "Inhibitor: skipped (controller — manages its own power policy)"
        return 0
    fi

    if ! _sleep_inhibit_enabled; then
        echo "Inhibitor: disabled (set \"sleep_inhibit\": true in config.json to enable)"
        return 0
    fi

    mkdir -p "$STATE_DIR"

    # Clean up stale PID file if the process is gone
    local existing_pid; existing_pid=$(_read_pid)
    if [[ -n "$existing_pid" ]] && _pid_alive "$existing_pid"; then
        echo "Inhibitor: already active (PID $existing_pid)"
        return 0
    fi
    rm -f "$PID_FILE"

    local new_pid
    if [[ "$(uname -s)" == "Darwin" ]]; then
        if ! command -v caffeinate &>/dev/null; then
            echo "WARNING: caffeinate not found — sleep inhibitor not active" >&2
            return 0
        fi
        # -i: prevent idle sleep  -s: prevent system sleep
        caffeinate -i -s &
        new_pid=$!
    else
        if ! command -v systemd-inhibit &>/dev/null; then
            echo "WARNING: systemd-inhibit not found — sleep inhibitor not active" >&2
            return 0
        fi
        systemd-inhibit \
            --what=idle:sleep:handle-suspend-key:handle-hibernate-key \
            --who="ai-stack" \
            --why="AI Stack worker is running" \
            --mode=block \
            sleep infinity &
        new_pid=$!
    fi

    echo "$new_pid" > "$PID_FILE"
    echo "Inhibitor: active (PID $new_pid, platform: $(uname -s), profile: $profile)"
}

cmd_stop() {
    local pid; pid=$(_read_pid)

    if [[ -z "$pid" ]]; then
        echo "Inhibitor: not active (no PID file)"
        return 0
    fi

    if _pid_alive "$pid"; then
        if kill "$pid" 2>/dev/null; then
            echo "Inhibitor: released (PID $pid)"
        else
            echo "WARNING: could not kill inhibitor PID $pid" >&2
        fi
    else
        echo "Inhibitor: was not running (stale PID $pid cleaned up)"
    fi

    rm -f "$PID_FILE"
}

cmd_status() {
    local profile; profile=$(_get_node_profile)
    local pid; pid=$(_read_pid)
    local enabled; _sleep_inhibit_enabled && enabled="yes" || enabled="no"

    echo "Inhibitor status"
    echo "  Platform:  $(uname -s)"
    echo "  Profile:   $profile"
    echo "  Enabled:   $enabled (config.json sleep_inhibit / SLEEP_INHIBIT env)"
    echo ""

    if [[ -n "$pid" ]] && _pid_alive "$pid"; then
        echo "  State:     active (PID $pid)"
        if [[ "$(uname -s)" != "Darwin" ]] && command -v systemd-inhibit &>/dev/null; then
            echo ""
            systemd-inhibit --list 2>/dev/null | grep -i "ai-stack" || true
        fi
    else
        echo "  State:     inactive"
        if [[ -n "$pid" ]]; then
            echo "  Note:      stale PID $pid in $PID_FILE — run 'inhibit.sh stop' to clean up"
        fi
    fi
}

# ── Dispatch ──────────────────────────────────────────────────────────────────

case "${1:-}" in
    start)          cmd_start ;;
    stop)           cmd_stop ;;
    status)         cmd_status ;;
    -h|--help|help) usage; exit 0 ;;
    *) echo "Usage: inhibit.sh <start|stop|status>" >&2; usage >&2; exit 1 ;;
esac
