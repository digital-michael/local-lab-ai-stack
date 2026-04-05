# testing/layer3_model/test_node_registry.py
#
# Phase 22 — Dynamic Node Registration tests (T-120 through T-127)
#
# T-120: generate-join-token creates a 'nodes' row with status 'unregistered'
# T-121: join with valid token sets status 'online'
# T-122: heartbeat updates node_heartbeats + last_seen, returns ack
# T-123: Stale last_seen triggers status down-transitions + LiteLLM removal
# T-124: 2 consecutive healthy heartbeats → 'online' + LiteLLM re-add
# T-125: DELETE /admin/v1/nodes/{id} sets status 'unregistered'
# T-126: failed → offline transition; re-join → online
# T-127: GET suggestions + consume → consumed_at set
#
# Run:
#   pytest testing/layer3_model/test_node_registry.py -v
#   pytest testing/layer3_model/test_node_registry.py -v -k T122

from __future__ import annotations

import importlib
import json
import os
import sys
import time
import types
import uuid
from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine, text
from sqlalchemy.pool import StaticPool

# ---------------------------------------------------------------------------
# Path setup — import from services/knowledge-index/
# ---------------------------------------------------------------------------

REPO_ROOT  = Path(__file__).parent.parent.parent
KI_SRC     = REPO_ROOT / "services" / "knowledge-index"

