from __future__ import annotations

import pathlib
import shutil
import sys

import pytest

_SERVICE_DIR = pathlib.Path(__file__).resolve().parents[2] / "services" / "conversions"


@pytest.fixture(scope="module", autouse=True)
def _converters_importable():
    """Skip this module if the real conversion engines (pandoc, weasyprint,
    pymupdf4llm) aren't installed on the host running pytest. These tests
    exercise the actual engines rather than mocking them, so a missing
    system dependency is a skip, not a failure — mirrors the session-scoped
    skip-gate fixture pattern documented in the Python governance overlay.
    """
    if not shutil.which("pandoc"):
        pytest.skip("pandoc binary not on PATH — run inside the conversions container/image")
    if str(_SERVICE_DIR) not in sys.path:
        sys.path.insert(0, str(_SERVICE_DIR))
    try:
        import converters  # noqa: F401
    except ImportError as exc:
        pytest.skip(f"conversions converters package not importable: {exc}")


def test_registry_lists_phase_1_formats():
    import converters

    formats = converters.list_formats()
    assert {"from": "md", "to": "pdf"} in formats
    assert {"from": "pdf", "to": "md"} in formats


def test_unsupported_pair_raises():
    import converters

    with pytest.raises(converters.UnsupportedConversionError):
        converters.convert(
            "html", "xlsx", pathlib.Path("/nonexistent"), pathlib.Path("/nonexistent2")
        )


def test_markdown_to_pdf_round_trip(tmp_path: pathlib.Path):
    import converters

    md_path = tmp_path / "sample.md"
    md_path.write_text("# Title\n\nSome body text.\n")
    pdf_path = tmp_path / "sample.pdf"

    converters.convert("md", "pdf", md_path, pdf_path)

    assert pdf_path.exists()
    assert pdf_path.read_bytes().startswith(b"%PDF")


def test_pdf_to_markdown_round_trip(tmp_path: pathlib.Path):
    import converters

    md_path = tmp_path / "sample.md"
    md_path.write_text("# Title\n\nSome body text.\n")
    pdf_path = tmp_path / "sample.pdf"
    converters.convert("md", "pdf", md_path, pdf_path)

    out_md_path = tmp_path / "roundtrip.md"
    converters.convert("pdf", "md", pdf_path, out_md_path)

    text = out_md_path.read_text()
    assert "Title" in text
    assert "Some body text" in text
