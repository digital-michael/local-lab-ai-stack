# services/knowledge-index/app.py
#
# Knowledge Index Service — Phase 7 (MCP Integration)
#
# REST API:
#   POST /documents          — ingest a document (chunk → embed → store in Qdrant)
#   PUT  /documents/{id}     — replace a document
#   DELETE /documents/{id}   — remove a document from Qdrant
#   POST /query              — vector search over a named collection
#   GET  /health             — readiness probe (used by pytest module-level skip guard)
#
# MCP (Model Context Protocol) — HTTP/SSE transport (D-015):
#   GET  /mcp/sse            — establish SSE stream (MCP clients connect here)
#   POST /mcp/messages       — MCP message channel
#   Tools: search_knowledge, ingest_document
#
# Embedding is performed via the Ollama /api/embeddings endpoint.
# Vector storage is Qdrant (filter-based delete; UUID point IDs per chunk).
# Auth: API_KEY env var guards both REST and MCP endpoints when set.

from __future__ import annotations

import asyncio
import json
import os
import re
import uuid
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException
from mcp.server import Server as McpServer
from mcp.server.sse import SseServerTransport
from mcp.types import TextContent, Tool
from pydantic import BaseModel
from starlette.requests import Request
from starlette.responses import Response

# ---------------------------------------------------------------------------
# Configuration (all overridable via environment variables)
# ---------------------------------------------------------------------------

OLLAMA_URL  = os.environ.get("OLLAMA_URL",   "http://ollama.ai-stack:11434")
QDRANT_URL  = os.environ.get("QDRANT_URL",   "http://qdrant.ai-stack:6333")
EMBED_MODEL = os.environ.get("EMBED_MODEL",  "llama3.1:8b")
QDRANT_KEY  = os.environ.get("QDRANT_API_KEY", "")
CHUNK_SIZE  = int(os.environ.get("CHUNK_SIZE", "400"))   # max chars per chunk
API_KEY     = os.environ.get("API_KEY", "")              # guards /mcp/* and /query when set

# ---------------------------------------------------------------------------
# HTTP clients (module-level singletons; closed on shutdown if needed)
# ---------------------------------------------------------------------------

_qdrant_headers: dict[str, str] = {"Content-Type": "application/json"}
if QDRANT_KEY:
    _qdrant_headers["api-key"] = QDRANT_KEY

_qdrant = httpx.Client(base_url=QDRANT_URL, timeout=30.0, headers=_qdrant_headers)
_ollama = httpx.Client(base_url=OLLAMA_URL, timeout=120.0)

# In-memory map: doc_id → collection (survives connection reuse, lost on restart).
# Sufficient for the test lifecycle (ingest → update → delete in one session).
_doc_collection: dict[str, str] = {}

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="Knowledge Index Service", version="0.1.0")

# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------

class IngestRequest(BaseModel):
    id: str
    content: str
    metadata: dict[str, Any] = {}


class UpdateRequest(BaseModel):
    content: str
    metadata: dict[str, Any] = {}


class QueryRequest(BaseModel):
    query: str
    collection: str
    top_k: int = 5

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _embed(text: str) -> list[float]:
    """Return an embedding vector via the Ollama /api/embeddings endpoint."""
    resp = _ollama.post("/api/embeddings", json={"model": EMBED_MODEL, "prompt": text})
    resp.raise_for_status()
    return resp.json()["embedding"]


def _chunk_text(text: str) -> list[str]:
    """
    Split text into sentence-aware chunks no longer than CHUNK_SIZE characters.
    Falls back to the full text as a single chunk if it is already short enough.
    """
    sentences = re.split(r'(?<=[.!?])\s+', text.strip())
    chunks: list[str] = []
    current = ""
    for sent in sentences:
        candidate = (current + " " + sent).strip() if current else sent
        if len(candidate) <= CHUNK_SIZE:
            current = candidate
        else:
            if current:
                chunks.append(current)
            current = sent
    if current:
        chunks.append(current)
    return chunks if chunks else [text]


