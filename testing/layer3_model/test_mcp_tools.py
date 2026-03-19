# testing/layer3_model/test_mcp_tools.py
#
# Layer 3d — MCP Tool Tests (T-MCP-001 through T-MCP-004)
#
# Tests the MCP HTTP/SSE layer on the knowledge-index service:
#   SSE endpoint availability → tool discovery → ingest_document → search_knowledge
#
# Prerequisites:
#   - T-062 passing (knowledge-index service active)
#   - Qdrant running (Layer 1 T-015 passing)
#   - Ollama running with EMBED_MODEL loaded (T-055 passing)
#   - mcp[server] installed in the knowledge-index container image
#
# Entire module is skipped if knowledge-index is not reachable.
#
# Run: pytest testing/layer3_model/test_mcp_tools.py -v

import asyncio
import os
import uuid

import httpx
import pytest

from .conftest import KNOWLEDGE_INDEX_URL, poll_until

pytestmark = pytest.mark.requires_rag


# ---------------------------------------------------------------------------
# Module-level skip if knowledge-index is not reachable
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module", autouse=True)
def require_knowledge_index():
    """Skip the entire module if knowledge-index HTTP endpoint is not up."""
    try:
        resp = httpx.get(f"{KNOWLEDGE_INDEX_URL}/health", timeout=5.0)
        if resp.status_code not in (200, 204):
            pytest.skip(
                f"knowledge-index /health returned {resp.status_code}. "
                "Build the custom image and start knowledge-index.service first."
            )
    except Exception as exc:
        pytest.skip(
            f"knowledge-index not reachable at {KNOWLEDGE_INDEX_URL}: {exc}. "
            "This service requires a custom-built image (Phase 8d+)."
        )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def ki_client() -> httpx.Client:
    """HTTP client pointed at knowledge-index."""
    with httpx.Client(base_url=KNOWLEDGE_INDEX_URL, timeout=60.0) as client:
        yield client


@pytest.fixture(scope="module")
def mcp_headers() -> dict:
    """
    Authorization header for MCP endpoints.
    Uses API_KEY env var when set; empty dict otherwise (no-auth mode).
    """
    api_key = os.environ.get("API_KEY", "")
    if api_key:
        return {"Authorization": f"Bearer {api_key}"}
    return {}


@pytest.fixture(scope="module")
def test_doc_id() -> str:
    """Unique document ID for this MCP test run."""
    return f"mcp-test-{uuid.uuid4().hex[:8]}"


# ---------------------------------------------------------------------------
# T-MCP-001: SSE endpoint returns correct content-type
# ---------------------------------------------------------------------------

def test_mcp_sse_endpoint_headers(mcp_headers):
    """
    T-MCP-001 — GET /mcp/sse returns HTTP 200 and text/event-stream content-type.

    The connection is opened but immediately closed after checking headers.
    """
    with httpx.stream(
        "GET",
        f"{KNOWLEDGE_INDEX_URL}/mcp/sse",
        headers=mcp_headers,
        timeout=10.0,
    ) as resp:
        assert resp.status_code == 200, (
            f"Expected 200 from /mcp/sse, got {resp.status_code}. "
            "Ensure knowledge-index image includes mcp[server]>=1.6.0."
        )
        content_type = resp.headers.get("content-type", "")
        assert "text/event-stream" in content_type, (
            f"Expected text/event-stream content-type, got: {content_type!r}"
        )


# ---------------------------------------------------------------------------
# T-MCP-002 through T-MCP-004: MCP client tool calls
# ---------------------------------------------------------------------------

def _run_mcp_session(doc_id: str, mcp_headers: dict) -> dict:
    """
    Run a complete MCP session: initialize, ingest_document, search_knowledge.
    Returns a dict with keys: tools, ingest_result, search_result.

    Wrapped in asyncio.run() by each test.
    """
    from mcp import ClientSession
    from mcp.client.sse import sse_client

    sse_url = f"{KNOWLEDGE_INDEX_URL}/mcp/sse"

    async def _session() -> dict:
        async with sse_client(sse_url, headers=mcp_headers) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()

                # List tools
                tools_result = await session.list_tools()
                tool_names = [t.name for t in tools_result.tools]

                # ingest_document
                ingest_resp = await session.call_tool(
                    "ingest_document",
                    {
                        "id": doc_id,
                        "content": (
                            "The MCP HTTP/SSE transport allows agent clients "
                            "to call knowledge index tools over a standard "
                            "HTTP connection without subprocess dependencies."
                        ),
                        "metadata": {"collection": "mcp-test", "source": "mcp-test"},
                    },
                )
                ingest_text = ingest_resp.content[0].text if ingest_resp.content else "{}"

                # search_knowledge
                search_resp = await session.call_tool(
                    "search_knowledge",
                    {
                        "query": "MCP transport agent tools",
                        "collection": "mcp-test",
                        "top_k": 3,
                    },
                )
                search_text = search_resp.content[0].text if search_resp.content else "{}"

                return {
                    "tools": tool_names,
                    "ingest_result": ingest_text,
                    "search_result": search_text,
                }

    return asyncio.run(_session())


@pytest.fixture(scope="module")
def mcp_session_data(test_doc_id, mcp_headers) -> dict:
    """
    Run one MCP session for the entire module; all T-MCP-002/003/004 tests
    share the result to avoid opening multiple SSE connections.
    """
    try:
        from mcp import ClientSession  # noqa: F401 — import check
        from mcp.client.sse import sse_client  # noqa: F401 — import check
    except ImportError:
        pytest.skip(
            "mcp Python SDK not installed in test environment. "
            "Install with: pip install 'mcp[server]>=1.6.0'"
        )
    return _run_mcp_session(test_doc_id, mcp_headers)


def test_mcp_tool_discovery(mcp_session_data):
    """T-MCP-002 — MCP session lists expected tools: search_knowledge and ingest_document."""
    tools = mcp_session_data["tools"]
    assert "search_knowledge" in tools, (
        f"search_knowledge not in tool list: {tools}"
    )
    assert "ingest_document" in tools, (
        f"ingest_document not in tool list: {tools}"
    )


def test_mcp_ingest_document(mcp_session_data):
    """T-MCP-003 — ingest_document tool returns a valid chunks count."""
    import json as _json

    raw = mcp_session_data["ingest_result"]
    data = _json.loads(raw)
    assert "id" in data, f"ingest_document response missing 'id': {raw}"
    assert "chunks" in data, f"ingest_document response missing 'chunks': {raw}"
    assert data["chunks"] >= 1, f"Expected at least 1 chunk, got: {data['chunks']}"


def test_mcp_search_knowledge(mcp_session_data):
    """T-MCP-004 — search_knowledge tool returns results after ingest."""
    import json as _json

    raw = mcp_session_data["search_result"]
    data = _json.loads(raw)
    assert "results" in data, f"search_knowledge response missing 'results': {raw}"
    results = data["results"]
    assert len(results) >= 1, (
        f"Expected at least 1 search result after ingest, got 0. "
        f"Full response: {raw}"
    )
    first = results[0]
    assert "text" in first, f"Result missing 'text' field: {first}"
    assert "score" in first, f"Result missing 'score' field: {first}"
    assert first["score"] > 0.0, f"Expected positive similarity score, got: {first['score']}"
