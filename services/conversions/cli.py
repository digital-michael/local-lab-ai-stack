from __future__ import annotations

import os
import pathlib
import sys

import typer

from client import ConversionsClient

app = typer.Typer(add_completion=False, help="Convert documents via the conversions service.")


def _client() -> ConversionsClient:
    base_url = os.environ.get("CONVERSIONS_BASE_URL", "http://conversions.ai-stack:8300")
    api_key = os.environ.get("CONVERSIONS_API_KEY", "")
    return ConversionsClient(base_url=base_url, api_key=api_key)


def _infer_format(input_arg: str, explicit: str | None) -> str:
    if explicit:
        return explicit.lower().lstrip(".")
    if input_arg == "-":
        raise typer.BadParameter("--from is required when reading from stdin")
    suffix = pathlib.Path(input_arg).suffix.lstrip(".")
    if not suffix:
        raise typer.BadParameter(f"Cannot infer source format from {input_arg!r}; pass --from")
    return suffix.lower()


def _resolve_output_path(out: str | None, input_name: str, to_format: str) -> pathlib.Path | None:
    """Resolve --out into a concrete file path, or None for stdout.

    --out accepts a directory (result keeps the input's basename, extension
    swapped to the target format), a full file path, or '-'/omitted for
    stdout — the "new directory / new directory+file / stream" requirement
    this CLI was built around.
    """
    if out is None or out == "-":
        return None
    out_path = pathlib.Path(out)
    if out_path.is_dir() or out.endswith(("/", os.sep)):
        out_path.mkdir(parents=True, exist_ok=True)
        stem = pathlib.Path(input_name).stem
        return out_path / f"{stem}.{to_format}"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    return out_path


@app.command()
def convert(
    input: str = typer.Argument(..., help="Input file path, or '-' to read from stdin"),
    to: str = typer.Option(..., "--to", help="Target format, e.g. pdf, md"),
    from_: str | None = typer.Option(
        None, "--from", help="Source format; inferred from the input's extension if omitted"
    ),
    out: str | None = typer.Option(
        None, "--out", "-o", help="Output directory, file path, or '-' for stdout (default: stdout)"
    ),
) -> None:
    """Convert a single document and write the result to --out (or stdout)."""
    from_format = _infer_format(input, from_)
    to_format = to.lower().lstrip(".")

    if input == "-":
        data = sys.stdin.buffer.read()
        input_name = f"stdin.{from_format}"
    else:
        input_path = pathlib.Path(input)
        if not input_path.is_file():
            typer.echo(f"error: no such file: {input}", err=True)
            raise typer.Exit(code=1)
        data = input_path.read_bytes()
        input_name = input_path.name

    try:
        result = _client().convert_bytes(
            data, filename=input_name, from_format=from_format, to_format=to_format
        )
    except Exception as exc:
        # Top-level CLI error boundary: any transport/HTTP failure below this
        # point should become a clean exit code + message, not a traceback.
        typer.echo(f"error: conversion failed: {exc}", err=True)
        raise typer.Exit(code=1) from exc

    output_path = _resolve_output_path(out, input_name, to_format)
    if output_path is None:
        sys.stdout.buffer.write(result)
    else:
        output_path.write_bytes(result)
        typer.echo(str(output_path))


@app.command()
def formats() -> None:
    """List currently-implemented (from, to) conversion pairs."""
    try:
        data = _client().list_formats()
    except Exception as exc:
        typer.echo(f"error: could not reach conversions service: {exc}", err=True)
        raise typer.Exit(code=1) from exc
    for pair in data.get("implemented", []):
        typer.echo(f"{pair['from']} -> {pair['to']}")


if __name__ == "__main__":
    app()
