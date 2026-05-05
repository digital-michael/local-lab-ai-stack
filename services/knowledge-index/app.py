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
#   POST /v1/scan            — localhost discovery: scan LIBRARIES_DIR for .ai-library packages
#   GET  /v1/catalog/peers    — local discovery: merged catalog from mDNS-discovered peers (D-014a)
#   GET  /v1/catalog/registry — WAN discovery: search federated registry (D-014b)
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
import pathlib
import re
import sys
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
import node_registry as _nr

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
TAVILY_API_KEY = os.environ.get("TAVILY_API_KEY", "")      # web search; capability flag — 501 when unset
CONTROLLER_KI_URL = os.environ.get("CONTROLLER_KI_URL", "")  # custody push target on enhanced-workers
LIBRARIES_DIR = os.environ.get("LIBRARIES_DIR", "")        # localhost discovery: path to scan for .ai-library packages
DISCOVERY_PROFILE = os.environ.get("DISCOVERY_PROFILE", "localhost")  # comma-separated: localhost,local,WAN (D-014)
REGISTRY_URL  = os.environ.get("REGISTRY_URL", "")         # WAN discovery: federation registry base URL (D-014b)
NODES_DIR     = os.environ.get("NODES_DIR", "")            # path to configs/nodes/ for peer discovery
KI_ADMIN_KEY  = os.environ.get("KI_ADMIN_KEY", "")         # admin bearer token; enables unvetted catalog view (D-035)
CNC_BEARER_TOKEN = os.environ.get("CNC_BEARER_TOKEN", "")  # shared tailnet bearer token for /v1/cnc/* (BL-015)

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
                visibility     TEXT NOT NULL DEFAULT 'private'
                                   CHECK (visibility IN ('public','shared','private','licensed')),
                checksum_hash  TEXT,
                signature_hash TEXT,
                status         TEXT NOT NULL DEFAULT 'unvetted'
                                   CHECK (status IN ('active','unvetted','prohibited')),
                synced_at      TIMESTAMP,
                PRIMARY KEY (name, version)
            )
        """))
        # Migration: add status column to existing databases (new DBs already have it above)
        try:
            conn.execute(text("SAVEPOINT pre_migration"))
            conn.execute(text(
                "ALTER TABLE libraries ADD COLUMN"
                " status TEXT NOT NULL DEFAULT 'unvetted'"
                " CHECK (status IN ('active','unvetted','prohibited'))"
            ))
            conn.execute(text("RELEASE SAVEPOINT pre_migration"))
        except Exception:
            conn.execute(text("ROLLBACK TO SAVEPOINT pre_migration"))

        # Phase 22 — Dynamic Node Registration (D-027)
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS nodes (
                node_id           TEXT PRIMARY KEY,
                display_name      TEXT NOT NULL DEFAULT '',
                profile           TEXT NOT NULL DEFAULT 'knowledge-worker',
                address           TEXT NOT NULL DEFAULT '',
                capabilities      TEXT NOT NULL DEFAULT '{}',
                status            TEXT NOT NULL DEFAULT 'unregistered'
                                      CHECK (status IN ('online','caution','failed','offline','unregistered')),
                token_hash        TEXT,
                litellm_model_ids TEXT NOT NULL DEFAULT '[]',
                registered_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                last_seen         TIMESTAMP
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS node_heartbeats (
                id                TEXT PRIMARY KEY,
                node_id           TEXT NOT NULL REFERENCES nodes(node_id),
                recorded_at       TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                cpu_percent       REAL,
                mem_used_gb       REAL,
                mem_total_gb      REAL,
                gpu_vram_used_mb  INTEGER,
                requests_last_60s INTEGER,
                messages          TEXT NOT NULL DEFAULT '[]'
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS node_suggestions (
                id          TEXT PRIMARY KEY,
                node_id     TEXT NOT NULL REFERENCES nodes(node_id),
                created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                consumed_at TIMESTAMP,
                suggestion  TEXT NOT NULL DEFAULT '{}'
            )
        """))
        # Migration: add node_api_key_hash column to existing databases
        try:
            conn.execute(text("SAVEPOINT pre_node_key_migration"))
            conn.execute(text("ALTER TABLE nodes ADD COLUMN node_api_key_hash TEXT"))
            conn.execute(text("RELEASE SAVEPOINT pre_node_key_migration"))
        except Exception:
            conn.execute(text("ROLLBACK TO SAVEPOINT pre_node_key_migration"))
        # Migration: add last_message column to existing databases
        try:
            conn.execute(text("SAVEPOINT pre_last_message_migration"))
            conn.execute(text(
                "ALTER TABLE nodes ADD COLUMN last_message TEXT NOT NULL DEFAULT ''"
            ))
            conn.execute(text("RELEASE SAVEPOINT pre_last_message_migration"))
        except Exception:
            conn.execute(text("ROLLBACK TO SAVEPOINT pre_last_message_migration"))
        # Migration: add entry_id (surrogate key) and pending_node_id to nodes
        try:
            conn.execute(text("SAVEPOINT pre_entry_id_migration"))
            conn.execute(text("ALTER TABLE nodes ADD COLUMN entry_id TEXT NOT NULL DEFAULT ''"))
            conn.execute(text("ALTER TABLE nodes ADD COLUMN pending_node_id TEXT"))
            conn.execute(text("RELEASE SAVEPOINT pre_entry_id_migration"))
        except Exception:
            conn.execute(text("ROLLBACK TO SAVEPOINT pre_entry_id_migration"))
        # Backfill entry_id for any nodes that don't have one yet
        import uuid as _uuid
        blank_nodes = conn.execute(
            text("SELECT node_id FROM nodes WHERE entry_id = '' OR entry_id IS NULL")
        ).fetchall()
        for (nid,) in blank_nodes:
            conn.execute(
                text("UPDATE nodes SET entry_id = :eid WHERE node_id = :nid"),
                {"eid": str(_uuid.uuid4()), "nid": nid},
            )
        conn.commit()
        # Migration: recreate node_id FKs with ON UPDATE CASCADE so rename works
        try:
            conn.execute(text("SAVEPOINT pre_fk_cascade_migration"))
            conn.execute(text(
                "ALTER TABLE node_heartbeats "
                "DROP CONSTRAINT IF EXISTS node_heartbeats_node_id_fkey, "
                "ADD CONSTRAINT node_heartbeats_node_id_fkey "
                "FOREIGN KEY (node_id) REFERENCES nodes(node_id) ON UPDATE CASCADE ON DELETE CASCADE"
            ))
            conn.execute(text(
                "ALTER TABLE node_suggestions "
                "DROP CONSTRAINT IF EXISTS node_suggestions_node_id_fkey, "
                "ADD CONSTRAINT node_suggestions_node_id_fkey "
                "FOREIGN KEY (node_id) REFERENCES nodes(node_id) ON UPDATE CASCADE ON DELETE CASCADE"
            ))
            conn.execute(text("RELEASE SAVEPOINT pre_fk_cascade_migration"))
        except Exception:
            conn.execute(text("ROLLBACK TO SAVEPOINT pre_fk_cascade_migration"))
        conn.commit()
        # Migration: add alias column — stable join key between DB and configs/nodes/ files
        try:
            conn.execute(text("SAVEPOINT pre_alias_migration"))
            conn.execute(text("ALTER TABLE nodes ADD COLUMN alias TEXT NOT NULL DEFAULT ''"))
            conn.execute(text("RELEASE SAVEPOINT pre_alias_migration"))
        except Exception:
            conn.execute(text("ROLLBACK TO SAVEPOINT pre_alias_migration"))
        conn.commit()


