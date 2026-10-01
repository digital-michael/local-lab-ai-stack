# services/conversions/app.py
#
# Conversions Service — document format conversion (D-0xx, see docs/decisions.md)
#
# REST API:
#   GET  /health              — readiness probe
#   GET  /formats             — capability discovery: currently-implemented (from, to) pairs
#   POST /v1/convert          — API/CLI/agent entrypoint (multipart upload); requires API_KEY
#                                bearer auth (D-034 Layer B — no browser session available)
#
# Browser UI (no app-level auth — gated by Traefik's Authentik forward-auth instead, D-034 Layer A):
#   GET  /                    — upload form
#   POST /ui/convert          — form submission target; same conversion engine as /v1/convert
#
# MCP (Model Context Protocol) — HTTP/SSE transport, mirrors knowledge-index (D-015):
#   GET  /mcp/sse             — establish SSE stream
#   POST /mcp/messages        — MCP message channel
#   Tools: convert_document (content is base64 — unlike knowledge-index's text-only tools,
#          converted formats here may be binary, e.g. PDF)
#
# Auth: API_KEY env var guards /v1/* and /mcp/* when set. /ui/* and / rely on Traefik's
# Authentik forward-auth middleware instead — see configs/traefik/dynamic/services.yaml.

from __future__ import annotations

import asyncio
import base64
import json
import os
import pathlib
import tempfile

from fastapi import FastAPI, File, Form, HTTPException, UploadFile
from fastapi.templating import Jinja2Templates
from mcp.server import Server as McpServer
from mcp.server.sse import SseServerTransport
from mcp.types import TextContent, Tool
from starlette.requests import Request
from starlette.responses import HTMLResponse, Response

import converters

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

API_KEY = os.environ.get("API_KEY", "")
MAX_UPLOAD_BYTES = int(os.environ.get("MAX_UPLOAD_BYTES", str(25 * 1024 * 1024)))

_MIME_TYPES: dict[str, str] = {
    "md": "text/markdown",
    "pdf": "application/pdf",
    "html": "text/html",
    "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
    "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
}
_SUPPORTED_FORMATS = frozenset(_MIME_TYPES)

app = FastAPI(title="Conversions Service", version="0.1.0")
_templates = Jinja2Templates(directory=str(pathlib.Path(__file__).parent / "templates"))

# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------


def _check_api_key(request: Request) -> None:
    """Raise HTTP 401 if API_KEY is configured and the request does not supply it."""
    if not API_KEY:
        return
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or auth[7:] != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")

# ---------------------------------------------------------------------------
# Shared conversion engine (used by REST, UI, and MCP surfaces)
# ---------------------------------------------------------------------------


def _validate_known_formats(from_format: str, to_format: str) -> None:
    """Reject unrecognized format tokens outright. Whether the *pair* is
    implemented yet is the registry's concern (UnsupportedConversionError)."""
    if from_format not in _SUPPORTED_FORMATS or to_format not in _SUPPORTED_FORMATS:
        raise HTTPException(
            status_code=422,
            detail=f"Unknown format token(s): {from_format!r} -> {to_format!r}. "
                   f"Recognized tokens: {sorted(_SUPPORTED_FORMATS)}",
        )


