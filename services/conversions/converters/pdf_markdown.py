from __future__ import annotations

import pathlib

import pymupdf4llm

from . import ConversionError


def convert(input_path: pathlib.Path, output_path: pathlib.Path) -> None:
    """Extract Markdown from a PDF via pymupdf4llm.

    pandoc's own PDF reader is experimental and low-fidelity; pymupdf4llm is a
    library purpose-built for PDF -> Markdown extraction (headings, tables,
    reading order) and is used here instead — see the conversions service ADR
    in docs/decisions.md.
    """
    try:
        markdown = pymupdf4llm.to_markdown(str(input_path))
    except Exception as exc:
        raise ConversionError(f"PDF -> Markdown conversion failed: {exc}") from exc
    output_path.write_text(markdown, encoding="utf-8")
