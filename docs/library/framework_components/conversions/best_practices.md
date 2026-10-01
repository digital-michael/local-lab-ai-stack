# Conversions Service — Best Practices
**Last Updated:** 2026-08-12 UTC

## Purpose
General best practices for building and extending a document-conversion service of this shape —
distinct from `guidance.md`'s project-specific decisions and `security.md`'s hardening rules.

---

## Table of Contents

1. Adding a New Format Pair
2. Conversion Engine Selection
3. Reliability

---

# 1 Adding a New Format Pair

- One module per `(from, to)` pair under `services/conversions/converters/`, each exposing
  `convert(input_path: Path, output_path: Path) -> None`
- Register it with `register(from_format, to_format, fn)` in `converters/__init__.py` — this is
  the only change needed for the pair to appear in `/formats`, the CLI, the web UI's picker, and
  the MCP tool's effective capability. The REST/UI/MCP routers never need to change.
- Raise `converters.ConversionError` (or a more specific subclass) on failure with a message
  that's useful to the *caller*, not just a stack trace — it is surfaced directly as the HTTP
  422 detail / MCP tool error
- Do not special-case a format pair in `app.py` — if a pair needs different handling than
  "call the registered converter," that's a signal the registry abstraction needs to grow
  (e.g. streaming vs. buffered), not that the router should branch on format strings

# 2 Conversion Engine Selection

- Prefer a general-purpose tool (pandoc) when it has solid, non-experimental support for the
  pair — don't reach for a specialized library out of habit
- Diverge to a specialized library when the general-purpose tool's support for that specific
  direction is weak — e.g. this service uses `pymupdf4llm` instead of pandoc for PDF→Markdown
  specifically because pandoc's PDF reader is experimental/low-fidelity, while pandoc handles
  MD→PDF (via WeasyPrint) and will likely handle HTML/DOCX natively just fine
- Weigh footprint explicitly when choosing a rendering backend — WeasyPrint (Cairo/Pango) was
  chosen over a LaTeX PDF engine specifically to avoid a multi-GB TeX Live install; this
  trade-off should be re-examined per format, not assumed to generalize
- Don't build an async job queue ahead of measured need — every implemented conversion here
  completes in low single-digit seconds; add job/polling infrastructure only when profiling
  shows synchronous request/response is actually the bottleneck

# 3 Reliability

- Every temporary file lives inside a `tempfile.TemporaryDirectory()` context manager —
  deterministic cleanup on both success and exception (Resource Lifecycle Contract, Python
  governance overlay)
- Cap upload size at the app layer explicitly; do not assume the web framework enforces a
  default limit
- Return capability-flagged errors (501) for not-yet-implemented pairs rather than letting an
  unregistered format fall through to a confusing downstream failure
- Keep the conversion engine (`converters/`), the access surfaces (`app.py`'s REST/UI/MCP
  routers), and the CLI (`client.py` transport + `cli.py` ergonomics) as separate units — each
  changes for a different reason, and testing one should never require standing up another