async def _read_capped(upload: UploadFile, max_bytes: int) -> bytes:
    """Read an UploadFile into memory, rejecting anything over max_bytes.

    Starlette does not cap multipart body size by default — unbounded upload
    is a real DoS surface for a conversion service, so this is enforced here
    rather than relying on any upstream default.
    """
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = await upload.read(1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > max_bytes:
            raise HTTPException(status_code=413, detail=f"Upload exceeds {max_bytes} byte limit")
        chunks.append(chunk)
    return b"".join(chunks)


def _run_conversion(input_bytes: bytes, from_format: str, to_format: str) -> bytes:
    """Run one conversion in an isolated temp directory.

    Every temp file lives inside this TemporaryDirectory context manager, so
    cleanup is deterministic even if the converter raises (RLC — Python
    governance overlay's Resource Lifecycle Contract).
    Raises converters.ConversionError / UnsupportedConversionError on failure;
    callers translate those into their own surface's error shape.
    """
    with tempfile.TemporaryDirectory() as tmp:
        tmp_path = pathlib.Path(tmp)
        input_path = tmp_path / f"input.{from_format}"
        output_path = tmp_path / f"output.{to_format}"
        input_path.write_bytes(input_bytes)
        converters.convert(from_format, to_format, input_path, output_path)
        return output_path.read_bytes()


async def _convert_upload(file: UploadFile, from_format: str, to_format: str) -> Response:
    from_format = from_format.lower().lstrip(".")
    to_format = to_format.lower().lstrip(".")
    _validate_known_formats(from_format, to_format)

    input_bytes = await _read_capped(file, MAX_UPLOAD_BYTES)

    try:
        output_bytes = await asyncio.to_thread(_run_conversion, input_bytes, from_format, to_format)
    except converters.UnsupportedConversionError as exc:
        raise HTTPException(status_code=501, detail=str(exc)) from exc
    except converters.ConversionError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc

    filename = f"{pathlib.Path(file.filename or 'converted').stem}.{to_format}"
    return Response(
        content=output_bytes,
        media_type=_MIME_TYPES[to_format],
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )

# ---------------------------------------------------------------------------
# REST endpoints
# ---------------------------------------------------------------------------


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.get("/formats")
def list_formats() -> dict:
    return {
        "implemented": converters.list_formats(),
        "known_tokens": sorted(_SUPPORTED_FORMATS),
    }


@app.post("/v1/convert")
async def convert_v1(
    request: Request,
    file: UploadFile = File(...),
    from_format: str = Form(...),
    to_format: str = Form(...),
) -> Response:
    """API/CLI/agent entrypoint. Requires API_KEY bearer auth (D-034 Layer B)."""
    _check_api_key(request)
    return await _convert_upload(file, from_format, to_format)

# ---------------------------------------------------------------------------
# Browser UI — server-rendered, no JS build step (Jinja2 + a little HTMX for
# the format picker). Auth is Traefik's Authentik forward-auth, not app-level
# (D-034 Layer A) — see configs/traefik/dynamic/services.yaml's `conversions` router.
# ---------------------------------------------------------------------------


@app.get("/", response_class=HTMLResponse)
def index(request: Request) -> HTMLResponse:
    return _templates.TemplateResponse(
        request, "index.html", {"formats": sorted(_SUPPORTED_FORMATS)}
    )


@app.post("/ui/convert")
async def convert_ui(
    file: UploadFile = File(...),
    from_format: str = Form(...),
    to_format: str = Form(...),
) -> Response:
    return await _convert_upload(file, from_format, to_format)

# ---------------------------------------------------------------------------
# MCP — HTTP/SSE transport (mirrors knowledge-index, D-015)
# One tool: convert_document. Content is base64 since converted formats may
# be binary (e.g. PDF) — MCP's text-oriented content blocks don't carry raw
# bytes directly.
# ---------------------------------------------------------------------------

_mcp_server = McpServer("conversions")
_sse_transport = SseServerTransport("/mcp/messages")


@_mcp_server.list_tools()
async def _list_tools() -> list[Tool]:
    return [
        Tool(
            name="convert_document",
            description=(
                "Convert a document between supported formats. Call GET /formats "
                "(or list_formats via REST) to see currently-implemented pairs. "
                "Content is base64-encoded on both sides since converted formats "
                "may be binary (e.g. PDF)."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "content_base64": {"type": "string", "description": "Base64-encoded source document"},
                    "from_format": {"type": "string", "description": "Source format token, e.g. 'md', 'pdf'"},
                    "to_format": {"type": "string", "description": "Target format token, e.g. 'md', 'pdf'"},
                },
                "required": ["content_base64", "from_format", "to_format"],
            },
        ),
    ]


@_mcp_server.call_tool()
async def _call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name != "convert_document":
        raise ValueError(f"Unknown MCP tool: {name!r}")

    from_format = str(arguments["from_format"]).lower().lstrip(".")
    to_format = str(arguments["to_format"]).lower().lstrip(".")
    if from_format not in _SUPPORTED_FORMATS or to_format not in _SUPPORTED_FORMATS:
        raise ValueError(
            f"Unknown format token(s): {from_format!r} -> {to_format!r}. "
            f"Recognized tokens: {sorted(_SUPPORTED_FORMATS)}"
        )

    try:
        input_bytes = base64.b64decode(arguments["content_base64"], validate=True)
    except Exception as exc:
        raise ValueError(f"content_base64 is not valid base64: {exc}") from exc

    if len(input_bytes) > MAX_UPLOAD_BYTES:
        raise ValueError(f"Decoded content exceeds {MAX_UPLOAD_BYTES} byte limit")

    try:
        output_bytes = await asyncio.to_thread(_run_conversion, input_bytes, from_format, to_format)
    except converters.ConversionError as exc:
        raise ValueError(str(exc)) from exc

    result = {
        "content_base64": base64.b64encode(output_bytes).decode("ascii"),
        "mime_type": _MIME_TYPES[to_format],
    }
    return [TextContent(type="text", text=json.dumps(result))]


@app.get("/mcp/sse")
async def mcp_sse(request: Request) -> Response:
    _check_api_key(request)
    async with _sse_transport.connect_sse(
        request.scope, request.receive, request._send
    ) as streams:
        await _mcp_server.run(
            streams[0], streams[1], _mcp_server.create_initialization_options()
        )
    # Empty Response so FastAPI does not attempt a second "http.response.start"
    # after the SSE stream has already completed (matches knowledge-index).
    return Response()


async def _mcp_messages_asgi(scope, receive, send) -> None:  # type: ignore[type-arg]
    """ASGI handler for POST /mcp/messages — bypasses FastAPI response wrapping
    so handle_post_message's own "202 Accepted" isn't double-written (matches
    knowledge-index's identical mounting pattern)."""
    if API_KEY:
        req = Request(scope, receive)
        auth = req.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != API_KEY:
            await Response("Unauthorized", status_code=401)(scope, receive, send)
            return
    await _sse_transport.handle_post_message(scope, receive, send)


app.mount("/mcp/messages", app=_mcp_messages_asgi)
