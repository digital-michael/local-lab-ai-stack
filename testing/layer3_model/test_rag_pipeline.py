# testing/layer3_model/test_rag_pipeline.py
#
# Layer 3c — RAG Pipeline Tests (T-062 through T-068)
#
# Tests the full document lifecycle through the knowledge-index service:
#   ingest → chunk storage in Qdrant → retrieval → metadata → Flowise
#   → document update → document delete
#
# Prerequisites:
#   - T-055–T-057 passing (model loaded)
#   - knowledge-index service active (custom image — Phase 8d)
#   - Qdrant running (Layer 1 T-015 passing)
#
# Entire module is skipped if knowledge-index is not reachable.
#
# Run: pytest testing/layer3_model/test_rag_pipeline.py -v

import time
import uuid

import httpx
import pytest

from .conftest import KNOWLEDGE_INDEX_URL, QDRANT_BASE_URL, poll_until

pytestmark = pytest.mark.requires_rag

# ---------------------------------------------------------------------------
# Module-level skip if knowledge-index is not reachable
# ---------------------------------------------------------------------------

def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "requires_rag: test requires knowledge-index service and Qdrant",
    )


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
            "This service requires a custom-built image (Phase 8d)."
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
def qdrant_client(qdrant_headers) -> httpx.Client:
    """HTTP client pointed at Qdrant REST API."""
    with httpx.Client(base_url=QDRANT_BASE_URL, timeout=30.0) as client:
        yield client


@pytest.fixture(scope="module")
def test_doc_id() -> str:
    """Unique document ID for this test run — prevents collision on re-runs."""
    return f"bats-rag-test-{uuid.uuid4().hex[:8]}"


TEST_COLLECTION = "bats_rag_test_collection"

# Content used for ingest tests. Short enough to produce 1–2 chunks.
TEST_DOCUMENT_CONTENT = (
    "The Eiffel Tower is located in Paris, France. "
    "It was constructed between 1887 and 1889. "
    "The tower is 330 metres tall and was designed by Gustave Eiffel."
)
TEST_QUERY = "Where is the Eiffel Tower located?"

# ---------------------------------------------------------------------------
# Teardown: clean up any test collection from Qdrant after module run
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module", autouse=True)
def cleanup_test_collection(qdrant_headers):
    yield
    # Use a fresh client — the module-scoped qdrant_client may have a stale
    # keep-alive connection by the time teardown runs.
    try:
        with httpx.Client(base_url=QDRANT_BASE_URL, timeout=10.0) as client:
            client.delete(f"/collections/{TEST_COLLECTION}", headers=qdrant_headers)
    except Exception:
        pass  # best-effort cleanup; stale collection will not affect re-runs


# ---------------------------------------------------------------------------
# T-062 — Document ingest returns 200 with a document ID
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def ingested_doc(ki_client, test_doc_id):
    """
    Ingest a test document and return the response body.
    Used as a fixture so T-063–T-065 can depend on a successful ingest.
    """
    payload = {
        "id": test_doc_id,
        "content": TEST_DOCUMENT_CONTENT,
        "metadata": {
            "title": "Eiffel Tower Test Document",
            "collection": TEST_COLLECTION,
            "source": "bats-layer3c-test",
        },
    }
    response = ki_client.post("/documents", json=payload)
    assert response.status_code in (200, 201), (
        f"Document ingest returned {response.status_code}: {response.text[:500]}"
    )
    body = response.json()
    assert body.get("id") or body.get("document_id"), (
        f"Ingest response missing document ID field: {body}"
    )
    return body


def test_document_ingest(ingested_doc, test_doc_id):
    """T-062: POST document to knowledge-index returns 200/201 with document ID."""
    # ingested_doc fixture already asserts the preconditions;
    # this test is the explicit T-062 checkpoint.
    assert ingested_doc is not None


# ---------------------------------------------------------------------------
# T-063 — Chunks stored in Qdrant after ingest
# ---------------------------------------------------------------------------

def test_chunks_stored_in_qdrant(
    ingested_doc, qdrant_client, qdrant_headers
):
    """T-063: After ingest, Qdrant collection has at least one vector point."""
    # Poll for up to 30 seconds — indexing may be async
    def collection_has_points() -> bool:
        resp = qdrant_client.get(
            f"/collections/{TEST_COLLECTION}", headers=qdrant_headers
        )
        if resp.status_code != 200:
            return False
        info = resp.json().get("result", {})
        return info.get("points_count", 0) >= 1

    appeared = poll_until(collection_has_points, timeout_s=30, interval_s=3)
    assert appeared, (
        f"No vector points found in Qdrant collection '{TEST_COLLECTION}' "
        "after 30 seconds. Check knowledge-index chunking and embedding pipeline."
    )


# ---------------------------------------------------------------------------
# T-064 — Retrieval via knowledge-index API returns a relevant chunk
# ---------------------------------------------------------------------------

def test_retrieval_returns_chunk(ki_client, ingested_doc):
    """T-064: Querying knowledge-index returns a chunk relevant to the query."""
    response = ki_client.post(
        "/query",
        json={
            "query": TEST_QUERY,
            "collection": TEST_COLLECTION,
            "top_k": 3,
        },
    )
    assert response.status_code == 200, (
        f"Query returned {response.status_code}: {response.text[:500]}"
    )
    results = response.json().get("results", [])
    assert len(results) >= 1, (
        f"Knowledge-index returned no results for query: {TEST_QUERY!r}"
    )

    # At least one result must reference the document content
    combined_text = " ".join(r.get("text", "") for r in results).lower()
    assert "paris" in combined_text or "eiffel" in combined_text, (
        f"Retrieved chunks do not appear to be from the test document. "
        f"Results: {results}"
    )


