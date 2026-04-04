# services/knowledge-index/node_registry.py
#
# Phase 22 — Dynamic Node Registration (D-027)
#
# Provides an APIRouter mounted at /admin/v1/nodes by app.py.
# All endpoints are controller-only: they return 403 when
# NODE_PROFILE != "controller".
#
# State machine (lazy — transitions evaluated on GET and heartbeat):
#   unregistered  ──join──►  online
#   online        ──miss──►  caution  (last_seen > CAUTION_THRESHOLD)
#   caution       ──miss──►  failed   (last_seen > FAILED_THRESHOLD)
#   failed        ──time──►  offline  (last_seen > OFFLINE_THRESHOLD)
#   caution/failed ─2×hb──►  online   (2 consecutive healthy heartbeats)
#   offline       ──join──►  online   (explicit re-join with token)
#   any           ─unjoin─►  unregistered

from __future__ import annotations

import hashlib
import json
import os
import uuid
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException
from pydantic import BaseModel
from sqlalchemy import text
from sqlalchemy.engine import Engine
from starlette.requests import Request

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

NODE_PROFILE       = os.environ.get("NODE_PROFILE", "knowledge-worker")
API_KEY            = os.environ.get("API_KEY", "")
KI_ADMIN_KEY       = os.environ.get("KI_ADMIN_KEY", "")
LITELLM_URL        = os.environ.get("LITELLM_URL", "http://litellm.ai-stack:9000")
LITELLM_MASTER_KEY = os.environ.get("LITELLM_MASTER_KEY", "")

# Heartbeat thresholds — overridable via env vars for testing
_CAUTION_THRESHOLD = timedelta(seconds=int(os.environ.get("NODE_CAUTION_SECONDS", "90")))
_FAILED_THRESHOLD  = timedelta(seconds=int(os.environ.get("NODE_FAILED_SECONDS", "150")))
_OFFLINE_THRESHOLD = timedelta(hours=float(os.environ.get("NODE_OFFLINE_HOURS", "24")))

# Maximum gap between two consecutive heartbeats to be considered "healthy"
_HEALTHY_GAP       = timedelta(seconds=int(os.environ.get("NODE_HEALTHY_GAP_SECONDS", "70")))

# ---------------------------------------------------------------------------
# Router
# ---------------------------------------------------------------------------

router = APIRouter(tags=["node-registry"])

# The SQLAlchemy engine is injected via init_router() after _db is initialized
# in app.py.
_db: Engine | None = None


def init_router(db: Engine) -> None:
    """Wire the shared DB engine into the node-registry module."""
    global _db
    _db = db


# ---------------------------------------------------------------------------
# Auth helpers
# ---------------------------------------------------------------------------

def _require_controller() -> None:
    """Raise 403 if not running on a controller node."""
    if NODE_PROFILE != "controller":
        raise HTTPException(status_code=403, detail="Only available on controller nodes")


def _check_admin(request: Request) -> None:
    """Require API_KEY or KI_ADMIN_KEY.  Open (no restriction) when neither is configured."""
    auth  = request.headers.get("Authorization", "")
    token = auth[7:] if auth.startswith("Bearer ") else auth
    if not API_KEY and not KI_ADMIN_KEY:
        return  # dev mode — no keys configured
    if (API_KEY and token == API_KEY) or (KI_ADMIN_KEY and token == KI_ADMIN_KEY):
        return
    raise HTTPException(status_code=401, detail="Unauthorized")


def _check_node_or_admin(request: Request) -> None:
    """Accept the per-node API key, the shared API_KEY, or the admin KI_ADMIN_KEY."""
    auth  = request.headers.get("Authorization", "")
    token = auth[7:] if auth.startswith("Bearer ") else auth
    if not API_KEY and not KI_ADMIN_KEY:
        return
    if (API_KEY and token == API_KEY) or (KI_ADMIN_KEY and token == KI_ADMIN_KEY):
        return
    # Check per-node API key (keyed to the node_id in the URL path)
    node_id = request.path_params.get("node_id")
    if node_id and _db is not None and token:
        token_hash = hashlib.sha256(token.encode()).hexdigest()
        with _db.connect() as conn:
            row = conn.execute(
                text("SELECT node_api_key_hash FROM nodes WHERE node_id = :id"),
                {"id": node_id},
            ).fetchone()
        if row and row[0] and row[0] == token_hash:
            return
    raise HTTPException(status_code=401, detail="Unauthorized")


