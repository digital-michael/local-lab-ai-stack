# services/knowledge-index/app.py
#
# Knowledge Index Service — Phase 10 (Knowledge-Worker Nodes)
#
# REST API:
#   POST /documents          — ingest a document (chunk → embed → store in Qdrant)
#   PUT  /documents/{id}     — replace a document
#   DELETE /documents/{id}   — remove a document from Qdrant
#   POST /query              — vector search (custody-aware routing on controller)
#   GET  /health             — readiness probe (used by pytest module-level skip guard)
#   POST /v1/libraries       — custody ingest: receive .ai-library package from a worker
#   GET  /v1/catalog         — list all libraries with provenance metadata
#
# Cross-node query routing (D-023 revised, 10.5):
#   On the controller (NODE_PROFILE=controller):
#     1. Query local Qdrant collection as requested
#     2. If empty/404 and collection maps to a custody library — re-query the custody collection
#     3. If still empty and origin node known — proxy to origin worker KI (fallback)
#   On workers (knowledge-worker): local Qdrant only; no routing.
#
# MCP (Model Context Protocol) — HTTP/SSE transport (D-015):
#   GET  /mcp/sse            — establish SSE stream (MCP clients connect here)
#   POST /mcp/messages       — MCP message channel
#   Tools: search_knowledge, ingest_document
#
# Embedding is performed via the Ollama /api/embeddings endpoint.
# Vector storage is Qdrant (filter-based delete; UUID point IDs per chunk).
# Persistence: SQLite on knowledge-worker nodes; PostgreSQL on controller (DATABASE_URL).
# Auth: API_KEY env var guards both REST and MCP endpoints when set.

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
import uuid
from typing import Any

from sqlalchemy import create_engine, text
from sqlalchemy.engine import Engine

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

OLLAMA_URL    = os.environ.get("OLLAMA_URL",    "http://ollama.ai-stack:11434")
QDRANT_URL    = os.environ.get("QDRANT_URL",    "http://qdrant.ai-stack:6333")
EMBED_MODEL   = os.environ.get("EMBED_MODEL",   "llama3.1:8b")
QDRANT_KEY    = os.environ.get("QDRANT_API_KEY", "")
CHUNK_SIZE    = int(os.environ.get("CHUNK_SIZE", "400"))   # max chars per chunk
API_KEY       = os.environ.get("API_KEY", "")              # guards /mcp/* and /query when set
DATABASE_URL  = os.environ.get("DATABASE_URL", "sqlite:///ki.db")  # sqlite (workers) or postgresql (controller)
NODE_PROFILE  = os.environ.get("NODE_PROFILE", "knowledge-worker")  # controller enables cross-node routing
NODE_NAME     = os.environ.get("NODE_NAME", "")            # this node's name (for proxy auth header)
KI_API_KEY    = os.environ.get("KI_API_KEY", API_KEY)      # API key used when proxying to origin workers

# ---------------------------------------------------------------------------
# HTTP clients (module-level singletons; closed on shutdown if needed)
# ---------------------------------------------------------------------------

_qdrant_headers: dict[str, str] = {"Content-Type": "application/json"}
if QDRANT_KEY:
    _qdrant_headers["api-key"] = QDRANT_KEY

_qdrant = httpx.Client(base_url=QDRANT_URL, timeout=30.0, headers=_qdrant_headers)
_ollama = httpx.Client(base_url=OLLAMA_URL, timeout=120.0)

# ---------------------------------------------------------------------------
# Database (SQLite on workers, PostgreSQL on controller — DATABASE_URL selects)
# ---------------------------------------------------------------------------

_db: Engine = create_engine(DATABASE_URL, pool_pre_ping=True)


