from __future__ import annotations

import pathlib

import pypandoc

from . import ConversionError


def convert(input_path: pathlib.Path, output_path: pathlib.Path) -> None:
    """Render Markdown to PDF via pandoc, using WeasyPrint as the PDF engine.

    WeasyPrint (pure-Python, Cairo/Pango-backed) is used instead of a LaTeX
    engine (pdflatex/xelatex) to avoid pulling a multi-GB TeX Live install
    into the image — see the conversions service ADR in docs/decisions.md.
    """
    try:
        pypandoc.convert_file(
            str(input_path),
            "pdf",
            outputfile=str(output_path),
            extra_args=["--pdf-engine=weasyprint", "--standalone"],
        )
    except Exception as exc:  # pypandoc surfaces pandoc/weasyprint failures as RuntimeError
        raise ConversionError(f"Markdown -> PDF conversion failed: {exc}") from exc