# ---------------------------------------------------------------------------
# Pydantic request / response models
# ---------------------------------------------------------------------------

class NodeRegisterRequest(BaseModel):
    node_id:      str
    display_name: str             = ""
    profile:      str             = "knowledge-worker"
    address:      str             = ""
    capabilities: dict[str, Any]  = {}


class JoinRequest(BaseModel):
    token:   str
    address: str = ""


class HeartbeatRequest(BaseModel):
    node_id:   str
    timestamp: str                   = ""
    metrics:   dict[str, Any]        = {}
    messages:  list[dict[str, Any]]  = []


class SuggestionCreateRequest(BaseModel):
    suggestion: dict[str, Any]


# ---------------------------------------------------------------------------
# Timestamp helper
# ---------------------------------------------------------------------------

def _parse_ts(ts: Any) -> datetime:
    """Parse a timestamp that arrives as a datetime object (PostgreSQL)
    or as a string (SQLite)."""
    if isinstance(ts, datetime):
        return ts if ts.tzinfo else ts.replace(tzinfo=timezone.utc)
    if isinstance(ts, str):
        for fmt in (
            "%Y-%m-%d %H:%M:%S.%f",
            "%Y-%m-%d %H:%M:%S",
            "%Y-%m-%dT%H:%M:%S.%f",
            "%Y-%m-%dT%H:%M:%S",
        ):
            try:
                return datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
            except ValueError:
                continue
    raise ValueError(f"Cannot parse timestamp: {ts!r}")


# ---------------------------------------------------------------------------
# LiteLLM helpers  (non-fatal — errors are swallowed; LiteLLM is optional)
# ---------------------------------------------------------------------------

def _litellm_add_node(node_id: str, address: str, models: list[str]) -> list[str]:
    """Register a node's models in LiteLLM routing.
    Returns list of LiteLLM model IDs created (for later removal)."""
    if not LITELLM_MASTER_KEY or not address or not models:
        return []
    headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
    ids: list[str] = []
    for model_name in models:
        try:
            resp = httpx.post(
                f"{LITELLM_URL}/model/new",
                headers=headers,
                json={
                    "model_name": f"{node_id}/{model_name}",
                    "litellm_params": {
                        "model":    f"ollama/{model_name}",
                        "api_base": address,
                    },
                },
                timeout=5.0,
            )
            if resp.is_success:
                mid = (resp.json().get("model_info") or {}).get("id", "")
                if mid:
                    ids.append(mid)
        except Exception:
            pass  # LiteLLM unavailable — non-fatal
    return ids


def _litellm_remove_ids(model_ids: list[str]) -> None:
    """Remove models from LiteLLM by their stored IDs."""
    if not LITELLM_MASTER_KEY or not model_ids:
        return
    headers = {"Authorization": f"Bearer {LITELLM_MASTER_KEY}"}
    for mid in model_ids:
        try:
            httpx.post(
                f"{LITELLM_URL}/model/delete",
                headers=headers,
                json={"id": mid},
                timeout=5.0,
            )
        except Exception:
            pass  # non-fatal


# ---------------------------------------------------------------------------
# State machine helpers
# ---------------------------------------------------------------------------

_TERMINAL_STATES       = frozenset({"unregistered", "offline"})
_OUT_OF_ROTATION       = frozenset({"failed", "offline", "unregistered"})


