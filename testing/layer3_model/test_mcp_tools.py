# testing/layer3_model/test_mcp_tools.py
#
# Layer 3d — MCP Tool Tests (T-MCP-001 through T-MCP-010)
#
# Tests both MCP transports on the knowledge-index service (D-042):
#   /mcp       — Streamable HTTP (current spec; use this for new clients)
#   /mcp/sse   — legacy HTTP/SSE (D-015; spec-deprecated, kept for stragglers)
# For each transport: endpoint reachability -> tool discovery -> ingest_document
# -> search_knowledge. Also covers the transport-security behaviour Streamable
# HTTP requires (DNS-rebinding protection via Host header allowlist).
#
# Prerequisites:
#   - T-062 passing (knowledge-index service active)
#   - Qdrant running (Layer 1 T-015 passing)
#   - Ollama running with EMBED_MODEL loaded (T-055 passing)
#   - mcp[server]>=1.6.0 installed in the test environment and the
#     knowledge-index container image
#
# Entire module is skipped if knowledge-index is not reachable.
#
# Run: pytest testing/layer3_model/test_mcp_tools.py -v

import asyncio
import json as _json
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
def mcp_headers(ki_headers: dict) -> dict:
    """
    Authorization header for MCP endpoints.
    Delegates to ki_headers (resolved from KI_API_KEY or Podman secret).
    """
    return ki_headers


# ---------------------------------------------------------------------------
# T-MCP-001 / T-MCP-005: transport endpoints are reachable with correct headers
# ---------------------------------------------------------------------------