if str(KI_SRC) not in sys.path:
    sys.path.insert(0, str(KI_SRC))

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def in_memory_db():
    """Return a SQLite in-memory engine with node-registry schema applied.
    Uses StaticPool so all connections share the same underlying DB connection."""
    engine = create_engine(
        "sqlite:///:memory:",
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    # Bootstrap schema — keep in sync with _init_db() in app.py
    with engine.connect() as conn:
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS nodes (
                node_id              TEXT PRIMARY KEY,
                display_name         TEXT NOT NULL DEFAULT '',
                profile              TEXT NOT NULL DEFAULT 'knowledge-worker',
                address              TEXT NOT NULL DEFAULT '',
                capabilities         TEXT NOT NULL DEFAULT '{}',
                status               TEXT NOT NULL DEFAULT 'unregistered'
                                         CHECK (status IN ('online','caution','failed','offline','unregistered')),
                token_hash           TEXT,
                litellm_model_ids    TEXT NOT NULL DEFAULT '[]',
                registered_at        TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                last_seen            TIMESTAMP,
                node_api_key_hash    TEXT,
                last_message         TEXT NOT NULL DEFAULT '',
                entry_id             TEXT NOT NULL DEFAULT '',
                pending_node_id      TEXT,
                alias                TEXT NOT NULL DEFAULT ''
            )
        """))
        conn.execute(text("""
            CREATE TABLE IF NOT EXISTS node_heartbeats (
                id                TEXT PRIMARY KEY,
                node_id           TEXT NOT NULL,
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
                node_id     TEXT NOT NULL,
                created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                consumed_at TIMESTAMP,
                suggestion  TEXT NOT NULL DEFAULT '{}'
            )
        """))
        conn.commit()
    return engine


@pytest.fixture(scope="module")
def nr_module(in_memory_db):
    """Load node_registry with controller profile and inject in-memory DB."""
    env_patch = {
        "NODE_PROFILE":          "controller",
        "API_KEY":               "",
        "KI_ADMIN_KEY":          "",
        "LITELLM_URL":           "http://litellm-mock:9000",
        "LITELLM_MASTER_KEY":    "",
        # Short thresholds for transition tests
        "NODE_CAUTION_SECONDS":  "2",
        "NODE_FAILED_SECONDS":   "4",
        "NODE_OFFLINE_HOURS":    "0.001",   # ~3.6 seconds
        "NODE_HEALTHY_GAP_SECONDS": "5",
    }
    with patch.dict(os.environ, env_patch):
        # Force fresh import with patched env
        if "node_registry" in sys.modules:
            del sys.modules["node_registry"]
        import node_registry as nr
        nr.init_router(in_memory_db)
        yield nr


@pytest.fixture(scope="module")
def client(nr_module):
    """TestClient wrapping a minimal FastAPI app with the node-registry router."""
    from fastapi import FastAPI
    mini_app = FastAPI()
    mini_app.include_router(nr_module.router, prefix="/admin/v1/nodes")
    return TestClient(mini_app, raise_server_exceptions=True)


# ---------------------------------------------------------------------------
# T-120: generate-join-token → nodes row with status 'unregistered'
# ---------------------------------------------------------------------------

class TestT120RegisterNode:
    """T-120: POST /admin/v1/nodes creates a row with status 'unregistered'."""

    def test_register_creates_db_row(self, client, in_memory_db):
        node_id = f"test-node-{uuid.uuid4().hex[:8]}"
        resp = client.post(
            "/admin/v1/nodes",
            json={"node_id": node_id, "display_name": "Test Node", "profile": "knowledge-worker"},
        )
        assert resp.status_code == 201, resp.text
        body = resp.json()
        assert body["node_id"] == node_id
        assert body["status"] == "unregistered"
        assert "token" in body
        assert len(body["token"]) > 0

    def test_register_persists_unregistered(self, client, in_memory_db):
        node_id = f"persist-{uuid.uuid4().hex[:8]}"
        resp = client.post("/admin/v1/nodes", json={"node_id": node_id})
        assert resp.status_code == 201

        with in_memory_db.connect() as conn:
            row = conn.execute(
                text("SELECT status FROM nodes WHERE node_id = :id"),
                {"id": node_id},
            ).fetchone()
        assert row is not None, "Node row not found in DB"
        assert row[0] == "unregistered"

    def test_register_duplicate_online_rejected(self, client, in_memory_db):
        node_id = f"dup-{uuid.uuid4().hex[:8]}"
        # First registration
        client.post("/admin/v1/nodes", json={"node_id": node_id})
        # Force online status
        with in_memory_db.connect() as conn:
            conn.execute(
                text("UPDATE nodes SET status = 'online' WHERE node_id = :id"),
                {"id": node_id},
            )
            conn.commit()
        # Duplicate should fail
        resp = client.post("/admin/v1/nodes", json={"node_id": node_id})
        assert resp.status_code == 409


# ---------------------------------------------------------------------------
# T-121: node.sh join → status 'online'
# ---------------------------------------------------------------------------

class TestT121JoinNode:
    """T-121: POST /admin/v1/nodes/{id}/join with valid token → status 'online'."""

    def test_join_valid_token(self, client, in_memory_db):
        node_id = f"join-node-{uuid.uuid4().hex[:8]}"
        reg_resp = client.post("/admin/v1/nodes", json={"node_id": node_id, "address": "http://10.0.0.50:8100"})
        assert reg_resp.status_code == 201
        token = reg_resp.json()["token"]

        join_resp = client.post(
            f"/admin/v1/nodes/{node_id}/join",
            json={"token": token, "address": "http://10.0.0.50:8100"},
        )
        assert join_resp.status_code == 200, join_resp.text
        body = join_resp.json()
        assert body["ack"] is True
        assert body["status"] == "online"

    def test_join_sets_online_in_db(self, client, in_memory_db):
        node_id = f"join-db-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        with in_memory_db.connect() as conn:
            row = conn.execute(
                text("SELECT status FROM nodes WHERE node_id = :id"),
                {"id": node_id},
            ).fetchone()
        assert row[0] == "online"

    def test_join_invalid_token_rejected(self, client, in_memory_db):
        node_id = f"badtoken-{uuid.uuid4().hex[:8]}"
        client.post("/admin/v1/nodes", json={"node_id": node_id})
        resp = client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": "wrong-token"})
        assert resp.status_code == 401

    def test_join_unknown_node_404(self, client):
        resp = client.post("/admin/v1/nodes/nonexistent/join", json={"token": "any"})
        assert resp.status_code == 404


# ---------------------------------------------------------------------------
# T-122: heartbeat → updates node_heartbeats + last_seen, returns ack
# ---------------------------------------------------------------------------

class TestT122Heartbeat:
    """T-122: POST /admin/v1/nodes/{id}/heartbeat → DB updated, ack returned."""

    @pytest.fixture(autouse=True)
    def joined_node(self, client):
        node_id = f"hb-node-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})
        self.node_id = node_id

    def test_heartbeat_returns_ack(self, client):
        resp = client.post(
            f"/admin/v1/nodes/{self.node_id}/heartbeat",
            json={
                "node_id": self.node_id,
                "metrics": {"cpu_percent": 15.5, "mem_used_gb": 2.1, "mem_total_gb": 8.0},
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["ack"] is True
        assert "pending_suggestions" in body

    def test_heartbeat_inserts_db_row(self, client, in_memory_db):
        client.post(
            f"/admin/v1/nodes/{self.node_id}/heartbeat",
            json={"node_id": self.node_id, "metrics": {"cpu_percent": 42.0}},
        )
        with in_memory_db.connect() as conn:
            count = conn.execute(
                text("SELECT COUNT(*) FROM node_heartbeats WHERE node_id = :id"),
                {"id": self.node_id},
            ).fetchone()[0]
        assert count >= 1

    def test_heartbeat_updates_last_seen(self, client, in_memory_db):
        before = datetime.now(timezone.utc)
        client.post(
            f"/admin/v1/nodes/{self.node_id}/heartbeat",
            json={"node_id": self.node_id},
        )
        with in_memory_db.connect() as conn:
            row = conn.execute(
                text("SELECT last_seen FROM nodes WHERE node_id = :id"),
                {"id": self.node_id},
            ).fetchone()
        assert row[0] is not None

    def test_heartbeat_unjoined_node_rejected(self, client, in_memory_db):
        node_id = f"unjoined-{uuid.uuid4().hex[:8]}"
        client.post("/admin/v1/nodes", json={"node_id": node_id})  # registered only
        resp = client.post(f"/admin/v1/nodes/{node_id}/heartbeat", json={"node_id": node_id})
        assert resp.status_code == 403


# ---------------------------------------------------------------------------
# T-123: Stale last_seen → down-transitions + LiteLLM removal
# ---------------------------------------------------------------------------

class TestT123DownTransitions:
    """T-123: Missed heartbeats cause status down-transitions and LiteLLM removal."""

    def _set_last_seen(self, db, node_id, seconds_ago):
        ds = datetime.now(timezone.utc) - timedelta(seconds=seconds_ago)
        with db.connect() as conn:
            conn.execute(
                text("UPDATE nodes SET last_seen = :ts WHERE node_id = :id"),
                {"ts": ds.strftime("%Y-%m-%d %H:%M:%S.%f"), "id": node_id},
            )
            conn.commit()

    def test_online_to_caution(self, client, in_memory_db, nr_module):
        node_id = f"caution-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        # Simulate stale: beyond CAUTION_THRESHOLD (2s in test env)
        self._set_last_seen(in_memory_db, node_id, seconds_ago=3)

        resp = client.get(f"/admin/v1/nodes/{node_id}")
        assert resp.status_code == 200
        assert resp.json()["status"] == "caution"

    def test_caution_to_failed(self, client, in_memory_db, nr_module):
        node_id = f"failed-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        # Simulate stale: beyond FAILED_THRESHOLD (4s in test env)
        self._set_last_seen(in_memory_db, node_id, seconds_ago=5)

        resp = client.get(f"/admin/v1/nodes/{node_id}")
        assert resp.status_code == 200
        assert resp.json()["status"] == "failed"

    def test_litellm_removal_called_on_transition(self, client, in_memory_db, nr_module):
        node_id = f"ltm-remove-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        # Insert fake LiteLLM model IDs
        fake_ids = ["ltm-model-abc", "ltm-model-def"]
        with in_memory_db.connect() as conn:
            conn.execute(
                text("UPDATE nodes SET litellm_model_ids = :ids WHERE node_id = :id"),
                {"ids": json.dumps(fake_ids), "id": node_id},
            )
            conn.commit()

        self._set_last_seen(in_memory_db, node_id, seconds_ago=5)

        removed_ids: list[str] = []

        def fake_remove(ids):
            removed_ids.extend(ids)

        with patch.object(nr_module, "_litellm_remove_ids", side_effect=fake_remove):
            client.get(f"/admin/v1/nodes/{node_id}")

        assert fake_ids[0] in removed_ids


# ---------------------------------------------------------------------------
# T-124: 2 consecutive healthy heartbeats → online + LiteLLM re-add
# ---------------------------------------------------------------------------

class TestT124UpTransition:
    """T-124: 2 consecutive healthy heartbeats restore 'online' status."""

    def test_caution_to_online_on_two_heartbeats(self, client, in_memory_db):
        node_id = f"recover-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        # Force caution status
        with in_memory_db.connect() as conn:
            conn.execute(
                text("UPDATE nodes SET status = 'caution' WHERE node_id = :id"),
                {"id": node_id},
            )
            conn.commit()

        # First heartbeat — not enough yet
        client.post(f"/admin/v1/nodes/{node_id}/heartbeat", json={"node_id": node_id})
        with in_memory_db.connect() as conn:
            status = conn.execute(
                text("SELECT status FROM nodes WHERE node_id = :id"),
                {"id": node_id},
            ).fetchone()[0]
        assert status != "online"  # still caution (only 1 heartbeat)

        # Second heartbeat within _HEALTHY_GAP (5s in test env) → online
        client.post(f"/admin/v1/nodes/{node_id}/heartbeat", json={"node_id": node_id})
        with in_memory_db.connect() as conn:
            status = conn.execute(
                text("SELECT status FROM nodes WHERE node_id = :id"),
                {"id": node_id},
            ).fetchone()[0]
        assert status == "online"

    def test_litellm_add_called_on_recovery(self, client, in_memory_db, nr_module):
        node_id = f"ltm-add-{uuid.uuid4().hex[:8]}"
        token = client.post(
            "/admin/v1/nodes",
            json={
                "node_id": node_id,
                "address": "http://10.0.0.99:8100",
                "capabilities": {"models_loaded": ["llama3.1:8b"]},
            },
        ).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token, "address": "http://10.0.0.99:8100"})

        with in_memory_db.connect() as conn:
            conn.execute(
                text("UPDATE nodes SET status = 'caution' WHERE node_id = :id"),
                {"id": node_id},
            )
            conn.commit()

        added_calls: list[tuple] = []

        def fake_add(nid, addr, models):
            added_calls.append((nid, addr, models))
            return []

        with patch.object(nr_module, "_litellm_add_node", side_effect=fake_add):
            client.post(f"/admin/v1/nodes/{node_id}/heartbeat", json={"node_id": node_id})
            client.post(f"/admin/v1/nodes/{node_id}/heartbeat", json={"node_id": node_id})

        assert any(call[0] == node_id for call in added_calls), \
            f"_litellm_add_node never called with {node_id}; calls={added_calls}"


# ---------------------------------------------------------------------------
# T-125: node.sh unjoin → unregistered, absent from LiteLLM
# ---------------------------------------------------------------------------

class TestT125Unjoin:
    """T-125: DELETE /admin/v1/nodes/{id} → status 'unregistered' + LiteLLM removal."""

    def test_unjoin_sets_unregistered(self, client, in_memory_db):
        node_id = f"unjoin-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        resp = client.delete(f"/admin/v1/nodes/{node_id}")
        assert resp.status_code == 200
        assert resp.json()["status"] == "unregistered"

    def test_unjoin_persists_in_db(self, client, in_memory_db):
        node_id = f"unjoin-db-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})
        client.delete(f"/admin/v1/nodes/{node_id}")

        with in_memory_db.connect() as conn:
            row = conn.execute(
                text("SELECT status FROM nodes WHERE node_id = :id"),
                {"id": node_id},
            ).fetchone()
        assert row[0] == "unregistered"

    def test_unjoin_calls_litellm_remove(self, client, in_memory_db, nr_module):
        node_id = f"unjoin-ltm-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        fake_ids = ["ltm-xyz"]
        with in_memory_db.connect() as conn:
            conn.execute(
                text("UPDATE nodes SET litellm_model_ids = :ids WHERE node_id = :id"),
                {"ids": json.dumps(fake_ids), "id": node_id},
            )
            conn.commit()

        removed: list[str] = []
        with patch.object(nr_module, "_litellm_remove_ids", side_effect=lambda ids: removed.extend(ids)):
            client.delete(f"/admin/v1/nodes/{node_id}")

        assert "ltm-xyz" in removed


# ---------------------------------------------------------------------------
# T-126: failed ≥ threshold → offline; re-join → online
# ---------------------------------------------------------------------------

class TestT126OfflineAndRejoin:
    """T-126: failed ≥ OFFLINE_THRESHOLD → offline; re-join with token → online."""

    def test_failed_to_offline_transition(self, client, in_memory_db):
        node_id = f"offline-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        # Put in failed state with a very old last_seen
        # NODE_OFFLINE_HOURS = 0.001 ≈ 3.6 s; use 5s ago
        stale_ts = (datetime.now(timezone.utc) - timedelta(seconds=5)).strftime(
            "%Y-%m-%d %H:%M:%S.%f"
        )
        with in_memory_db.connect() as conn:
            conn.execute(
                text("UPDATE nodes SET status = 'failed', last_seen = :ts WHERE node_id = :id"),
                {"ts": stale_ts, "id": node_id},
            )
            conn.commit()

        resp = client.get(f"/admin/v1/nodes/{node_id}")
        assert resp.status_code == 200
        assert resp.json()["status"] == "offline"

    def test_offline_rejoin_with_token(self, client, in_memory_db):
        node_id = f"rejoin-{uuid.uuid4().hex[:8]}"
        resp = client.post("/admin/v1/nodes", json={"node_id": node_id})
        token = resp.json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})

        # Force offline
        with in_memory_db.connect() as conn:
            conn.execute(
                text("UPDATE nodes SET status = 'offline' WHERE node_id = :id"),
                {"id": node_id},
            )
            conn.commit()

        # Re-join (same token still valid — hash is preserved)
        rejoin = client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})
        assert rejoin.status_code == 200
        assert rejoin.json()["status"] == "online"


# ---------------------------------------------------------------------------
# T-127: GET suggestions + suggestions apply → consumed_at set
# ---------------------------------------------------------------------------

class TestT127Suggestions:
    """T-127: Create suggestion, list it, consume it → consumed_at set."""

    @pytest.fixture(autouse=True)
    def setup_node(self, client, in_memory_db):
        node_id = f"sugg-{uuid.uuid4().hex[:8]}"
        token = client.post("/admin/v1/nodes", json={"node_id": node_id}).json()["token"]
        client.post(f"/admin/v1/nodes/{node_id}/join", json={"token": token})
        self.node_id = node_id
        self.client = client
        self.db = in_memory_db

    def test_create_and_list_suggestion(self):
        # Create
        resp = self.client.post(
            f"/admin/v1/nodes/{self.node_id}/suggestions",
            json={"suggestion": {"action": "upgrade", "target": "llama3.2:3b"}},
        )
        assert resp.status_code == 201
        sugg_id = resp.json()["id"]
        assert sugg_id.startswith("sugg-")

        # List
        resp = self.client.get(f"/admin/v1/nodes/{self.node_id}/suggestions")
        assert resp.status_code == 200
        body = resp.json()
        assert body["count"] >= 1
        ids = [s["id"] for s in body["suggestions"]]
        assert sugg_id in ids

    def test_consume_sets_consumed_at(self):
        # Create
        sugg_id = self.client.post(
            f"/admin/v1/nodes/{self.node_id}/suggestions",
            json={"suggestion": {"action": "pull", "model": "qwen2.5:7b"}},
        ).json()["id"]

        # Consume
        resp = self.client.post(
            f"/admin/v1/nodes/{self.node_id}/suggestions/{sugg_id}/consume"
        )
        assert resp.status_code == 200
        assert resp.json()["consumed"] is True

        # Verify consumed_at in DB
        with self.db.connect() as conn:
            row = conn.execute(
                text("SELECT consumed_at FROM node_suggestions WHERE id = :id"),
                {"id": sugg_id},
            ).fetchone()
        assert row[0] is not None

    def test_consume_twice_rejected(self):
        sugg_id = self.client.post(
            f"/admin/v1/nodes/{self.node_id}/suggestions",
            json={"suggestion": {"action": "noop"}},
        ).json()["id"]

        self.client.post(f"/admin/v1/nodes/{self.node_id}/suggestions/{sugg_id}/consume")
        resp = self.client.post(
            f"/admin/v1/nodes/{self.node_id}/suggestions/{sugg_id}/consume"
        )
        assert resp.status_code == 409

    def test_heartbeat_reports_pending_count(self):
        # Create 2 suggestions
        self.client.post(
            f"/admin/v1/nodes/{self.node_id}/suggestions",
            json={"suggestion": {"action": "a"}},
        )
        self.client.post(
            f"/admin/v1/nodes/{self.node_id}/suggestions",
            json={"suggestion": {"action": "b"}},
        )

        resp = self.client.post(
            f"/admin/v1/nodes/{self.node_id}/heartbeat",
            json={"node_id": self.node_id},
        )
        assert resp.status_code == 200
        assert resp.json()["pending_suggestions"] >= 2