def _transition_down(node_id: str, conn: Any) -> str | None:
    """Lazily evaluate whether a node should move to a lower-health status.

    Transitions (time-based, lazy):
      online  → caution  if last_seen > CAUTION_THRESHOLD
      caution → failed   if last_seen > FAILED_THRESHOLD
      failed  → offline  if last_seen > OFFLINE_THRESHOLD

    Returns the new status if a transition occurred, None otherwise.
    """
    row = conn.execute(
        text("SELECT status, last_seen, litellm_model_ids FROM nodes WHERE node_id = :id"),
        {"id": node_id},
    ).fetchone()

    if not row or not row[1]:
        return None

    status, last_seen_raw, ltm_ids_raw = row[0], row[1], row[2] or "[]"
    if status in _TERMINAL_STATES:
        return None

    ls  = _parse_ts(last_seen_raw)
    age = datetime.now(timezone.utc) - ls

    new_status = status
    if status == "failed" and age >= _OFFLINE_THRESHOLD:
        new_status = "offline"
    elif status in ("online", "caution") and age >= _FAILED_THRESHOLD:
        new_status = "failed"
    elif status == "online" and age >= _CAUTION_THRESHOLD:
        new_status = "caution"

    if new_status == status:
        return None

    conn.execute(
        text("UPDATE nodes SET status = :s WHERE node_id = :id"),
        {"s": new_status, "id": node_id},
    )
    conn.commit()

    # Remove from LiteLLM when node falls out of rotation
    if new_status in _OUT_OF_ROTATION:
        try:
            ids = json.loads(ltm_ids_raw)
        except (json.JSONDecodeError, TypeError):
            ids = []
        if ids:
            _litellm_remove_ids(ids)
            conn.execute(
                text("UPDATE nodes SET litellm_model_ids = '[]' WHERE node_id = :id"),
                {"id": node_id},
            )
            conn.commit()

    return new_status


def _transition_up(node_id: str, conn: Any) -> bool:
    """After a new heartbeat, check if 2 consecutive healthy beats warrant
    an upward transition to 'online'.

    Returns True if the node is now online.
    """
    row = conn.execute(
        text("SELECT status, address, capabilities FROM nodes WHERE node_id = :id"),
        {"id": node_id},
    ).fetchone()
    if not row:
        return False

    status, address, caps_raw = row[0], row[1] or "", row[2] or "{}"
    if status == "online":
        return True   # already online
    if status in _TERMINAL_STATES:
        return False  # terminal states require explicit action

    # Check the last 2 heartbeats (most recent first)
    rows = conn.execute(
        text("""
            SELECT recorded_at FROM node_heartbeats
            WHERE node_id = :id
            ORDER BY recorded_at DESC LIMIT 2
        """),
        {"id": node_id},
    ).fetchall()

    if len(rows) < 2:
        return False  # need at least 2 heartbeats

    t1  = _parse_ts(rows[0][0])
    t2  = _parse_ts(rows[1][0])
    gap = t1 - t2

    if gap > _HEALTHY_GAP:
        return False  # gap too large — not consecutive healthy

    # Transition to online
    conn.execute(
        text("UPDATE nodes SET status = 'online' WHERE node_id = :id"),
        {"id": node_id},
    )
    conn.commit()

    # Add to LiteLLM
    try:
        caps = json.loads(caps_raw)
    except (json.JSONDecodeError, TypeError):
        caps = {}
    models = caps.get("models_loaded") or []
    if models and address:
        ltm_ids = _litellm_add_node(node_id, address, models)
        if ltm_ids:
            conn.execute(
                text("UPDATE nodes SET litellm_model_ids = :ids WHERE node_id = :id"),
                {"ids": json.dumps(ltm_ids), "id": node_id},
            )
            conn.commit()

    return True


# ---------------------------------------------------------------------------
# Endpoints
# ---------------------------------------------------------------------------