def test_mcp_sse_endpoint_headers(mcp_headers):
    """
    T-MCP-001 — GET /mcp/sse (legacy transport) returns HTTP 200 and
    text/event-stream content-type. The connection is opened but immediately
    closed after checking headers.
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


def test_mcp_streamable_endpoint_initialize(mcp_headers):
    """
    T-MCP-005 — POST /mcp (Streamable HTTP, current spec transport) accepts an
    initialize request and returns a 200 with a well-formed JSON-RPC result.
    Regression guard for the https->http redirect-downgrade bug fixed in D-042
    (Authorization must survive the /mcp -> /mcp/ trailing-slash redirect).
    """
    resp = httpx.post(
        f"{KNOWLEDGE_INDEX_URL}/mcp",
        headers={
            **mcp_headers,
            "Accept": "application/json, text/event-stream",
        },
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "pytest", "version": "0.0"},
            },
        },
        follow_redirects=True,
        timeout=10.0,
    )
    assert resp.status_code == 200, (
        f"Expected 200 from /mcp initialize, got {resp.status_code}: {resp.text}"
    )
    # Response is an SSE-framed body ("event: message\ndata: {...}"); the
    # JSON-RPC payload should still be present in the raw text either way.
    assert '"protocolVersion"' in resp.text, (
        f"Expected an initialize result in the response body, got: {resp.text!r}"
    )


def test_mcp_streamable_rejects_unlisted_host(mcp_headers):
    """
    T-MCP-006 — POST /mcp with a Host header not on the DNS-rebinding
    allowlist (_MCP_ALLOWED_HOSTS in app.py) is rejected with 421, per the
    MCP spec's transport security guidance for Streamable HTTP (D-042).
    """
    resp = httpx.post(
        f"{KNOWLEDGE_INDEX_URL}/mcp/",  # trailing slash avoids the redirect hop
        headers={
            **mcp_headers,
            "Host": "evil.attacker.example",
            "Accept": "application/json, text/event-stream",
        },
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": {
                "protocolVersion": "2025-06-18",
                "capabilities": {},
                "clientInfo": {"name": "pytest", "version": "0.0"},
            },
        },
        timeout=10.0,
    )
    assert resp.status_code == 421, (
        f"Expected 421 for an unlisted Host header, got {resp.status_code}: {resp.text}"
    )


# ---------------------------------------------------------------------------
# T-MCP-002/003/004 (legacy SSE) and T-MCP-007/008/009 (Streamable HTTP):
# full MCP client sessions — discovery, ingest_document, search_knowledge
# ---------------------------------------------------------------------------

def _run_mcp_session(doc_id: str, mcp_headers: dict, transport: str) -> dict:
    """
    Run a complete MCP session over the given transport ("sse" or "streamable"):
    initialize, list tools, ingest_document, search_knowledge.
    Returns a dict with keys: tools, ingest_result, search_result.

    Wrapped in asyncio.run() by each test.
    """
    from mcp import ClientSession

    if transport == "sse":
        from mcp.client.sse import sse_client as _client_cm
        url = f"{KNOWLEDGE_INDEX_URL}/mcp/sse"
    else:
        from mcp.client.streamable_http import streamablehttp_client as _client_cm
        url = f"{KNOWLEDGE_INDEX_URL}/mcp"

    async def _session() -> dict:
        async with _client_cm(url, headers=mcp_headers) as streams:
            read, write = streams[0], streams[1]
            async with ClientSession(read, write) as session:
                await session.initialize()

                tools_result = await session.list_tools()
                tool_names = [t.name for t in tools_result.tools]

                collection = f"mcp-test-{transport}"
                ingest_resp = await session.call_tool(
                    "ingest_document",
                    {
                        "id": doc_id,
                        "content": (
                            "The MCP transport allows agent clients to call "
                            "knowledge index tools over a standard HTTP "
                            "connection without subprocess dependencies."
                        ),
                        "metadata": {"collection": collection, "source": "mcp-test"},
                    },
                )
                ingest_text = ingest_resp.content[0].text if ingest_resp.content else "{}"

                search_resp = await session.call_tool(
                    "search_knowledge",
                    {
                        "query": "MCP transport agent tools",
                        "collection": collection,
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


def _mcp_session_fixture(transport: str):
    """Builds a module-scoped fixture running one MCP session for `transport`."""

    @pytest.fixture(scope="module")
    def _fixture(mcp_headers: dict) -> dict:
        try:
            from mcp import ClientSession  # noqa: F401 — import check
            if transport == "sse":
                from mcp.client.sse import sse_client  # noqa: F401
            else:
                from mcp.client.streamable_http import streamablehttp_client  # noqa: F401
        except ImportError:
            pytest.skip(
                "mcp Python SDK not installed in test environment. "
                "Install with: pip install 'mcp[server]>=1.6.0'"
            )
        doc_id = f"mcp-test-{transport}-{uuid.uuid4().hex[:8]}"
        return _run_mcp_session(doc_id, mcp_headers, transport)

    return _fixture


mcp_session_data_sse = _mcp_session_fixture("sse")
mcp_session_data_streamable = _mcp_session_fixture("streamable")


def test_mcp_tool_discovery(mcp_session_data_sse):
    """T-MCP-002 — legacy SSE session lists expected tools."""
    tools = mcp_session_data_sse["tools"]
    assert "search_knowledge" in tools, f"search_knowledge not in tool list: {tools}"
    assert "ingest_document" in tools, f"ingest_document not in tool list: {tools}"


def test_mcp_ingest_document(mcp_session_data_sse):
    """T-MCP-003 — legacy SSE: ingest_document returns a valid chunks count."""
    raw = mcp_session_data_sse["ingest_result"]
    data = _json.loads(raw)
    assert "id" in data, f"ingest_document response missing 'id': {raw}"
    assert "chunks" in data, f"ingest_document response missing 'chunks': {raw}"
    assert data["chunks"] >= 1, f"Expected at least 1 chunk, got: {data['chunks']}"


def test_mcp_search_knowledge(mcp_session_data_sse):
    """T-MCP-004 — legacy SSE: search_knowledge returns results after ingest."""
    raw = mcp_session_data_sse["search_result"]
    data = _json.loads(raw)
    assert "results" in data, f"search_knowledge response missing 'results': {raw}"
    results = data["results"]
    assert len(results) >= 1, (
        f"Expected at least 1 search result after ingest, got 0. Full response: {raw}"
    )
    first = results[0]
    assert "text" in first, f"Result missing 'text' field: {first}"
    assert "score" in first, f"Result missing 'score' field: {first}"
    assert first["score"] > 0.0, f"Expected positive similarity score, got: {first['score']}"


def test_mcp_streamable_tool_discovery(mcp_session_data_streamable):
    """T-MCP-007 — Streamable HTTP session lists expected tools."""
    tools = mcp_session_data_streamable["tools"]
    assert "search_knowledge" in tools, f"search_knowledge not in tool list: {tools}"
    assert "ingest_document" in tools, f"ingest_document not in tool list: {tools}"


def test_mcp_streamable_ingest_document(mcp_session_data_streamable):
    """T-MCP-008 — Streamable HTTP: ingest_document returns a valid chunks count."""
    raw = mcp_session_data_streamable["ingest_result"]
    data = _json.loads(raw)
    assert "id" in data, f"ingest_document response missing 'id': {raw}"
    assert "chunks" in data, f"ingest_document response missing 'chunks': {raw}"
    assert data["chunks"] >= 1, f"Expected at least 1 chunk, got: {data['chunks']}"


def test_mcp_streamable_search_knowledge(mcp_session_data_streamable):
    """T-MCP-009 — Streamable HTTP: search_knowledge returns results after ingest."""
    raw = mcp_session_data_streamable["search_result"]
    data = _json.loads(raw)
    assert "results" in data, f"search_knowledge response missing 'results': {raw}"
    results = data["results"]
    assert len(results) >= 1, (
        f"Expected at least 1 search result after ingest, got 0. Full response: {raw}"
    )
    first = results[0]
    assert "text" in first, f"Result missing 'text' field: {first}"
    assert "score" in first, f"Result missing 'score' field: {first}"
    assert first["score"] > 0.0, f"Expected positive similarity score, got: {first['score']}"
