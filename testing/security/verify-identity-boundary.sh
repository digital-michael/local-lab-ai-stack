#!/usr/bin/env bash
# verify-identity-boundary.sh -- D-041 Stage 1 trust boundary, pass/fail.
#
# Proves that forwarded chat-user identity (X-OpenWebUI-User-*) reaches an MCP
# server through LiteLLM ONLY for Open WebUI's key, and that any other key
# sending the same headers cannot assert an identity.
#
# Design under test (LiteLLM config):
#   <open server>  allow_all_keys: true,  env has NO ${X-...} placeholders
#   <chat server>  allow_all_keys: false, env CALLER_ID/_EMAIL/_ROLE: "${X-OpenWebUI-User-...}"
#   Open WebUI's virtual key: object_permission.mcp_servers = [<chat server id>]
#   Every other key: no grant for the chat server.
# Both servers must expose a `whoami` tool that returns the CALLER_* env it sees
# as JSON (see testing/security/fixtures/echo_mcp.py).
#
# Usage:
#   verify-identity-boundary.sh --url http://127.0.0.1:4000 \
#       --owui-key-file <f> --other-key-file <f> \
#       [--open-server cortex_open] [--chat-server cortex_chat] \
#       --open-id <server_id> --chat-id <server_id>
# Keys are read from files so they never appear in argv or output.
set -uo pipefail

URL="" OWUI_F="" OTHER_F="" OPEN=cortex_open CHAT=cortex_chat OPEN_ID="" CHAT_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --url) URL="$2"; shift 2 ;;
    --owui-key-file) OWUI_F="$2"; shift 2 ;;
    --other-key-file) OTHER_F="$2"; shift 2 ;;
    --open-server) OPEN="$2"; shift 2 ;;
    --chat-server) CHAT="$2"; shift 2 ;;
    --open-id) OPEN_ID="$2"; shift 2 ;;
    --chat-id) CHAT_ID="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$URL" && -r "$OWUI_F" && -r "$OTHER_F" && -n "$OPEN_ID" && -n "$CHAT_ID" ]] || { sed -n 2,22p "$0"; exit 2; }
OWUI="$(cat "$OWUI_F")" OTHER="$(cat "$OTHER_F")"

pass=0 fail=0
check() { if [[ "$2" == 0 ]]; then pass=$((pass+1)); printf '  ok    %s\n' "$1"; else fail=$((fail+1)); printf '  FAIL  %s\n        %s\n' "$1" "${3:-}"; fi; }
SPOOF=(-H "X-OpenWebUI-User-Id: u-spoofed-admin" -H "X-OpenWebUI-User-Email: admin@spoofed.example" -H "X-OpenWebUI-User-Role: admin")
REAL=(-H "X-OpenWebUI-User-Id: u-alice" -H "X-OpenWebUI-User-Email: alice@example.com" -H "X-OpenWebUI-User-Role: user")

