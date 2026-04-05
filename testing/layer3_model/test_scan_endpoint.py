# testing/layer3_model/test_scan_endpoint.py
#
# Layer 3d — POST /v1/scan Endpoint Tests (T-070 through T-074)
#
# Tests the localhost discovery profile (Phase 15, D-013, D-014):
#   scan → ingest → skip-existing → force-reingest → 400 on bad path → catalog check
#
# Prerequisites:
#   - knowledge-index service active (custom image — Phase 8d)
#   - Qdrant running (Layer 1 T-015 passing)
#
# Entire module is skipped if knowledge-index is not reachable.
#
# Run: pytest testing/layer3_model/test_scan_endpoint.py -v

import pathlib
import shutil
import tempfile
import textwrap
import uuid

import httpx
import pytest

from .conftest import KNOWLEDGE_INDEX_URL

# Host path mounted into the knowledge-index container as /test-tmp (rw).
# configure.sh generates the Volume= line from config.json; deploy.sh mkdir -p's it.
_TEST_TMP_HOST      = pathlib.Path.home() / "ai-stack" / "test-tmp"
_TEST_TMP_CONTAINER = pathlib.PurePosixPath("/test-tmp")

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
def scan_version() -> str:
    """Unique semver build-metadata tag per module run.
    Prevents stale-DB conflicts when the knowledge-index retains entries
    across test runs (name+version is the catalog primary key).
    """
    return f"0.1.0+{uuid.uuid4().hex[:8]}"


@pytest.fixture(scope="module")
def scan_root(scan_version: str):
    """Module-scoped temp directory under the knowledge-index /test-tmp bind mount.

    Creates package files on the **host** under ~/ai-stack/test-tmp/ and yields
    the **container** path (/test-tmp/<dirname>) so the scan API can resolve it.

    Structure::

        ~/ai-stack/test-tmp/<scan_NNN>/   ← host path (created here)
        /test-tmp/<scan_NNN>/              ← container path (yielded to tests)
            my-scan-library/
                manifest.yaml
                documents/
                    intro.md
    """
    _TEST_TMP_HOST.mkdir(parents=True, exist_ok=True)
    host_dir = pathlib.Path(tempfile.mkdtemp(dir=_TEST_TMP_HOST, prefix="scan_"))
    container_dir = _TEST_TMP_CONTAINER / host_dir.name
    try:
        pkg = host_dir / "my-scan-library"
        pkg.mkdir()
        (pkg / "manifest.yaml").write_text(
            textwrap.dedent(f"""\
                name: my-scan-library
                version: {scan_version}
                author: test-suite
                license: MIT
                description: Minimal library for Phase 15 scan tests
                profiles:
                  - localhost
            """)
        )
        (pkg / "documents").mkdir()
        (pkg / "documents" / "intro.md").write_text(
            "# My Scan Library\n\nThis is a test document for the scan endpoint.\n"
        )
        yield container_dir
    finally:
        shutil.rmtree(host_dir, ignore_errors=True)


# ---------------------------------------------------------------------------
# T-070 — First scan: single package ingested
# ---------------------------------------------------------------------------

def test_t070_scan_single_package(ki_client, ki_headers, scan_root, scan_version):
    """POST /v1/scan — one valid .ai-library package must be ingested."""
    resp = ki_client.post("/v1/scan", json={"path": str(scan_root)}, headers=ki_headers)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["scanned"] == 1
    assert data["ingested"] == 1
    assert data["skipped"] == 0
    assert data["errors"] == []
    result = data["results"][0]
    assert result["status"] == "ingested"
    assert result["name"] == "my-scan-library"
    assert result["version"] == scan_version


# ---------------------------------------------------------------------------
# T-071 — Re-scan without force: already cataloged → skipped
# ---------------------------------------------------------------------------

def test_t071_skip_existing(ki_client, ki_headers, scan_root):
    """POST /v1/scan without force=true must skip already-cataloged packages."""
    resp = ki_client.post("/v1/scan", json={"path": str(scan_root), "force": False}, headers=ki_headers)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["scanned"] == 1
    assert data["ingested"] == 0
    assert data["skipped"] == 1
    assert data["errors"] == []


# ---------------------------------------------------------------------------
# T-072 — Force re-ingest: already cataloged but force=true → ingested
# ---------------------------------------------------------------------------

def test_t072_force_reingest(ki_client, ki_headers, scan_root):
    """POST /v1/scan with force=true must re-ingest already-cataloged packages."""
    resp = ki_client.post("/v1/scan", json={"path": str(scan_root), "force": True}, headers=ki_headers)
    assert resp.status_code == 200, resp.text
    data = resp.json()
    assert data["scanned"] == 1
    assert data["ingested"] == 1
    assert data["skipped"] == 0
    assert data["errors"] == []


# ---------------------------------------------------------------------------
# T-073 — Bad path: non-existent scan path → HTTP 400
# ---------------------------------------------------------------------------

def test_t073_bad_path(ki_client, ki_headers):
    """POST /v1/scan with a non-existent path must return HTTP 400."""
    resp = ki_client.post(
        "/v1/scan",
        json={"path": "/nonexistent-llm-stack-test-path-xyz-phase15"},
        headers=ki_headers,
    )
    assert resp.status_code == 400


# ---------------------------------------------------------------------------
# T-074 — Catalog entry reflects scanned package metadata
# ---------------------------------------------------------------------------

def test_t074_catalog_entry(ki_client, ki_headers, scan_root, scan_version):
    """GET /v1/catalog must include the scanned library with origin_node=localhost and path set."""
    resp = ki_client.get("/v1/catalog", headers=ki_headers)
    assert resp.status_code == 200, resp.text
    libs = resp.json().get("libraries", [])
    match = next(
        (lib for lib in libs
         if lib.get("name") == "my-scan-library" and lib.get("version") == scan_version),
        None,
    )
    assert match is not None, f"my-scan-library {scan_version} not found in /v1/catalog"
    assert match.get("origin_node") == "localhost"
    assert match.get("path") == str(scan_root / "my-scan-library")
