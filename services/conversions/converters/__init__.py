# services/conversions/converters/__init__.py
#
# Format-pair registry. Keeps "how a conversion happens" (this package) separate
# from "how a conversion is triggered" (app.py's REST/UI/MCP routers) — see the
# separation-of-concerns note in the conversions service ADR.
#
# Each converter module exposes convert(input_path, output_path) -> None and
# registers itself below. Adding a new format pair means adding one module and
# one register() call — the routers, CLI, and MCP tool don't change.

from __future__ import annotations

import pathlib
from typing import Callable


class ConversionError(Exception):
    """Raised when a document conversion fails for a reason the caller can act on."""


class UnsupportedConversionError(ConversionError):
    """Raised when no converter is registered for the requested (from, to) pair."""


ConverterFn = Callable[[pathlib.Path, pathlib.Path], None]

_REGISTRY: dict[tuple[str, str], ConverterFn] = {}


def register(from_format: str, to_format: str, fn: ConverterFn) -> None:
    _REGISTRY[(from_format, to_format)] = fn


def get_converter(from_format: str, to_format: str) -> ConverterFn | None:
    return _REGISTRY.get((from_format, to_format))


def list_formats() -> list[dict[str, str]]:
    """Return the currently-implemented (from, to) pairs — drives /formats,
    the web UI's picker, and the CLI's --help output from one source of truth."""
    return [{"from": f, "to": t} for (f, t) in sorted(_REGISTRY)]


def convert(from_format: str, to_format: str, input_path: pathlib.Path, output_path: pathlib.Path) -> None:
    fn = get_converter(from_format, to_format)
    if fn is None:
        raise UnsupportedConversionError(f"Conversion not supported: {from_format} -> {to_format}")
    fn(input_path, output_path)


# Register built-in converters. Imported after the registry primitives above
# exist, since each converter module imports ConversionError from this package.
from . import markdown_pdf as _markdown_pdf  # noqa: E402
from . import pdf_markdown as _pdf_markdown  # noqa: E402

register("md", "pdf", _markdown_pdf.convert)
register("pdf", "md", _pdf_markdown.convert)

# Phase 2+ (HTML, DOCX, XLSX) register here as their converter modules land —
# see docs/library/framework_components/conversions/guidance.md.