@router.post("", status_code=201)
def register_node(req: NodeRegisterRequest, request: Request) -> dict:
    """Register a new node and return a one-time join token.

    Called by ``configure.sh generate-join-token`` on the controller.
    The token is returned only in this response — store it immediately.
    """
    _require_controller()
    _check_admin(request)
    assert _db is not None

    with _db.connect() as conn:
        existing = conn.execute(
            text("SELECT status FROM nodes WHERE node_id = :id"),
            {"id": req.node_id},
        ).fetchone()
        if existing and existing[0] not in ("unregistered",):
            raise HTTPException(
                status_code=409,
                detail=f"Node '{req.node_id}' already exists with status '{existing[0]}'",
            )

    token      = str(uuid.uuid4())
    token_hash = hashlib.sha256(token.encode()).hexdigest()

    with _db.connect() as conn:
        conn.execute(
            text("""
                INSERT INTO nodes
                    (node_id, display_name, profile, address, capabilities,
                     status, token_hash, registered_at)
                VALUES
                    (:node_id, :display_name, :profile, :address, :capabilities,
                     'unregistered', :token_hash, CURRENT_TIMESTAMP)
                ON CONFLICT(node_id) DO UPDATE SET
                    display_name  = excluded.display_name,
                    profile       = excluded.profile,
                    address       = excluded.address,
                    capabilities  = excluded.capabilities,
                    token_hash    = excluded.token_hash,
                    status        = 'unregistered',
                    registered_at = CURRENT_TIMESTAMP
            """),
            {
                "node_id":      req.node_id,
                "display_name": req.display_name,
                "profile":      req.profile,
                "address":      req.address,
                "capabilities": json.dumps(req.capabilities),
                "token_hash":   token_hash,
            },
        )
        conn.commit()

    return {
        "node_id": req.node_id,
        "status":  "unregistered",
        "token":   token,  # one-time; not stored in plaintext
    }


