#!/usr/bin/env bash
# scripts/check-logs.sh — Cross-layer diagnostic snapshot for "model seems stuck/disconnected"
#
# Consolidates the evidence this project's own incident investigations keep
# needing, across every layer a stuck/crashed model report can originate
# from, so troubleshooting doesn't require re-deriving it by hand each time:
#
#   - Host:       CPU/memory/GPU pressure (rules out OOM as a cause)
#   - Ollama:     loaded models + resource usage (is it actually idle, or
#                 genuinely still working), the raw access log (the *only*
#                 place a real backend failure reliably shows up — LiteLLM
#                 has been observed silently swallowing backend 500s), and
#                 whether a model is sitting near its context-window ceiling
#   - LiteLLM:    recent errors/tracebacks, and whether it logged anything
#                 at all for each Ollama-side failure found above
#   - Open WebUI: chats with a message stuck in-progress (done=0) or
#                 completed with empty content and no recorded error (the
#                 "silent failure" pattern), plus a check for tool-call-
#                 shaped text in message content when no real tool is
#                 registered (the model narrating a fake tool call as plain
#                 text, rather than actually invoking one)
#
# This script is read-only — it never stops, restarts, or modifies anything.
#
# Usage:
#   check-logs.sh                     # full snapshot, last 30 min, auto-detect
#   check-logs.sh --since "-2 hours"   # widen/narrow the log window
#   check-logs.sh --chat-id <id>       # focus Open WebUI section on one chat
#
# Environment variables:
#   OLLAMA_CONTAINER      default: ollama
#   LITELLM_SERVICE       default: litellm.service (systemd --user unit)
#   OPENWEBUI_CONTAINER   default: openwebui

set -euo pipefail

SINCE="-30 min"
CHAT_ID=""
OLLAMA_CONTAINER="${OLLAMA_CONTAINER:-ollama}"
LITELLM_SERVICE="${LITELLM_SERVICE:-litellm.service}"
OPENWEBUI_CONTAINER="${OPENWEBUI_CONTAINER:-openwebui}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --since) SINCE="$2"; shift 2 ;;
        --chat-id) CHAT_ID="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

section() { printf '\n%s\n%s\n%s\n' "================================================================================" "  $1" "================================================================================"; }

section "Host resources"
free -h
if command -v nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv 2>&1
else
    echo "nvidia-smi not available — no GPU, or not running on the GPU host"
fi

section "Ollama: loaded models (NAME/SIZE/PROCESSOR/CONTEXT/UNTIL)"
podman exec "$OLLAMA_CONTAINER" ollama ps 2>&1 || echo "could not reach $OLLAMA_CONTAINER"
echo
echo "-- container resource usage --"
podman stats --no-stream "$OLLAMA_CONTAINER" 2>&1 || true

# podman logs --since wants a Go duration ("20m") or timestamp, not
# journalctl's "-20 min" style — convert once, reuse for every podman call.
PODMAN_SINCE="$(echo "$SINCE" | sed -E 's/^-?\s*([0-9]+)\s*min(ute)?s?$/\1m/; s/^-?\s*([0-9]+)\s*hours?$/\1h/')"

section "Ollama: raw access log, window=$SINCE (ground truth for real backend failures)"
GIN_LOG="$(podman logs "$OLLAMA_CONTAINER" --since "$PODMAN_SINCE" 2>/dev/null | grep "POST.*api/chat" || true)"
if [[ -n "$GIN_LOG" ]]; then
    echo "$GIN_LOG"
else
    echo "no POST /api/chat entries in this window"
fi
echo
FIVE_HUNDREDS="$(echo "$GIN_LOG" | grep -E '\| 500 \|' || true)"
if [[ -n "$FIVE_HUNDREDS" ]]; then
    echo "-- backend returned a real 500 for these (LiteLLM may not have logged anything for them — check the LiteLLM section below) --"
    echo "$FIVE_HUNDREDS"
fi

section "Ollama: most recent log lines (last 40) — context-window position, crash/panic text, slot activity"
podman logs "$OLLAMA_CONTAINER" --tail 40 2>&1
echo
echo "-- any explicit error/panic/OOM text in this window --"
podman logs "$OLLAMA_CONTAINER" --since "$PODMAN_SINCE" 2>/dev/null | grep -iE "error|panic|oom|killed|crash|unexpected eof" | grep -v "print_info\|slot " || echo "none found"

