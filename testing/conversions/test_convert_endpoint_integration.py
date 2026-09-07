# testing/conversions/test_convert_endpoint_integration.py
#
# End-to-end REST API tests against a live conversions service (Phase 1: md<->pdf).
# Entire module is skipped if the conversions service is not reachable.
#
# Run: pytest testing/conversions/test_convert_endpoint_integration.py -v

from __future__ import annotations

import httpx
import pytest

pytestmark = pytest.mark.requires_conversions


@pytest.fixture(scope="module", autouse=True)
def _require_conversions(conversions_available) -> None:
    pass


def test_health_returns_ok(conversions_client: httpx.Client):
    resp = conversions_client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "ok"}


def test_formats_lists_markdown_pdf_pair(conversions_client: httpx.Client):
    resp = conversions_client.get("/formats")
    assert resp.status_code == 200
    body = resp.json()
    assert {"from": "md", "to": "pdf"} in body["implemented"]
    assert {"from": "pdf", "to": "md"} in body["implemented"]


def test_markdown_to_pdf_returns_pdf_bytes(conversions_client: httpx.Client, conversions_headers: dict):
    files = {"file": ("sample.md", b"# Title\n\nBody text.\n")}
    data = {"from_format": "md", "to_format": "pdf"}
    resp = conversions_client.post("/v1/convert", data=data, files=files, headers=conversions_headers)
    assert resp.status_code == 200
    assert resp.content.startswith(b"%PDF")
    assert resp.headers["content-type"] == "application/pdf"


def test_unimplemented_pair_returns_501(conversions_client: httpx.Client, conversions_headers: dict):
    files = {"file": ("sample.xlsx", b"not-a-real-xlsx")}
    data = {"from_format": "xlsx", "to_format": "pdf"}
    resp = conversions_client.post("/v1/convert", data=data, files=files, headers=conversions_headers)
    assert resp.status_code == 501


def test_unknown_format_token_returns_422(conversions_client: httpx.Client, conversions_headers: dict):
    files = {"file": ("sample.txt", b"hello")}
    data = {"from_format": "txt", "to_format": "pdf"}
    resp = conversions_client.post("/v1/convert", data=data, files=files, headers=conversions_headers)
    assert resp.status_code == 422


def test_missing_bearer_token_is_rejected_when_api_key_configured(
    conversions_client: httpx.Client, conversions_api_key: str
):
    if not conversions_api_key:
        pytest.skip("API_KEY is not configured on this deployment — auth check not applicable")
    files = {"file": ("sample.md", b"# Title\n")}
    data = {"from_format": "md", "to_format": "pdf"}
    resp = conversions_client.post("/v1/convert", data=data, files=files)
    assert resp.status_code == 401