@router.post("/{node_id}/join")
def join_node(node_id: str, req: JoinRequest) -> dict:
    """Present a join token to activate a node.

    Called by ``node.sh join``.  No Authorization header required —
    the token itself is the credential.
    """
    _require_controller()
    assert _db is not None

    token_hash = hashlib.sha256(req.token.encode()).hexdigest()

    with _db.connect() as conn:
        row = conn.execute(
            text("SELECT status, token_hash FROM nodes WHERE node_id = :id"),
            {"id": node_id},
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Node not found — register first")
        if row[1] != token_hash:
            raise HTTPException(status_code=401, detail="Invalid join token")
        if row[0] not in ("unregistered", "offline"):
            raise HTTPException(
                status_code=409,
                detail=f"Node is '{row[0]}'; can only join from unregistered or offline status",
            )

        if req.address:
            conn.execute(
                text("""
                    UPDATE nodes
                    SET status = 'online', address = :addr, last_seen = CURRENT_TIMESTAMP
                    WHERE node_id = :id
                """),
                {"addr": req.address, "id": node_id},
            )
        else:
            conn.execute(
                text("""
                    UPDATE nodes
                    SET status = 'online', last_seen = CURRENT_TIMESTAMP
                    WHERE node_id = :id
                """),
                {"id": node_id},
            )

        node_key      = str(uuid.uuid4())
        node_key_hash = hashlib.sha256(node_key.encode()).hexdigest()
        conn.execute(
            text("UPDATE nodes SET node_api_key_hash = :nkh WHERE node_id = :id"),
            {"nkh": node_key_hash, "id": node_id},
        )
        conn.commit()

    return {"ack": True, "node_id": node_id, "status": "online", "node_api_key": node_key}


@router.post("/{node_id}/heartbeat")
def node_heartbeat(node_id: str, req: HeartbeatRequest, request: Request) -> dict:
    """Receive a heartbeat from a worker node.

    Updates last_seen and node_heartbeats, then evaluates upward transitions.
    Returns ack + pending suggestion count.
    """
    _require_controller()
    _check_node_or_admin(request)
    assert _db is not None

    metrics = req.metrics or {}

    with _db.connect() as conn:
        row = conn.execute(
            text("SELECT status FROM nodes WHERE node_id = :id"),
            {"id": node_id},
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Node not found — register first")
        if row[0] == "unregistered":
            raise HTTPException(status_code=403, detail="Node must join before sending heartbeats")

        hb_id = str(uuid.uuid4())
        conn.execute(
            text("""
                INSERT INTO node_heartbeats
                    (id, node_id, recorded_at,
                     cpu_percent, mem_used_gb, mem_total_gb,
                     gpu_vram_used_mb, requests_last_60s, messages)
                VALUES
                    (:id, :node_id, CURRENT_TIMESTAMP,
                     :cpu, :mem_used, :mem_total,
                     :gpu_vram, :reqs, :messages)
            """),
            {
                "id":       hb_id,
                "node_id":  node_id,
                "cpu":      metrics.get("cpu_percent"),
                "mem_used": metrics.get("mem_used_gb"),
                "mem_total": metrics.get("mem_total_gb"),
                "gpu_vram": metrics.get("gpu_vram_used_mb"),
                "reqs":     metrics.get("requests_last_60s"),
                "messages": json.dumps(req.messages),
            },
        )
        conn.execute(
            text("UPDATE nodes SET last_seen = CURRENT_TIMESTAMP WHERE node_id = :id"),
            {"id": node_id},
        )
        # TODO: refresh capabilities.models_loaded from heartbeat metrics
        # When req.messages carries a "models_loaded" list, extract it here and
        # UPDATE nodes SET capabilities = json_patch(capabilities, '{"models_loaded": [...]}')
        # then re-run _litellm_add_node so LiteLLM routing stays current.
        # Tracked as known debt after Phase 22.
        conn.commit()

        transitioned = _transition_up(node_id, conn)

    with _db.connect() as conn:
        count = conn.execute(
            text("""
                SELECT COUNT(*) FROM node_suggestions
                WHERE node_id = :id AND consumed_at IS NULL
            """),
            {"id": node_id},
        ).fetchone()[0]

    return {
        "ack":                 True,
        "pending_suggestions": count,
        "transitioned_to":     "online" if transitioned and transitioned is True else None,
    }


@router.get("")
def list_nodes(request: Request) -> dict:
    """List all nodes with lazy down-transitions applied."""
    _require_controller()
    _check_admin(request)
    assert _db is not None

    with _db.connect() as conn:
        # Apply lazy down-transitions for all non-terminal nodes
        node_ids = conn.execute(
            text("SELECT node_id, status FROM nodes")
        ).fetchall()
        for nid, status in node_ids:
            if status not in _TERMINAL_STATES:
                _transition_down(nid, conn)

        rows = conn.execute(
            text("""
                SELECT node_id, display_name, profile, address, capabilities,
                       status, registered_at, last_seen
                FROM nodes ORDER BY registered_at
            """)
        ).fetchall()

    nodes = [
        {
            "node_id":       r[0],
            "display_name":  r[1],
            "profile":       r[2],
            "address":       r[3],
            "capabilities":  json.loads(r[4] or "{}"),
            "status":        r[5],
            "registered_at": str(r[6]) if r[6] else None,
            "last_seen":     str(r[7]) if r[7] else None,
        }
        for r in rows
    ]
    return {"count": len(nodes), "nodes": nodes}


@router.get("/{node_id}")
def get_node(node_id: str, request: Request) -> dict:
    """Get a single node with lazy down-transition applied."""
    _require_controller()
    _check_admin(request)
    assert _db is not None

    with _db.connect() as conn:
        _transition_down(node_id, conn)

        row = conn.execute(
            text("""
                SELECT node_id, display_name, profile, address, capabilities,
                       status, registered_at, last_seen
                FROM nodes WHERE node_id = :id
            """),
            {"id": node_id},
        ).fetchone()

    if not row:
        raise HTTPException(status_code=404, detail="Node not found")

    return {
        "node_id":       row[0],
        "display_name":  row[1],
        "profile":       row[2],
        "address":       row[3],
        "capabilities":  json.loads(row[4] or "{}"),
        "status":        row[5],
        "registered_at": str(row[6]) if row[6] else None,
        "last_seen":     str(row[7]) if row[7] else None,
    }


@router.delete("/{node_id}")
def unjoin_node(node_id: str, request: Request) -> dict:
    """Unjoin a node — set status to unregistered and remove from LiteLLM."""
    _require_controller()
    _check_admin(request)
    assert _db is not None

    with _db.connect() as conn:
        row = conn.execute(
            text("SELECT status, litellm_model_ids FROM nodes WHERE node_id = :id"),
            {"id": node_id},
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Node not found")

        ltm_ids: list[str] = []
        try:
            ltm_ids = json.loads(row[1] or "[]")
        except (json.JSONDecodeError, TypeError):
            pass

        conn.execute(
            text("""
                UPDATE nodes
                SET status = 'unregistered', litellm_model_ids = '[]'
                WHERE node_id = :id
            """),
            {"id": node_id},
        )
        conn.commit()

    if ltm_ids:
        _litellm_remove_ids(ltm_ids)

    return {"node_id": node_id, "status": "unregistered"}


@router.get("/{node_id}/suggestions")
def list_suggestions(node_id: str, request: Request) -> dict:
    """List pending (unconsumed) suggestions for a node."""
    _require_controller()
    _check_node_or_admin(request)
    assert _db is not None

    with _db.connect() as conn:
        rows = conn.execute(
            text("""
                SELECT id, created_at, suggestion
                FROM node_suggestions
                WHERE node_id = :id AND consumed_at IS NULL
                ORDER BY created_at
            """),
            {"id": node_id},
        ).fetchall()

    return {
        "node_id":     node_id,
        "count":       len(rows),
        "suggestions": [
            {
                "id":         r[0],
                "created_at": str(r[1]) if r[1] else None,
                "suggestion": json.loads(r[2] or "{}"),
            }
            for r in rows
        ],
    }


@router.post("/{node_id}/suggestions", status_code=201)
def create_suggestion(node_id: str, req: SuggestionCreateRequest, request: Request) -> dict:
    """Create a suggestion for a node (admin only)."""
    _require_controller()
    _check_admin(request)
    assert _db is not None

    with _db.connect() as conn:
        if not conn.execute(
            text("SELECT node_id FROM nodes WHERE node_id = :id"),
            {"id": node_id},
        ).fetchone():
            raise HTTPException(status_code=404, detail="Node not found")

    suggestion_id = f"sugg-{uuid.uuid4()}"
    with _db.connect() as conn:
        conn.execute(
            text("""
                INSERT INTO node_suggestions (id, node_id, created_at, suggestion)
                VALUES (:id, :node_id, CURRENT_TIMESTAMP, :suggestion)
            """),
            {
                "id":         suggestion_id,
                "node_id":    node_id,
                "suggestion": json.dumps(req.suggestion),
            },
        )
        conn.commit()

    return {"id": suggestion_id, "node_id": node_id}


@router.post("/{node_id}/suggestions/{suggestion_id}/consume")
def consume_suggestion(node_id: str, suggestion_id: str, request: Request) -> dict:
    """Mark a suggestion as consumed (applied by the worker)."""
    _require_controller()
    _check_node_or_admin(request)
    assert _db is not None

    with _db.connect() as conn:
        row = conn.execute(
            text("""
                SELECT id, consumed_at FROM node_suggestions
                WHERE id = :sid AND node_id = :nid
            """),
            {"sid": suggestion_id, "nid": node_id},
        ).fetchone()
        if not row:
            raise HTTPException(status_code=404, detail="Suggestion not found")
        if row[1] is not None:
            raise HTTPException(status_code=409, detail="Suggestion already consumed")

        conn.execute(
            text("""
                UPDATE node_suggestions
                SET consumed_at = CURRENT_TIMESTAMP
                WHERE id = :sid
            """),
            {"sid": suggestion_id},
        )
        conn.commit()

    return {"id": suggestion_id, "consumed": True}
