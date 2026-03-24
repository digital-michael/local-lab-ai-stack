# testing/layer3_model/test_discovery_stubs.py
#
# Layer 3e — Discovery Profile Stub Tests (T-098 through T-102)
#
# Tests the local/WAN discovery profile stub endpoints (Phase 17, D-014a, D-014b):
#   catalog/peers 501 when profile disabled → catalog/registry 501 when profile
#   disabled → catalog/registry 501 when no REGISTRY_URL → catalog/peers 501
#   when no NODES_DIR
#
# These endpoints are stubs:
#   - GET /v1/catalog/peers returns 501 when "local" is not in DISCOVERY_PROFILE
#   - GET /v1/catalog/registry returns 501 when "WAN" is not in DISCOVERY_PROFILE
#     or when REGISTRY_URL is unset
#
# Prerequisites:
#   - knowledge-index service active (custom image)
#
# Entire module is skipped if knowledge-index is not reachable.
#
# Run: pytest testing/layer3_model/test_discovery_stubs.py -v

import httpx
import pytest

from .conftest import KNOWLEDGE_INDEX_URL

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
            "This service requires a custom-built image (Phase 8d)."
        )


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="module")
def ki_client() -> httpx.Client:
    """HTTP client pointed at knowledge-index."""
    with httpx.Client(base_url=KNOWLEDGE_INDEX_URL, timeout=30.0) as client:
        yield client


@pytest.fixture(scope="module")
def ki_headers() -> dict:
    """Headers for authenticated KI requests (reads KI_API_KEY if set)."""
    import os
    key = os.environ.get("KI_API_KEY", "")
    headers = {"Content-Type": "application/json"}
    if key:
        headers["Authorization"] = f"Bearer {key}"
    return headers


# ---------------------------------------------------------------------------
# T-098: GET /v1/catalog/peers — 501 when "local" not in DISCOVERY_PROFILE
# ---------------------------------------------------------------------------

class TestCatalogPeers:
    """Tests for GET /v1/catalog/peers (D-014a local discovery stub)."""

    def test_T098_peers_501_when_local_not_in_profile(
        self, ki_client: httpx.Client, ki_headers: dict
    ):
        """T-098: /v1/catalog/peers returns 501 when default profile is localhost-only.

        The default DISCOVERY_PROFILE is 'localhost' which does not include
        'local', so the endpoint should return HTTP 501.
        """
        resp = ki_client.get("/v1/catalog/peers", headers=ki_headers)
        assert resp.status_code == 501, (
            f"Expected 501 (local not in profile), got {resp.status_code}: "
            f"{resp.text}"
        )
        body = resp.json()
        assert "detail" in body
        assert "local" in body["detail"].lower() or "profile" in body["detail"].lower()

    def test_T099_peers_endpoint_exists(
        self, ki_client: httpx.Client, ki_headers: dict
    ):
        """T-099: /v1/catalog/peers is a registered route (not 404)."""
        resp = ki_client.get("/v1/catalog/peers", headers=ki_headers)
        assert resp.status_code != 404, (
            "GET /v1/catalog/peers returned 404 — endpoint not registered"
        )


# ---------------------------------------------------------------------------
# T-100–T-102: GET /v1/catalog/registry — WAN discovery stub (D-014b)
# ---------------------------------------------------------------------------

class TestCatalogRegistry:
    """Tests for GET /v1/catalog/registry (D-014b WAN discovery stub)."""

    def test_T100_registry_501_when_wan_not_in_profile(
        self, ki_client: httpx.Client, ki_headers: dict
    ):
        """T-100: /v1/catalog/registry returns 501 when WAN not in DISCOVERY_PROFILE.

        The default DISCOVERY_PROFILE is 'localhost' which does not include
        'WAN', so the endpoint should return HTTP 501.
        """
        resp = ki_client.get("/v1/catalog/registry", headers=ki_headers)
        assert resp.status_code == 501, (
            f"Expected 501 (WAN not in profile), got {resp.status_code}: "
            f"{resp.text}"
        )
        body = resp.json()
        assert "detail" in body

    def test_T101_registry_endpoint_exists(
        self, ki_client: httpx.Client, ki_headers: dict
    ):
        """T-101: /v1/catalog/registry is a registered route (not 404)."""
        resp = ki_client.get("/v1/catalog/registry", headers=ki_headers)
        assert resp.status_code != 404, (
            "GET /v1/catalog/registry returned 404 — endpoint not registered"
        )

    def test_T102_registry_returns_json(
        self, ki_client: httpx.Client, ki_headers: dict
    ):
        """T-102: /v1/catalog/registry returns valid JSON even on 501."""
        resp = ki_client.get("/v1/catalog/registry", headers=ki_headers)
        body = resp.json()  # should not raise
        assert isinstance(body, dict)
        assert "detail" in body