_init_db()

# ---------------------------------------------------------------------------
# Validation constants and admin auth helper (D-035)
# ---------------------------------------------------------------------------

_VALID_VISIBILITY = frozenset({"public", "shared", "private", "licensed"})
_VALID_STATUS     = frozenset({"active", "unvetted", "prohibited"})


def _is_admin(request: Request) -> bool:
    """Return True if the request carries the KI_ADMIN_KEY bearer token (D-035)."""
    if not KI_ADMIN_KEY:
        return False
    auth = request.headers.get("Authorization", "")
    return auth.startswith("Bearer ") and auth[7:].strip() == KI_ADMIN_KEY


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

# Phase 22 — mount node-registry router (controller-only; guards internally)
_nr.init_router(_db)
app.include_router(_nr.router, prefix="/admin/v1/nodes")

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
    visibility: str = "private"    # D-035: access policy (public|shared|private|licensed)
    status: str = "unvetted"       # D-035: lifecycle state (active|unvetted|prohibited)
    content: str                   # full text to chunk, embed, and store
    metadata: dict[str, Any] = {}
    checksum: str = ""             # sha256 of content; verified if non-empty
    signature: str = ""            # GPG signature from signature.asc (stored, not verified here)


class ScanRequest(BaseModel):
    path: str = ""      # override LIBRARIES_DIR; defaults to env var when empty
    force: bool = False  # re-ingest libraries already in catalog

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
# Content Review — Category A/B/C regex gates (D-039 Phase 1)
# ---------------------------------------------------------------------------
# Applied at ingestion endpoints before any Qdrant write or DB write.
# Patterns are a subset of those in configs/litellm/hooks.py; email-address
# is omitted here (legitimate in operator-curated document content).
# ---------------------------------------------------------------------------

_KI_REVIEW_ENABLED: bool = os.environ.get("REVIEW_ENABLED", "true").lower() not in ("false", "0", "no")

