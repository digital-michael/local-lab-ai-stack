# configs/litellm/mcp_zip_offload.py -- stdio MCP server for offloading experiment
# artifacts (files/code the model produces) to real disk + a zip archive, instead
# of the model re-generating everything as plain text on every "save a checkpoint"
# request (the root cause behind the qwen3-coder-next/qwen3.8-flash-next incidents:
# no tool existed, so the model tried to simulate file creation as a giant text
# dump, which is slow on a CPU model and a likely contributor to the crashes).
#
# Three tools only, deliberately minimal:
#   write_file  -- write text content to a path under the offload root
#   list_files  -- list what's been written so far
#   create_zip  -- zip the offload root (or a subset of paths) into one archive
#
# No third-party dependencies (matches testing/security/fixtures/echo_mcp.py's
# raw JSON-RPC-over-stdio approach) so nothing needs installing into LiteLLM's
# container image. All paths are relative and confined under OFFLOAD_ROOT --
# '..' or an absolute path is rejected, never resolved.

import json
import os
import sys
import zipfile

OFFLOAD_ROOT = os.environ.get("MCP_ZIP_OFFLOAD_ROOT", "/app/mcp-offload")


def send(msg):
    sys.stdout.write(json.dumps(msg) + "\n")
    sys.stdout.flush()


def _safe_path(rel_path):
    """Resolve rel_path under OFFLOAD_ROOT; raise ValueError on any escape attempt."""
    if not rel_path or os.path.isabs(rel_path) or ".." in rel_path.split(os.sep):
        raise ValueError(f"path must be relative and stay under the offload root: {rel_path!r}")
    full = os.path.normpath(os.path.join(OFFLOAD_ROOT, rel_path))
    if os.path.commonpath([full, OFFLOAD_ROOT]) != OFFLOAD_ROOT:
        raise ValueError(f"path escapes the offload root: {rel_path!r}")
    return full


def tool_write_file(args):
    rel_path = args.get("path", "")
    content = args.get("content", "")
    full = _safe_path(rel_path)
    os.makedirs(os.path.dirname(full), exist_ok=True)
    with open(full, "w") as f:
        f.write(content)
    return f"wrote {len(content)} bytes to {rel_path}"


def tool_list_files(args):
    out = []
    for root, _dirs, files in os.walk(OFFLOAD_ROOT):
        for name in files:
            full = os.path.join(root, name)
            rel = os.path.relpath(full, OFFLOAD_ROOT)
            out.append({"path": rel, "size": os.path.getsize(full)})
    return json.dumps(out, indent=2)


def tool_create_zip(args):
    zip_name = args.get("zip_name", "offload.zip")
    paths = args.get("paths")  # optional list of relative paths; default = everything
    zip_full = _safe_path(zip_name)
    os.makedirs(os.path.dirname(zip_full), exist_ok=True)

    if paths:
        targets = [_safe_path(p) for p in paths]
    else:
        targets = []
        for root, _dirs, files in os.walk(OFFLOAD_ROOT):
            for name in files:
                full = os.path.join(root, name)
                if full != zip_full:
                    targets.append(full)

    with zipfile.ZipFile(zip_full, "w", zipfile.ZIP_DEFLATED) as zf:
        for full in targets:
            zf.write(full, arcname=os.path.relpath(full, OFFLOAD_ROOT))

    return f"created {zip_name} with {len(targets)} file(s) under {OFFLOAD_ROOT}"


TOOLS = {
    "write_file": {
        "description": "Write text content to a file under the offload directory. Creates parent directories as needed. Use this instead of pasting large content back into the chat.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Relative path, e.g. 'agent-profile/profile.go'"},
                "content": {"type": "string", "description": "Full text content to write"},
            },
            "required": ["path", "content"],
        },
        "handler": tool_write_file,
    },
    "list_files": {
        "description": "List all files currently written to the offload directory, with sizes.",
        "inputSchema": {"type": "object", "properties": {}},
        "handler": tool_list_files,
    },
    "create_zip": {
        "description": "Create a zip archive of the offload directory (or a specific list of relative paths) as an intermediate save point.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "zip_name": {"type": "string", "description": "Name for the archive, e.g. 'checkpoint-1.zip'"},
                "paths": {"type": "array", "items": {"type": "string"}, "description": "Optional: specific relative paths to include. Omit to zip everything written so far."},
            },
            "required": ["zip_name"],
        },
        "handler": tool_create_zip,
    },
}


def main():
    os.makedirs(OFFLOAD_ROOT, exist_ok=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        msg = json.loads(line)
        mid, method = msg.get("id"), msg.get("method")

        if method == "initialize":
            send({
                "jsonrpc": "2.0", "id": mid,
                "result": {
                    "protocolVersion": msg["params"]["protocolVersion"],
                    "capabilities": {"tools": {}},
                    "serverInfo": {"name": "zip-offload", "version": "0.1.0"},
                },
            })
        elif method == "notifications/initialized":
            pass  # no response expected for a notification
        elif method == "tools/list":
            tools = [
                {"name": name, "description": spec["description"], "inputSchema": spec["inputSchema"]}
                for name, spec in TOOLS.items()
            ]
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": tools}})
        elif method == "tools/call":
            name = msg["params"]["name"]
            args = msg["params"].get("arguments", {})
            try:
                if name not in TOOLS:
                    raise ValueError(f"unknown tool: {name}")
                result_text = TOOLS[name]["handler"](args)
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": result_text}]}})
            except Exception as e:
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": f"error: {e}"}], "isError": True}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "result": {}})


if __name__ == "__main__":
    main()