def _init_db() -> None:
    """Create tables if they do not already exist."""
    with _db.connect() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS documents (
                id         TEXT PRIMARY KEY,
                collection TEXT NOT NULL DEFAULT 'default',
                metadata   TEXT NOT NULL DEFAULT '{}',
                created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS libraries (
                name           TEXT NOT NULL,
                version        TEXT NOT NULL DEFAULT '0.1.0',
                path           TEXT,
                author         TEXT,
                origin_node    TEXT,
                visibility     TEXT NOT NULL DEFAULT 'public',
                checksum_hash  TEXT,
                signature_hash TEXT,
                synced_at      TIMESTAMP,
                PRIMARY KEY (name, version)
            )
        """))
        conn.commit()


_init_db()


def _db_set_doc(doc_id: str, collection: str, metadata: dict | None = None) -> None:
    """Upsert a document record (id → collection + metadata)."""
    meta_json = json.dumps(metadata or {})
    with _db.connect() as conn:
        conn.execute(
            text(
                "INSERT INTO documents (id, collection, metadata) VALUES (:id, :col, :meta)"
                " ON CONFLICT(id) DO UPDATE SET collection = excluded.collection,"
                " metadata = excluded.metadata"
            ),
            {"id": doc_id, "col": collection, "meta": meta_json},
        )
        conn.commit()


def _db_get_doc_collection(doc_id: str, default: str = "default") -> str:
    """Return the collection name for a document, or *default* if not found."""
    with _db.connect() as conn:
        row = conn.execute(
            text("SELECT collection FROM documents WHERE id = :id"),
            {"id": doc_id},
        ).fetchone()
    return row[0] if row else default


def _db_del_doc(doc_id: str) -> None:
    """Delete a document record from the database."""
    with _db.connect() as conn:
        conn.execute(text("DELETE FROM documents WHERE id = :id"), {"id": doc_id})
        conn.commit()


def _db_get_custody_collection(collection: str) -> str | None:
    """
    On the controller, check if *collection* corresponds to a custody library.
    Returns the Qdrant collection name for the library, or None if not found.
    The library collection is named 'lib_{name}_{version}' with non-alphanumeric
    chars replaced by '_'; the match is done by normalising the requested name.
    """
    if NODE_PROFILE != "controller":
        return None
    norm = collection.replace(":", "_").replace(".", "_").replace("-", "_")
    # Exact match against stored lib collections
    with _db.connect() as conn:
        rows = conn.execute(
            text("SELECT name, version FROM libraries")
        ).fetchall()
    for name, version in rows:
        candidate = f"lib_{name}_{version}".replace(":", "_").replace(".", "_").replace("-", "_")
        if candidate == norm or candidate == f"lib_{norm}":
            return candidate
    return None


def _db_get_origin_node_url(collection: str) -> str | None:
    """Return the origin node KI URL for a library collection, or None."""
    if NODE_PROFILE != "controller":
        return None
    norm = collection.replace(":", "_").replace(".", "_").replace("-", "_")
    with _db.connect() as conn:
        rows = conn.execute(
            text("SELECT name, version, origin_node FROM libraries WHERE origin_node IS NOT NULL AND origin_node != ''")
        ).fetchall()
    for name, version, origin_node in rows:
        candidate = f"lib_{name}_{version}".replace(":", "_").replace(".", "_").replace("-", "_")
        if candidate == norm or candidate == f"lib_{norm}":
            # origin_node may be a hostname — KI runs on port 8100
            return f"http://{origin_node}:8100"
    return None


def _qdrant_search(collection: str, vec: list[float], top_k: int) -> list[dict]:
    """Run a vector search against a Qdrant collection; returns [] on 404."""
    resp = _qdrant.post(
        f"/collections/{collection}/points/search",
        json={"vector": vec, "limit": top_k, "with_payload": True},
    )
    if resp.status_code == 404:
        return []
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
    return results


def _proxy_query_to_origin(origin_url: str, req_collection: str, vec_query: str, top_k: int) -> list[dict]:
    """
    Proxy a /query request to the origin worker KI.
    *vec_query* is the natural-language query (origin re-embeds using its own model).
    Returns results list or [] on any error (fallback is always silent).
    """
    proxy_headers: dict[str, str] = {"Content-Type": "application/json"}
    if KI_API_KEY:
        proxy_headers["Authorization"] = f"Bearer {KI_API_KEY}"
    try:
        resp = httpx.post(
            f"{origin_url}/query",
            json={"query": vec_query, "collection": req_collection, "top_k": top_k},
            headers=proxy_headers,
            timeout=15.0,
        )
        if resp.status_code == 200:
            return resp.json().get("results", [])
    except Exception:  # noqa: BLE001 — proxy failure is non-fatal
        pass
    return []

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


class LibraryIngestRequest(BaseModel):
    name: str
    version: str = "0.1.0"
    author: str = ""
    origin_node: str = ""
    visibility: str = "public"
    content: str                   # full text to chunk, embed, and store
    metadata: dict[str, Any] = {}
    checksum: str = ""             # sha256 of content; verified if non-empty
    signature: str = ""            # GPG signature from signature.asc (stored, not verified here)

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
    _db_set_doc(req.id, collection, req.metadata)
    try:
        n = _ingest_chunks(req.id, req.content, req.metadata, collection)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"id": req.id, "document_id": req.id, "chunks": n}


@app.put("/documents/{doc_id}")
def update_document(doc_id: str, req: UpdateRequest) -> dict:
    collection = req.metadata.get("collection", _db_get_doc_collection(doc_id))
    _delete_doc_points(collection, doc_id)
    _db_set_doc(doc_id, collection, req.metadata)
    try:
        n = _ingest_chunks(doc_id, req.content, req.metadata, collection)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    return {"id": doc_id, "chunks": n}


@app.delete("/documents/{doc_id}")
def delete_document(doc_id: str) -> dict:
    collection = _db_get_doc_collection(doc_id)
    _delete_doc_points(collection, doc_id)
    _db_del_doc(doc_id)
    return {"id": doc_id, "deleted": True}


@app.post("/query")
def query_documents(req: QueryRequest) -> dict:
    """Vector search with cross-node custody routing on controller nodes."""
    try:
        vec = _embed(req.query)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    # --- Primary: search the requested collection directly
    results = _qdrant_search(req.collection, vec, req.top_k)

    # --- Controller routing: if primary empty, check custody namespace
    if not results and NODE_PROFILE == "controller":
        custody_col = _db_get_custody_collection(req.collection)
        if custody_col and custody_col != req.collection:
            results = _qdrant_search(custody_col, vec, req.top_k)

        # --- Fallback: proxy to origin worker for unsynced/draft libraries
        if not results:
            origin_url = _db_get_origin_node_url(req.collection)
            if origin_url:
                results = _proxy_query_to_origin(origin_url, req.collection, req.query, req.top_k)

    return {"results": results}


# ---------------------------------------------------------------------------
# Library custody endpoints (D-025)
# ---------------------------------------------------------------------------

@app.post("/v1/libraries", status_code=201)
def ingest_library(req: LibraryIngestRequest, request: Request) -> dict:
    """Receive a .ai-library package from a worker and store it in custody."""
    _check_api_key(request)

    if req.checksum:
        computed = hashlib.sha256(req.content.encode()).hexdigest()
        if computed != req.checksum:
            raise HTTPException(status_code=422, detail="Checksum mismatch")

    checksum_hash = req.checksum or hashlib.sha256(req.content.encode()).hexdigest()
    signature_hash = hashlib.sha256(req.signature.encode()).hexdigest() if req.signature else None

    with _db.connect() as conn:
        conn.execute(
            text(
                "INSERT INTO libraries"
                " (name, version, author, origin_node, visibility, checksum_hash, signature_hash, synced_at)"
                " VALUES (:name, :ver, :author, :origin, :vis, :cksum, :sig, CURRENT_TIMESTAMP)"
                " ON CONFLICT(name, version) DO UPDATE SET"
                " author = excluded.author,"
                " origin_node = excluded.origin_node,"
                " visibility = excluded.visibility,"
                " checksum_hash = excluded.checksum_hash,"
                " signature_hash = excluded.signature_hash,"
                " synced_at = CURRENT_TIMESTAMP"
            ),
            {
                "name": req.name, "ver": req.version, "author": req.author,
                "origin": req.origin_node, "vis": req.visibility,
                "cksum": checksum_hash, "sig": signature_hash,
            },
        )
        conn.commit()

    collection = f"lib_{req.name}_{req.version}".replace(":", "_").replace(".", "_").replace("-", "_")
    doc_id = f"lib:{req.name}:{req.version}"
    _delete_doc_points(collection, doc_id)
    _db_set_doc(doc_id, collection, req.metadata)
    try:
        n = _ingest_chunks(doc_id, req.content, {**req.metadata, "collection": collection}, collection)
    except httpx.HTTPStatusError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc

    return {"name": req.name, "version": req.version, "chunks": n, "status": "ingested"}


@app.get("/v1/catalog")
def list_catalog(request: Request) -> dict:
    """List all libraries held in custody with provenance metadata."""
    _check_api_key(request)
    with _db.connect() as conn:
        rows = conn.execute(
            text(
                "SELECT name, version, author, origin_node, visibility, synced_at"
                " FROM libraries ORDER BY name, version"
            )
        ).fetchall()
    libraries = [
        {
            "name": r[0], "version": r[1], "author": r[2],
            "origin_node": r[3], "visibility": r[4], "synced_at": str(r[5]) if r[5] else None,
        }
        for r in rows
    ]
    return {"count": len(libraries), "libraries": libraries}


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
            results = _qdrant_search(collection, vec, top_k)
            if not results and NODE_PROFILE == "controller":
                custody_col = _db_get_custody_collection(collection)
                if custody_col and custody_col != collection:
                    results = _qdrant_search(custody_col, vec, top_k)
                if not results:
                    origin_url = _db_get_origin_node_url(collection)
                    if origin_url:
                        results = _proxy_query_to_origin(origin_url, collection, query, top_k)
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
            _db_set_doc(doc_id, collection, metadata)
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