_KI_SEC_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r'\bignore\s+(all\s+)?previous\s+instructions?\b', re.I), 'jailbreak:ignore-previous'),
    (re.compile(r'\b(DAN|developer\s+mode|jailbreak|unrestricted\s+mode)\b', re.I), 'jailbreak:mode-switch'),
    (re.compile(r'\bpretend\s+(you\s+are|to\s+be)\b', re.I), 'jailbreak:pretend'),
    (re.compile(r'\byour\s+(true|real|actual|hidden)\s+(self|purpose|instructions?)\b', re.I), 'jailbreak:hidden-self'),
    (re.compile(r'\b(nsenter|unshare|pivot_root|chroot)\b', re.I), 'escape:container-syscall'),
    (re.compile(r'/proc/(self|[0-9]+)/(ns|fd|mem|maps)\b'), 'escape:proc-traversal'),
    (re.compile(r'\b--privileged\b', re.I), 'escape:privileged-flag'),
    (re.compile(r'\b(cap_sys_admin|cap_net_admin|setuid)\b', re.I), 'escape:capability'),
    (re.compile(r'\bsudo\s+(-[si]|bash|sh|su\b)', re.I), 'privesc:sudo-shell'),
    (re.compile(r'\b/etc/(passwd|shadow|sudoers)\b', re.I), 'privesc:sensitive-file'),
    (re.compile(r'__import__\s*\('), 'injection:dunder-import'),
    (re.compile(r'\bsubprocess\.(call|run|Popen|check_output)\s*\(', re.I), 'injection:subprocess'),
    (re.compile(r'\bos\.(system|popen|execv?[ep]?)\s*\(', re.I), 'injection:os-exec'),
    (re.compile(r'\b(base64|b64decode|atob)\b.*\beval\b', re.I | re.S), 'exfil:encoded-exec'),
    (re.compile(r'(.)\1{2000,}', re.S), 'dos:repeated-char'),
    (re.compile(r'\b(pip|pip3)\s+install\s+(?!-r\s)', re.I), 'inject:pip-install'),
]

_KI_PRIV_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r'\b\d{3}-\d{2}-\d{4}\b'), 'pii:ssn'),
    (re.compile(r'\bsession[_-]?token[s]?\s*[=:]\s*\S{10,}\b', re.I), 'privacy:session-token'),
]

_KI_CRED_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r'\bsk-[A-Za-z0-9]{20,}\b'), 'cred:openai-key'),
    (re.compile(r'\bAKIA[0-9A-Z]{16}\b'), 'cred:aws-access-key'),
    (re.compile(r'\bghp_[A-Za-z0-9]{36}\b'), 'cred:github-pat'),
    (re.compile(r'\bghs_[A-Za-z0-9]{36}\b'), 'cred:github-actions-secret'),
    (re.compile(r'\bxox[baprs]-[0-9A-Za-z\-]{10,}\b', re.I), 'cred:slack-token'),
    (re.compile(r'\bAIza[0-9A-Za-z\-_]{35}\b'), 'cred:google-api-key'),
    (re.compile(r'EYJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}'), 'cred:jwt-token'),
    (re.compile(r'[a-zA-Z][a-zA-Z0-9+\-.]*://[^:@\s]+:[^@\s]+@'), 'cred:url-with-password'),
    (re.compile(r'-----BEGIN\s+(?:RSA|EC|DSA|OPENSSH|PGP)?\s*PRIVATE KEY-----'), 'cred:private-key-pem'),
    (re.compile(r'(?:PASSWORD|SECRET|API_KEY|TOKEN|ACCESS_KEY)\s*=\s*[^\s$\'"]{6,}', re.I), 'cred:env-assignment'),
    (re.compile(
        r'(?:litellm_master_key|qdrant_api_key|knowledge_index_api_key|flowise_secret_key)\s*[=:]\s*\S{6,}',
        re.I), 'cred:stack-secret-leaked'),
]


def _ki_log_review_event(
    *, category: str, rule: str, source_endpoint: str, full_content: str, matched_segment: str
) -> None:
    """Write a structured review event to stderr. Never logs raw content or matched values."""
    from datetime import datetime, timezone
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": "WARN",
        "event": "content_review",
        "enforcement_point": "ki_ingestion",
        "category": category,
        "rule": rule,
        "action": "rejected",
        "request_id": source_endpoint,
        "content_hash": hashlib.sha256(full_content[:1024].encode()).hexdigest(),
        "match_hash": hashlib.sha256(matched_segment.encode()).hexdigest()[:8],
    }
    print(json.dumps(record), file=sys.stderr, flush=True)