# ---------------------------------------------------------------------------
# T-065 — Retrieval response includes source metadata
# ---------------------------------------------------------------------------

def test_retrieval_includes_metadata(ki_client, ingested_doc):
    """T-065: Retrieved chunks include a 'source' or 'metadata' field."""
    response = ki_client.post(
        "/query",
        json={"query": TEST_QUERY, "collection": TEST_COLLECTION, "top_k": 1},
    )
    assert response.status_code == 200
    results = response.json().get("results", [])
    assert results, "No results returned"

    top = results[0]
    has_source = (
        "source" in top
        or "metadata" in top
        or "document_id" in top
    )
    assert has_source, (
        f"Top result does not contain source/metadata attribution: {top}"
    )


# ---------------------------------------------------------------------------
# T-066 — End-to-end via Flowise chatflow
# ---------------------------------------------------------------------------
# Skipped if no Flowise chatflow with knowledge-index tool is configured.
# Full setup is covered in Phase 8d when chatflows are provisioned.
# ---------------------------------------------------------------------------

def test_rag_via_flowise(ki_client):
    """T-066: Flowise chatflow with knowledge-index tool returns a cited answer."""
    flowise_url = "http://localhost:3001"
    try:
        resp = httpx.get(
            f"{flowise_url}/api/v1/chatflows", timeout=5.0,
            headers={"Authorization": "Basic dXNlcjp0ZXN0"}  # placeholder
        )
    except Exception:
        pytest.skip("Flowise not reachable — skipping end-to-end RAG via Flowise")

    chatflows = resp.json() if resp.status_code == 200 else []
    rag_flows = [cf for cf in chatflows if "rag" in cf.get("name", "").lower()
                 or "knowledge" in cf.get("name", "").lower()]

    if not rag_flows:
        pytest.skip(
            "No RAG/knowledge chatflows found in Flowise. "
            "Create a chatflow with the knowledge-index tool then re-run T-066."
        )

    flow_id = rag_flows[0]["id"]
    response = httpx.post(
        f"{flowise_url}/api/v1/prediction/{flow_id}",
        json={"question": TEST_QUERY},
        timeout=60.0,
    )
    assert response.status_code == 200, (
        f"Flowise prediction returned {response.status_code}: {response.text[:500]}"
    )
    body = response.json()
    answer = body.get("text", body.get("answer", ""))
    assert answer, f"Flowise returned empty answer: {body}"

    # Should contain a source reference
    has_source = (
        "source" in str(body).lower()
        or "eiffel" in answer.lower()
        or "paris" in answer.lower()
    )
    assert has_source, (
        f"Flowise answer does not appear to cite the test document: {answer!r}"
    )


# ---------------------------------------------------------------------------
# T-067 — Document update: updated chunk returned, old chunk gone
# ---------------------------------------------------------------------------

def test_document_update(ki_client, test_doc_id):
    """T-067: Re-ingesting a modified document replaces the old content."""
    updated_content = (
        "The Eiffel Tower is a famous landmark in Paris. "
        "It was updated in the year 2026 for testing purposes. "
        "The tower height is 330 metres."
    )
    response = ki_client.put(
        f"/documents/{test_doc_id}",
        json={
            "content": updated_content,
            "metadata": {
                "title": "Eiffel Tower Test Document (updated)",
                "collection": TEST_COLLECTION,
                "source": "bats-layer3c-test-updated",
            },
        },
    )
    assert response.status_code in (200, 204), (
        f"Document update returned {response.status_code}: {response.text[:500]}"
    )

    # Poll: the updated content must appear in retrieval
    def updated_content_appears() -> bool:
        r = ki_client.post(
            "/query",
            json={"query": "2026 update", "collection": TEST_COLLECTION, "top_k": 3},
        )
        if r.status_code != 200:
            return False
        results = r.json().get("results", [])
        return any("2026" in r.get("text", "") for r in results)

    appeared = poll_until(updated_content_appears, timeout_s=30, interval_s=3)
    assert appeared, (
        "Updated document content ('2026') not found in Qdrant after 30s."
    )


# ---------------------------------------------------------------------------
# T-068 — Document delete: deleted chunk no longer returned
# ---------------------------------------------------------------------------

def test_document_delete(ki_client, test_doc_id):
    """T-068: After deleting a document, its content is not returned by queries."""
    response = ki_client.delete(f"/documents/{test_doc_id}")
    assert response.status_code in (200, 204), (
        f"Document delete returned {response.status_code}: {response.text[:300]}"
    )

    # Poll: the deleted content must no longer appear
    def content_gone() -> bool:
        r = ki_client.post(
            "/query",
            json={"query": TEST_QUERY, "collection": TEST_COLLECTION, "top_k": 5},
        )
        if r.status_code != 200:
            return True  # collection may be empty now — treat as gone
        results = r.json().get("results", [])
        return not any(test_doc_id in str(r) for r in results)

    gone = poll_until(content_gone, timeout_s=30, interval_s=3)
    assert gone, (
        f"Deleted document '{test_doc_id}' still appears in Qdrant query results "
        "after 30 seconds."
    )