def _ensure_collection(collection: str, vector_size: int) -> None:
    """Create a Qdrant collection if it does not already exist."""
    resp = _qdrant.get(f"/collections/{collection}")
    if resp.status_code == 404:
        _qdrant.put(
            f"/collections/{collection}",
            json={"vectors": {"size": vector_size, "distance": "Cosine"}},
        ).raise_for_status()


def _delete_doc_points(collection: str, doc_id: str) -> None:
    """Delete all Qdrant points that belong to a given document."""
    _qdrant.post(
        f"/collections/{collection}/points/delete",
        json={
            "filter": {
                "must": [{"key": "doc_id", "match": {"value": doc_id}}]
            }
        },
    )  # non-fatal if collection doesn't exist yet


def _ingest_chunks(doc_id: str, content: str, metadata: dict, collection: str) -> int:
    """Chunk, embed, and upsert into Qdrant. Returns the number of chunks stored."""
    chunks = _chunk_text(content)
    points: list[dict] = []
    vector_size: int | None = None

    for i, chunk in enumerate(chunks):
        vec = _embed(chunk)
        if vector_size is None:
            vector_size = len(vec)
            _ensure_collection(collection, vector_size)
        points.append({
            "id": str(uuid.uuid4()),
            "vector": vec,
            "payload": {
                "doc_id":      doc_id,
                "chunk_index": i,
                "text":        chunk,
                "source":      metadata.get("source", ""),
                "metadata":    metadata,
            },
        })

    # wait=true: flush to storage before returning so T-063 sees the points immediately
    _qdrant.put(
        f"/collections/{collection}/points?wait=true",
        json={"points": points},
    ).raise_for_status()

    return len(points)

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/documents", status_code=201)
def ingest_document(req: IngestRequest) -> dict:
    collection = req.metadata.get("collection", "default")
    _doc_collection[req.id] = collection
    try:
        n = _ingest_chunks(req.id, req.content, req.metadata, collection)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"id": req.id, "document_id": req.id, "chunks": n}


@app.put("/documents/{doc_id}")
def update_document(doc_id: str, req: UpdateRequest) -> dict:
    collection = req.metadata.get("collection", _doc_collection.get(doc_id, "default"))
    _delete_doc_points(collection, doc_id)
    _doc_collection[doc_id] = collection
    try:
        n = _ingest_chunks(doc_id, req.content, req.metadata, collection)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"id": doc_id, "chunks": n}


@app.delete("/documents/{doc_id}")
def delete_document(doc_id: str) -> dict:
    collection = _doc_collection.get(doc_id, "default")
    _delete_doc_points(collection, doc_id)
    _doc_collection.pop(doc_id, None)
    return {"id": doc_id, "deleted": True}


@app.post("/query")
def query_documents(req: QueryRequest) -> dict:
    try:
        vec = _embed(req.query)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    resp = _qdrant.post(
        f"/collections/{req.collection}/points/search",
        json={"vector": vec, "limit": req.top_k, "with_payload": True},
    )
    if resp.status_code == 404:
        return {"results": []}
    resp.raise_for_status()

    results = []
    for hit in resp.json().get("result", []):
        payload = hit.get("payload", {})
        results.append({
            "text":        payload.get("text", ""),
            "score":       hit.get("score", 0.0),
            "document_id": payload.get("doc_id", ""),
            "source":      payload.get("source", ""),
            "metadata":    payload.get("metadata", {}),
        })
    return {"results": results}


# ---------------------------------------------------------------------------
# MCP — HTTP/SSE transport (D-015)
# Two tools: search_knowledge, ingest_document
# Auth: Bearer token checked against API_KEY env var (when set)
# ---------------------------------------------------------------------------

_mcp_server = McpServer("knowledge-index")
_sse_transport = SseServerTransport("/mcp/messages")


