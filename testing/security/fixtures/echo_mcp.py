# testing/security/fixtures/echo_mcp.py -- stdio MCP server for verify-identity-boundary.sh.
# One tool, whoami: returns the STATIC and CALLER_* env vars it was spawned with.
# Minimal stdio MCP server: one tool, whoami, reporting the env it was spawned with.
import json, os, sys
def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
for line in sys.stdin:
    m = json.loads(line)
    mid, meth = m.get("id"), m.get("method")
    if meth == "initialize":
        send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": m["params"]["protocolVersion"],
              "capabilities": {"tools": {}}, "serverInfo": {"name": "echo", "version": "0"}}})
    elif meth == "tools/list":
        send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": "whoami", "description": "env seen by the server",
              "inputSchema": {"type": "object", "properties": {}}}]}})
    elif meth == "tools/call":
        seen = {k: v for k, v in os.environ.items() if k.startswith("CALLER_") or k == "STATIC"}
        seen["pid"] = os.getpid()
        seen["_meta"] = m["params"].get("_meta")
        send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": json.dumps(seen, sort_keys=True)}]}})
    elif mid is not None:
        send({"jsonrpc": "2.0", "id": mid, "result": {}})