def _review_content(text: str, *, source_endpoint: str) -> None:
    """
    Apply Category A/B/C content review to ingested document text.
    Raises HTTPException(422) with a generic message on any match.
    Call before any Qdrant write or DB write.
    """
    if not _KI_REVIEW_ENABLED:
        return

    for pattern, rule in _KI_SEC_PATTERNS:
        m = pattern.search(text)
        if m:
            _ki_log_review_event(category="A", rule=rule, source_endpoint=source_endpoint,
                                 full_content=text, matched_segment=m.group(0))
            raise HTTPException(status_code=422, detail="Document rejected by content policy.")

    for pattern, rule in _KI_PRIV_PATTERNS:
        m = pattern.search(text)
        if m:
            _ki_log_review_event(category="B", rule=rule, source_endpoint=source_endpoint,
                                 full_content=text, matched_segment=m.group(0))
            raise HTTPException(status_code=422, detail="Document rejected by content policy.")

    for pattern, rule in _KI_CRED_PATTERNS:
        m = pattern.search(text)
        if m:
            _ki_log_review_event(category="C", rule=rule, source_endpoint=source_endpoint,
                                 full_content=text, matched_segment=m.group(0))
            raise HTTPException(status_code=422, detail="Document rejected by content policy.")

# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.post("/documents", status_code=201)
def ingest_document(req: IngestRequest) -> dict:
    _review_content(req.content, source_endpoint="/documents")
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
    _review_content(req.content, source_endpoint="/v1/libraries")

    if req.visibility not in _VALID_VISIBILITY:
        raise HTTPException(
            status_code=422,
            detail=f"Invalid visibility '{req.visibility}'. Must be one of: {sorted(_VALID_VISIBILITY)}",
        )
    if req.status not in _VALID_STATUS:
        raise HTTPException(
            status_code=422,
            detail=f"Invalid status '{req.status}'. Must be one of: {sorted(_VALID_STATUS)}",
        )

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
                " (name, version, author, origin_node, visibility, status, checksum_hash, signature_hash, synced_at)"
                " VALUES (:name, :ver, :author, :origin, :vis, :status, :cksum, :sig, CURRENT_TIMESTAMP)"
                " ON CONFLICT(name, version) DO UPDATE SET"
                " author = excluded.author,"
                " origin_node = excluded.origin_node,"
                " visibility = excluded.visibility,"
                " status = excluded.status,"
                " checksum_hash = excluded.checksum_hash,"
                " signature_hash = excluded.signature_hash,"
                " synced_at = CURRENT_TIMESTAMP"
            ),
            {
                "name": req.name, "ver": req.version, "author": req.author,
                "origin": req.origin_node, "vis": req.visibility,
                "status": req.status, "cksum": checksum_hash, "sig": signature_hash,
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
    """List all libraries held in custody with provenance metadata.

    Filtering (D-035):
    - prohibited: never returned to any caller
    - unvetted: returned only to admin callers (KI_ADMIN_KEY bearer token)
    """
    _check_api_key(request)
    admin = _is_admin(request)
    with _db.connect() as conn:
        rows = conn.execute(
            text(
                "SELECT name, version, author, origin_node, visibility, status, synced_at, path"
                " FROM libraries ORDER BY name, version"
            )
        ).fetchall()
    libraries = []
    for r in rows:
        lib_status = r[5]
        if lib_status == "prohibited":
            continue                          # never expose prohibited
        if lib_status == "unvetted" and not admin:
            continue                          # unvetted visible to admins only
        libraries.append({
            "name": r[0], "version": r[1], "author": r[2],
            "origin_node": r[3], "visibility": r[4], "status": lib_status,
            "synced_at": str(r[6]) if r[6] else None,
            "path": r[7],
        })
    return {"count": len(libraries), "libraries": libraries}


# ---------------------------------------------------------------------------
# localhost discovery profile helpers (D-013, D-014)
# ---------------------------------------------------------------------------

def _parse_manifest(pkg_dir: pathlib.Path) -> dict[str, Any]:
    """Parse manifest.yaml from a .ai-library package directory.
    Returns a dict with validated fields and defaults.
    Raises ValueError if required fields are missing."""
    import yaml  # deferred: not always installed in minimal worker images

    manifest_path = pkg_dir / "manifest.yaml"
    if not manifest_path.exists():
        raise ValueError("manifest.yaml not found")
    with manifest_path.open() as f:
        data = yaml.safe_load(f) or {}
    if not data.get("name"):
        raise ValueError("manifest.yaml missing required field: name")
    if not data.get("version"):
        raise ValueError("manifest.yaml missing required field: version")
    return {
        "name": str(data["name"]),
        "version": str(data["version"]),
        "author": str(data.get("author", "")),
        "license": str(data.get("license", "")),
        "description": str(data.get("description", "")),
        "profiles": data.get("profiles", ["localhost"]),
    }


def _verify_checksums(pkg_dir: pathlib.Path) -> list[str]:
    """Verify checksums.txt against package contents (sha256sum format).
    Returns a list of error strings.  An empty list means all OK.
    If checksums.txt is absent, returns [] — per D-014 localhost profile
    checksums are strongly recommended but non-fatal when missing."""
    checksums_path = pkg_dir / "checksums.txt"
    if not checksums_path.exists():
        return []
    errors: list[str] = []
    with checksums_path.open() as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split(None, 1)
            if len(parts) != 2:
                continue
            expected_hex, rel_path = parts[0], parts[1].strip()
            target = pkg_dir / rel_path
            if not target.exists():
                errors.append(f"missing: {rel_path}")
                continue
            actual_hex = hashlib.sha256(target.read_bytes()).hexdigest()
            if actual_hex != expected_hex:
                errors.append(f"checksum mismatch: {rel_path}")
    return errors


def _scan_library_package(pkg_dir: pathlib.Path, force: bool) -> dict[str, Any]:
    """Scan one .ai-library package directory, validate, and ingest.
    Returns a result dict with keys: name, version, status, detail, (chunks)."""
    try:
        manifest = _parse_manifest(pkg_dir)
    except Exception as exc:
        return {"package": str(pkg_dir.name), "status": "error", "detail": str(exc)}

    name, version = manifest["name"], manifest["version"]

    if not force:
        with _db.connect() as conn:
            row = conn.execute(
                text("SELECT 1 FROM libraries WHERE name = :n AND version = :v"),
                {"n": name, "v": version},
            ).fetchone()
        if row:
            return {"name": name, "version": version, "status": "skipped",
                    "detail": "already in catalog (use force=true to re-ingest)"}

    checksum_warnings = _verify_checksums(pkg_dir)

    # Concatenate all document files from documents/
    docs_dir = pkg_dir / "documents"
    content_parts: list[str] = []
    if docs_dir.is_dir():
        for doc_file in sorted(docs_dir.iterdir()):
            if doc_file.is_file() and doc_file.suffix in (
                ".txt", ".md", ".rst", ".json", ".yaml", ".yml", ".html"
            ):
                try:
                    content_parts.append(doc_file.read_text(errors="replace"))
                except Exception:
                    pass
    content = "\n\n---\n\n".join(content_parts)
    if not content:
        content = manifest.get("description") or f"Library: {name} v{version}"

    # Read optional metadata.json
    meta: dict[str, Any] = {}
    metadata_path = pkg_dir / "metadata.json"
    if metadata_path.exists():
        try:
            meta = json.loads(metadata_path.read_text())
        except Exception:
            pass

    collection = (
        f"lib_{name}_{version}"
        .replace(":", "_").replace(".", "_").replace("-", "_")
    )
    doc_id = f"lib:{name}:{version}"
    checksum_hash = hashlib.sha256(content.encode()).hexdigest()

    # D-035: read visibility from manifest; default private; clamp to valid values
    vis = manifest.get("visibility", "private")
    if vis not in _VALID_VISIBILITY:
        vis = "private"

    with _db.connect() as conn:
        conn.execute(
            text(
                "INSERT INTO libraries"
                " (name, version, path, author, origin_node, visibility, status, checksum_hash, synced_at)"
                " VALUES (:name, :ver, :path, :author, :origin, :vis, :status, :cksum, CURRENT_TIMESTAMP)"
                " ON CONFLICT(name, version) DO UPDATE SET"
                " path = excluded.path,"
                " author = excluded.author,"
                " origin_node = excluded.origin_node,"
                " visibility = excluded.visibility,"
                " status = excluded.status,"
                " checksum_hash = excluded.checksum_hash,"
                " synced_at = CURRENT_TIMESTAMP"
            ),
            {
                "name": name, "ver": version, "path": str(pkg_dir),
                "author": manifest.get("author", ""), "origin": "localhost",
                "vis": vis, "status": "active", "cksum": checksum_hash,
            },
        )
        conn.commit()

    _delete_doc_points(collection, doc_id)
    _db_set_doc(doc_id, collection, {**meta, "collection": collection, "source": "localhost"})
    try:
        n = _ingest_chunks(doc_id, content, {**meta, "collection": collection, "source": "localhost"}, collection)
    except Exception as exc:
        return {"name": name, "version": version, "status": "error", "detail": str(exc)}

    detail = f"{n} chunks ingested"
    if checksum_warnings:
        detail += f"; checksum warnings: {checksum_warnings}"
    return {"name": name, "version": version, "status": "ingested", "chunks": n, "detail": detail}


@app.post("/v1/scan")
def scan_libraries(req: ScanRequest, request: Request) -> dict:
    """Localhost discovery profile (D-014): scan a directory for .ai-library packages.

    For each subdirectory containing a manifest.yaml the scanner will:
    - Parse and validate manifest.yaml (name + version required)
    - Verify checksums.txt if present (mismatch is reported but non-fatal)
    - Read all supported document files from documents/
    - Ingest document content into Qdrant and register in the libraries catalog

    Libraries already in the catalog are skipped unless force=true.
    """
    _check_api_key(request)
    scan_path = req.path or LIBRARIES_DIR
    if not scan_path:
        raise HTTPException(
            status_code=400,
            detail="No LIBRARIES_DIR configured and no path provided in request body",
        )
    root = pathlib.Path(scan_path)
    if not root.is_dir():
        raise HTTPException(
            status_code=400,
            detail=f"Path does not exist or is not a directory: {scan_path}",
        )

    results: list[dict[str, Any]] = []
    for candidate in sorted(root.iterdir()):
        if candidate.is_dir() and (candidate / "manifest.yaml").exists():
            results.append(_scan_library_package(candidate, req.force))

    ingested = sum(1 for r in results if r.get("status") == "ingested")
    skipped  = sum(1 for r in results if r.get("status") == "skipped")
    errors   = [r for r in results if r.get("status") == "error"]

    return {
        "path": scan_path,
        "scanned": len(results),
        "ingested": ingested,
        "skipped": skipped,
        "errors": errors,
        "results": results,
    }


# ---------------------------------------------------------------------------
# GET /v1/catalog/peers — local profile: merged catalog from peer nodes
# D-014a: In production this would use mDNS/DNS-SD (_ai-library._tcp)
# to discover peers.  For now, reads configs/nodes/*.json and queries
# each node that has "knowledge-index" in its capabilities[] array.
# Returns 501 if "local" is not in DISCOVERY_PROFILE.
# ---------------------------------------------------------------------------

@app.get("/v1/catalog/peers")
def catalog_peers(request: Request) -> dict:
    """Local discovery (D-014a): return merged library catalog from KI-capable peer nodes."""
    _check_api_key(request)

    active_profiles = [p.strip() for p in DISCOVERY_PROFILE.split(",")]
    if "local" not in active_profiles:
        raise HTTPException(
            status_code=501,
            detail="Local discovery profile is not enabled. "
                   "Set DISCOVERY_PROFILE=localhost,local to activate.",
        )

    nodes_dir = NODES_DIR
    if not nodes_dir:
        raise HTTPException(
            status_code=501,
            detail="NODES_DIR not configured — cannot discover peer nodes.",
        )

    nodes_path = pathlib.Path(nodes_dir)
    if not nodes_path.is_dir():
        raise HTTPException(
            status_code=501,
            detail=f"NODES_DIR does not exist: {nodes_dir}",
        )

    peers: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []

    for node_file in sorted(nodes_path.glob("*.json")):
        try:
            node_cfg = json.loads(node_file.read_text())
        except Exception:
            continue

        caps = node_cfg.get("capabilities", [])
        if "knowledge-index" not in caps:
            continue

        node_name = node_cfg.get("name", node_file.stem)
        if node_name == NODE_NAME:
            continue  # skip self

        address = node_cfg.get("address") or node_cfg.get("address_fallback", "")
        if not address:
            continue

        ki_port = node_cfg.get("ki_port", 8100)
        peer_url = f"http://{address}:{ki_port}"

        try:
            resp = httpx.get(
                f"{peer_url}/v1/catalog",
                headers={"Authorization": f"Bearer {KI_API_KEY}"} if KI_API_KEY else {},
                timeout=10.0,
            )
            resp.raise_for_status()
            catalog = resp.json()
            # Filter: only include libraries whose profiles include "local"
            for lib in catalog.get("libraries", []):
                lib["_peer_node"] = node_name
                lib["_peer_url"] = peer_url
            peers.extend(catalog.get("libraries", []))
        except Exception as exc:
            errors.append({"node": node_name, "url": peer_url, "error": str(exc)})

    return {
        "profile": "local",
        "peers_queried": len(peers) + len(errors),
        "libraries": peers,
        "errors": errors,
    }


# ---------------------------------------------------------------------------
# GET /v1/catalog/registry — WAN profile: query federation registry
# D-014b: Returns 501 when REGISTRY_URL is not set.  When set, forwards
# query to the registry's search endpoint and returns the result.
# ---------------------------------------------------------------------------

@app.get("/v1/catalog/registry")
def catalog_registry(request: Request, q: str = "") -> dict:
    """WAN discovery (D-014b): search the federated library registry."""
    _check_api_key(request)

    active_profiles = [p.strip() for p in DISCOVERY_PROFILE.split(",")]
    if "WAN" not in active_profiles:
        raise HTTPException(
            status_code=501,
            detail="WAN discovery profile is not enabled. "
                   "Set DISCOVERY_PROFILE=localhost,local,WAN to activate.",
        )

    if not REGISTRY_URL:
        raise HTTPException(
            status_code=501,
            detail="No REGISTRY_URL configured. A registry server is required "
                   "for WAN discovery (D-014b). This feature is not yet implemented.",
        )

    try:
        resp = httpx.get(
            f"{REGISTRY_URL}/v1/registry/search",
            params={"q": q} if q else {},
            headers={"Authorization": f"Bearer {API_KEY}"} if API_KEY else {},
            timeout=30.0,
        )
        resp.raise_for_status()
        return resp.json()
    except Exception as exc:
        raise HTTPException(
            status_code=502,
            detail=f"Registry query failed: {exc}",
        ) from exc


# ---------------------------------------------------------------------------
# POST /v1/search — web research endpoint (D-031)
# Capability flag: TAVILY_API_KEY env var. Returns HTTP 501 when unset.
# When set: search Tavily → ingest results into local Qdrant → push custody
# to controller (CONTROLLER_KI_URL) if configured.
# Intended for enhanced-worker nodes only; inference-workers return 501.
# ---------------------------------------------------------------------------

class SearchRequest(BaseModel):
    query: str
    max_results: int = 5
    collection: str = "web_research"


@app.post("/v1/search", status_code=200)
async def web_search(req: SearchRequest, request: Request) -> dict:
    """Execute a web search and ingest results into the local knowledge index."""
    _check_api_key(request)

    tavily_key = os.environ.get("TAVILY_API_KEY", "")
    if not tavily_key:
        raise HTTPException(
            status_code=501,
            detail=(
                "Web search is not available on this node: "
                "TAVILY_API_KEY is not configured. "
                "Set this env var to enable the enhanced-worker web_search capability."
            ),
        )

    try:
        from tavily import TavilyClient  # type: ignore[import-untyped]
    except ImportError:
        raise HTTPException(
            status_code=501,
            detail="tavily-python is not installed. Add it to requirements.txt and rebuild.",
        )

    tavily = TavilyClient(api_key=tavily_key)
    search_response = tavily.search(
        query=req.query,
        max_results=req.max_results,
        search_depth="advanced",
        include_raw_content=True,
    )

    results = search_response.get("results", [])
    ingested_ids: list[str] = []

    for result in results:
        content = result.get("raw_content") or result.get("content") or ""
        if not content.strip():
            continue

        doc_id = str(uuid.uuid4())
        metadata = {
            "source": "tavily_web_search",
            "url": result.get("url", ""),
            "title": result.get("title", ""),
            "query": req.query,
            "node": NODE_NAME or "unknown",
        }
        chunk_count = _ingest_chunks(
            doc_id=doc_id,
            content=content,
            metadata=metadata,
            collection=req.collection,
        )
        if chunk_count > 0:
            _db_set_doc(doc_id, req.collection, metadata)
            ingested_ids.append(doc_id)

    # Custody push to controller if configured (D-031 distributed pattern)
    controller_url = os.environ.get("CONTROLLER_KI_URL", "").rstrip("/")
    custody_pushed = False
    if controller_url and ingested_ids:
        push_headers: dict[str, str] = {"Content-Type": "application/json"}
        if KI_API_KEY:
            push_headers["Authorization"] = f"Bearer {KI_API_KEY}"
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                for doc_id in ingested_ids:
                    metadata_entry = {
                        "source": "tavily_web_search",
                        "query": req.query,
                        "node": NODE_NAME or "unknown",
                        "collection": req.collection,
                    }
                    await client.post(
                        f"{controller_url}/v1/libraries",
                        json={
                            "name": f"web_research:{req.query[:40]}",
                            "version": doc_id,
                            "origin_node": NODE_NAME or "unknown",
                            "metadata": metadata_entry,
                        },
                        headers=push_headers,
                    )
            custody_pushed = True
        except Exception:
            custody_pushed = False

    return {
        "query": req.query,
        "results_found": len(results),
        "documents_ingested": len(ingested_ids),
        "collection": req.collection,
        "custody_pushed": custody_pushed,
    }


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


def _check_cnc_bearer(request: Request) -> None:
    """Raise HTTP 401 if CNC_BEARER_TOKEN is configured and the request does not supply it."""
    if not CNC_BEARER_TOKEN:
        return
    auth = request.headers.get("Authorization", "")
    if not auth.startswith("Bearer ") or auth[7:] != CNC_BEARER_TOKEN:
        raise HTTPException(status_code=401, detail="Unauthorized")


# ---------------------------------------------------------------------------
# BL-015: Tailnet bootstrap + CNC namespace
# ---------------------------------------------------------------------------

@app.get("/v1/config")
def tailnet_config() -> dict:
    """Public bootstrap endpoint — no auth required.
    Workers call this at configure time to discover controller_url and capabilities.
    Accessible on the tailnet entrypoint (100.64.0.4:8443); not gated by API_KEY.
    """
    import json as _json
    import pathlib as _pathlib

    # Prefer env vars injected by configure.sh from config.json (non-secret, no file mount needed)
    controller_url = os.environ.get("TAILNET_CONTROLLER_URL", "")
    domain = os.environ.get("TAILNET_DOMAIN", "")
    schema_version = "1.2"

    # Fallback: try to read from config.json if mounted
    if not controller_url:
        for candidate in [
            "/etc/ai-stack/config.json",
            os.path.join(os.environ.get("AI_STACK_DIR", ""), "configs", "config.json"),
        ]:
            if candidate and _pathlib.Path(candidate).exists():
                try:
                    cfg = _json.loads(_pathlib.Path(candidate).read_text())
                    controller_url = cfg.get("tailnet", {}).get("controller_url", "")
                    schema_version = cfg.get("schema_version", "1.2")
                    domain = next(iter(cfg.get("network_domains", {})), "")
                except Exception:
                    pass
                break

    if not controller_url:
        controller_url = os.environ.get("CONTROLLER_URL", "https://100.64.0.4:8443")

    return {
        "controller_url": controller_url,
        "schema_version": schema_version,
        "domain": domain,
        "capabilities": ["inference", "knowledge", "routing"],
    }


class CncRegisterRequest(BaseModel):
    node_id:      str
    alias:        str             = ""
    profile:      str             = "inference-worker"
    os:           str             = ""
    deployment:   str             = ""
    capabilities: list[str]       = []
    models:       list[str]       = []
    version:      str             = ""
    updated_at:   str             = ""


class CncHeartbeatRequest(BaseModel):
    node_id:   str
    alias:     str                   = ""
    timestamp: str                   = ""
    metrics:   dict[str, Any]        = {}
    messages:  list[dict[str, Any]]  = []
    message:   str                   = ""


@app.post("/v1/cnc/register", status_code=201)
def cnc_register(req: CncRegisterRequest, request: Request) -> dict:
    """Register or refresh a worker node over the tailnet (BL-015).
    Requires CNC_BEARER_TOKEN bearer auth.
    Body is the node-config.json schema; mirrors /admin/v1/nodes POST.
    """
    _check_cnc_bearer(request)
    caps_json = json.dumps(req.capabilities)
    with _db.connect() as conn:
        conn.execute(
            text(
                "INSERT INTO nodes (node_id, display_name, profile, address, capabilities, status)"
                " VALUES (:nid, :name, :profile, :addr, :caps, 'unregistered')"
                " ON CONFLICT(node_id) DO UPDATE SET"
                " display_name = excluded.display_name,"
                " profile      = excluded.profile,"
                " capabilities = excluded.capabilities"
            ),
            {
                "nid":     req.node_id,
                "name":    req.alias or req.node_id,
                "profile": req.profile,
                "addr":    "",
                "caps":    caps_json,
            },
        )
        # Also update alias column (added by migration)
        conn.execute(
            text("UPDATE nodes SET alias = :alias WHERE node_id = :nid"),
            {"alias": req.alias, "nid": req.node_id},
        )
        conn.commit()
    return {"node_id": req.node_id, "status": "registered"}


@app.post("/v1/cnc/heartbeat", status_code=204)
def cnc_heartbeat(req: CncHeartbeatRequest, request: Request) -> None:
    """Receive a worker heartbeat over the tailnet (BL-015).
    Requires CNC_BEARER_TOKEN bearer auth.
    Updates last_seen; records heartbeat metrics; evaluates state transitions.
    Returns 204 No Content on success.
    """
    _check_cnc_bearer(request)
    with _db.connect() as conn:
        row = conn.execute(
            text("SELECT status FROM nodes WHERE node_id = :nid"),
            {"nid": req.node_id},
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Node not found — run node.sh configure first")

        conn.execute(
            text("UPDATE nodes SET last_seen = CURRENT_TIMESTAMP WHERE node_id = :nid"),
            {"nid": req.node_id},
        )

        metrics = req.metrics or {}
        conn.execute(
            text(
                "INSERT INTO node_heartbeats"
                " (id, node_id, recorded_at, cpu_percent, mem_used_gb, mem_total_gb,"
                "  gpu_vram_used_mb, requests_last_60s, messages)"
                " VALUES (:id, :nid, CURRENT_TIMESTAMP, :cpu, :mem_used, :mem_total,"
                "         :gpu, :reqs, :msgs)"
            ),
            {
                "id":        str(uuid.uuid4()),
                "nid":       req.node_id,
                "cpu":       float(metrics.get("cpu_percent", 0)),
                "mem_used":  float(metrics.get("mem_used_gb", 0)),
                "mem_total": float(metrics.get("mem_total_gb", 0)),
                "gpu":       int(metrics.get("gpu_vram_used_mb", 0)),
                "reqs":      int(metrics.get("requests_last_60s", 0)),
                "msgs":      json.dumps(req.messages),
            },
        )

        # Promote to 'online' if currently unregistered or offline
        if row[0] in ("unregistered", "offline"):
            conn.execute(
                text("UPDATE nodes SET status = 'online' WHERE node_id = :nid"),
                {"nid": req.node_id},
            )

        conn.commit()
    return None


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