@_mcp_server.list_tools()
async def _list_tools() -> list[Tool]:
    return [
        Tool(
            name="search_knowledge",
            description=(
                "Search the knowledge index using vector similarity. "
                "Returns ranked text chunks with scores and metadata."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "query":      {"type": "string",  "description": "Natural-language search query"},
                    "collection": {"type": "string",  "description": "Qdrant collection to search"},
                    "top_k":      {"type": "integer", "description": "Max results to return", "default": 5},
                },
                "required": ["query", "collection"],
            },
        ),
        Tool(
            name="ingest_document",
            description=(
                "Ingest a document into the knowledge index. "
                "The document is chunked, embedded, and stored in Qdrant."
            ),
            inputSchema={
                "type": "object",
                "properties": {
                    "id":       {"type": "string", "description": "Unique document ID"},
                    "content":  {"type": "string", "description": "Full document text"},
                    "metadata": {
                        "type": "object",
                        "description": "Optional metadata; 'collection' key sets the target Qdrant collection",
                    },
                },
                "required": ["id", "content"],
            },
        ),
    ]


@_mcp_server.call_tool()
async def _call_tool(name: str, arguments: dict) -> list[TextContent]:
    if name == "search_knowledge":
        query      = str(arguments["query"])
        collection = str(arguments["collection"])
        top_k      = int(arguments.get("top_k", 5))

        def _do_search() -> dict:
            vec = _embed(query)
            resp = _qdrant.post(
                f"/collections/{collection}/points/search",
                json={"vector": vec, "limit": top_k, "with_payload": True},
            )
            if resp.status_code == 404:
                return {"results": []}
            resp.raise_for_status()
            results = []
            for hit in resp.json().get("result", []):
                payload = hit.get("payload", {})
                results.append({
                    "text":        payload.get("text", ""),
                    "score":       hit.get("score", 0.0),
                    "document_id": payload.get("doc_id", ""),
                    "source":      payload.get("source", ""),
                })
            return {"results": results}

        result = await asyncio.to_thread(_do_search)
        return [TextContent(type="text", text=json.dumps(result))]

    elif name == "ingest_document":
        doc_id   = str(arguments["id"])
        content  = str(arguments["content"])
        metadata = arguments.get("metadata", {})
        if not isinstance(metadata, dict):
            metadata = {}
        collection = metadata.get("collection", "default")

        def _do_ingest() -> int:
            _doc_collection[doc_id] = collection
            return _ingest_chunks(doc_id, content, metadata, collection)

        n = await asyncio.to_thread(_do_ingest)
        return [TextContent(type="text", text=json.dumps({"id": doc_id, "chunks": n}))]

    else:
        raise ValueError(f"Unknown MCP tool: {name!r}")


def _check_api_key(request: Request) -> None:
    """Raise HTTP 401 if API_KEY is configured and the request does not supply it."""
    if not API_KEY:
        return
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or auth[7:] != API_KEY:
        raise HTTPException(status_code=401, detail="Unauthorized")


@app.get("/mcp/sse")
async def mcp_sse(request: Request) -> Response:
    _check_api_key(request)
    async with _sse_transport.connect_sse(
        request.scope, request.receive, request._send
    ) as streams:
        await _mcp_server.run(
            streams[0], streams[1], _mcp_server.create_initialization_options()
        )
    # Return an empty Response so FastAPI does not attempt to send a second
    # "http.response.start" after the SSE stream has already completed.
    return Response()


# Mount handle_post_message as a raw ASGI endpoint so that FastAPI's response
# wrapper does not add a second HTTP response after handle_post_message has
# already written "202 Accepted" directly to the ASGI send channel.
async def _mcp_messages_asgi(scope, receive, send) -> None:  # type: ignore[type-arg]
    """ASGI handler for POST /mcp/messages — bypasses FastAPI response wrapping."""
    if API_KEY:
        req = Request(scope, receive)
        auth = req.headers.get("Authorization", "")
        if not auth.startswith("Bearer ") or auth[7:] != API_KEY:
            await Response("Unauthorized", status_code=401)(scope, receive, send)
            return
    await _sse_transport.handle_post_message(scope, receive, send)


app.mount("/mcp/messages", app=_mcp_messages_asgi)