# rest <key> <server_id> <server_name> [headers...] -> prints "HTTP <code> <tool text or error>".
# Uses the namespaced tool name: on LiteLLM 1.81.14 a bare name ("whoami") is
# resolved across servers and can run another server's tool despite server_id.
rest() {
  local key="$1" sid="$2" name="$3"; shift 3
  curl -s -w '\nHTTP %{http_code}' "$URL/mcp-rest/tools/call" -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" "$@" -d "{\"server_id\":\"$sid\",\"name\":\"$name-whoami\",\"arguments\":{}}" \
  | python3 -c '
import json, sys
body, code = sys.stdin.read().rsplit("\nHTTP ", 1)
try:
    d = json.loads(body)
    text = "".join(c.get("text", "") for c in d["content"]) if isinstance(d, dict) and "content" in d else json.dumps(d)
except Exception:
    text = body
print("HTTP", code.strip(), text)'
}

# mcp <key> <tool> [headers...] -> runs initialize + tools/call over the MCP
# streamable HTTP endpoint and prints the tool result text or "ERROR: ...".
mcp() {
  local key="$1" tool="$2"; shift 2
  python3 - "$URL/mcp/" "$key" "$tool" "$@" <<'PY'
import json, sys, urllib.request, urllib.error
url, key, tool, *hdr_args = sys.argv[1:]
extra = {}
for i in range(0, len(hdr_args), 2):
    if hdr_args[i] == "-H":
        k, v = hdr_args[i + 1].split(": ", 1); extra[k] = v
def post(body, sid=None):
    h = {"Authorization": f"Bearer {key}", "Content-Type": "application/json",
         "Accept": "application/json, text/event-stream", **extra}
    if sid: h["mcp-session-id"] = sid
    req = urllib.request.Request(url, data=json.dumps(body).encode(), headers=h)
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            raw = r.read().decode(); sid = r.headers.get("mcp-session-id") or sid
    except urllib.error.HTTPError as e:
        return None, sid, f"HTTP {e.code} {e.read().decode()[:200]}"
    for line in raw.splitlines():
        if line.startswith("data:"): raw = line[5:].strip()
    return (json.loads(raw) if raw.strip() else None), sid, None
init, sid, err = post({"jsonrpc": "2.0", "id": 1, "method": "initialize",
    "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "tb", "version": "0"}}})
if err: print("ERROR:", err); sys.exit()
post({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
res, _, err = post({"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": {}}}, sid)
if err: print("ERROR:", err); sys.exit()
r = (res or {}).get("result") or {}
if (res or {}).get("error") or r.get("isError"):
    print("ERROR:", json.dumps((res or {}).get("error") or r.get("content"))[:200]); sys.exit()
print("".join(c.get("text", "") for c in r.get("content", [])))
PY
}

has_caller() { grep -q 'CALLER_ID'; }

echo "identity trust boundary: $URL"
echo "REST /mcp-rest/tools/call"
out=$(rest "$OWUI" "$CHAT_ID" "$CHAT" "${REAL[@]}")
check "Open WebUI key + headers -> chat server sees the user" "$(grep -q '"CALLER_ID": "u-alice"' <<<"$out" && grep -q '"CALLER_ROLE": "user"' <<<"$out"; echo $?)" "$out"
out=$(rest "$OWUI" "$CHAT_ID" "$CHAT")
check "Open WebUI key, no headers -> anonymous (no CALLER_*)" "$(grep -q '"STATIC": "chat"' <<<"$out" && ! has_caller <<<"$out"; echo $?)" "$out"
out=$(rest "$OTHER" "$CHAT_ID" "$CHAT" "${SPOOF[@]}")
check "other key + spoofed headers -> chat server refused (403), tool never runs" "$(! grep -q 'STATIC' <<<"$out" && grep -q '^HTTP 403' <<<"$out"; echo $?)" "$out"
out=$(rest "$OTHER" "$OPEN_ID" "$OPEN" "${SPOOF[@]}")
check "other key + spoofed headers -> open server runs with no identity" "$(grep -q '"STATIC": "open"' <<<"$out" && ! has_caller <<<"$out"; echo $?)" "$out"
out=$(rest "$OWUI" "$OPEN_ID" "$OPEN" "${REAL[@]}")
check "Open WebUI key + headers -> open server still gets no identity" "$(grep -q '"STATIC": "open"' <<<"$out" && ! has_caller <<<"$out"; echo $?)" "$out"

echo "tool listing"
list=$(curl -s "$URL/mcp-rest/tools/list" -H "Authorization: Bearer $OTHER")
check "other key does not see chat server tools" "$(! grep -q "\"$CHAT" <<<"$list" && grep -q '"whoami"' <<<"$list"; echo $?)" "$(head -c 300 <<<"$list")"

echo "MCP protocol /mcp"
out=$(mcp "$OWUI" "$CHAT-whoami" "${REAL[@]}")
check "Open WebUI key + headers -> chat server sees the user" "$(grep -q '"CALLER_ID": "u-alice"' <<<"$out"; echo $?)" "$out"
out=$(mcp "$OTHER" "$CHAT-whoami" "${SPOOF[@]}")
check "other key + spoofed headers -> chat tool refused" "$(! grep -q 'STATIC' <<<"$out" && grep -q '^ERROR' <<<"$out"; echo $?)" "$out"
out=$(mcp "$OTHER" "$OPEN-whoami" "${SPOOF[@]}")
check "other key + spoofed headers -> open tool runs with no identity" "$(grep -q '"STATIC": "open"' <<<"$out" && ! has_caller <<<"$out"; echo $?)" "$out"

echo; echo "$pass passed, $fail failed"
[[ "$fail" == 0 ]]