section "Host kernel: OOM killer activity in this window"
journalctl -k --since "$SINCE" --no-pager 2>&1 | grep -iE "oom|killed process|out of memory" || echo "none found"

section "LiteLLM: recent errors/tracebacks, window=$SINCE"
journalctl --user -u "$LITELLM_SERVICE" --since "$SINCE" --no-pager 2>&1 | grep -iE "ERROR|Exception|Traceback|InternalServerError|BadRequestError" | tail -60 || echo "none found"

section "LiteLLM: service health"
systemctl --user is-active "$LITELLM_SERVICE" 2>&1 || true
journalctl --user -u "$LITELLM_SERVICE" --since "$SINCE" --no-pager 2>&1 | grep -i "health/liveliness" | tail -3 || true

section "Open WebUI: chats with a stuck or silently-failed assistant turn"
# done=0            -> genuinely still in progress (or abandoned mid-stream)
# done=1 + empty content + no error -> the "silent failure" pattern found in
#                       the qwen3-coder-next incident: a real upstream
#                       failure that never got recorded anywhere
QUERY_CHAT_FILTER=""
if [[ -n "$CHAT_ID" ]]; then
    QUERY_CHAT_FILTER="AND chat_id = '$CHAT_ID'"
fi
podman exec -i "$OPENWEBUI_CONTAINER" python3 - "$QUERY_CHAT_FILTER" << 'PYEOF'
import sqlite3, json, sys, time

chat_filter = sys.argv[1] if len(sys.argv) > 1 else ""
conn = sqlite3.connect('/app/backend/data/webui.db')
c = conn.cursor()
q = f"""
    SELECT chat_id, id, model_id, done, error, length(content), created_at, updated_at
    FROM chat_message
    WHERE role = 'assistant'
      AND (done = 0 OR (done = 1 AND error IS NULL AND (content = '""' OR content IS NULL OR length(content) <= 2)))
      {chat_filter}
    ORDER BY created_at DESC
    LIMIT 20
"""
rows = c.execute(q).fetchall()
if not rows:
    print("none found — no stuck or silently-empty assistant turns in the database")
else:
    now = time.time()
    for chat_id, mid, model_id, done, error, clen, created, updated in rows:
        age_min = (now - created) / 60
        status = "STILL IN PROGRESS (done=0)" if done == 0 else "COMPLETED but EMPTY + no error (silent failure)"
        print(f"chat={chat_id} msg={mid.split('-')[-1]} model={model_id} status=[{status}] age={age_min:.1f}min created={created}")
PYEOF

section "Open WebUI: tool-call-shaped text with no real tool registered (hallucinated tool use)"
podman exec -i "$OPENWEBUI_CONTAINER" python3 -c "
import sqlite3, json
conn = sqlite3.connect('/app/backend/data/webui.db')
c = conn.cursor()
n_custom_tools = c.execute('SELECT count(*) FROM tool').fetchone()[0]
row = c.execute(\"SELECT value FROM config WHERE key='tool_server.connections'\").fetchone()
connections = json.loads(row[0]) if row and row[0] else []
print(f'Registered custom (Python) tools: {n_custom_tools}')
print(f'Registered tool-server connections (OpenAPI/MCP): {len(connections)}')
for conn_entry in connections:
    info = conn_entry.get('info', {})
    enabled = conn_entry.get('config', {}).get('enable')
    print(f\"  - {info.get('name', '?')} ({conn_entry.get('url')}) enabled={enabled}\")
if n_custom_tools == 0 and not connections:
    print('No tools exist at all — any message containing \"Executing <name>...\" or similar')
    print('tool-call narration is the model generating that as plain text, not a real')
    print('tool execution. Check the message content directly for this pattern.')
"

section "Summary"
echo "Review the sections above for:"
echo "  1. A real Ollama 500 with no matching LiteLLM log entry -> LiteLLM swallowed it (see docs/upstream-reports/)"
echo "  2. A model near its context-window ceiling in the 'loaded models'/'recent log lines' sections -> expect slow full-prompt reprocessing on every turn"
echo "  3. A chat flagged 'STILL IN PROGRESS' with high age -> likely actually hung; check Ollama resource usage above to see if it's truly working or idle"
echo "  4. A chat flagged 'silent failure' -> the model/pipeline failed with nothing recorded; re-run with --chat-id to dig into that specific chat's content"
echo "  5. Zero registered tools + content that narrates a tool call -> the model is hallucinating tool use as text, not actually executing anything"
