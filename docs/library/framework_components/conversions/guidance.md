# Conversions Service — Guidance
**Last Updated:** 2026-08-12 UTC

## Purpose
Project-specific preferences and opinionated decisions for the Conversions Service within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Implementation Choices
3. Access Surfaces
4. Phased Format Rollout

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`, same as every other service in this stack — no bespoke deployment path
- Internal port: 8300 (not published beyond `127.0.0.1` on the host; reached via `ai-stack-net` or Traefik)
- No persistent data volume — every conversion runs in a per-request `tempfile.TemporaryDirectory()`; nothing survives a request
- Resource limits: 1 CPU, 1024 MB RAM — higher than knowledge-index's 512m because WeasyPrint/pandoc rendering is more memory-hungry than KI's text/embedding workload; untuned starting point, revisit after real usage
- Decision: see `docs/decisions.md` ADR for this service — standalone FastAPI microservice adopting the knowledge-index/m2m-gateway pattern, rather than a bare CLI+Docker tool outside this stack

# 2 Implementation Choices

- **Python/FastAPI** — same stack as knowledge-index and m2m-gateway; no new framework introduced
- **Synchronous conversion, no job queue** — every Phase 1 format pair (MD⇄PDF) completes in low single-digit seconds; an async job store/polling layer is a new architectural concern this stack doesn't otherwise carry, and would be premature without measured latency data. Revisit only if profiling shows real need.
- **MD → PDF via `pandoc --pdf-engine=weasyprint`** — WeasyPrint (pure Python, Cairo/Pango-backed) instead of a LaTeX engine, to avoid a multi-GB TeX Live install
- **PDF → MD via `pymupdf4llm`** — pandoc's own PDF reader is experimental/low-fidelity; this is a purpose-built extraction library used instead, a deliberate divergence from "route everything through pandoc"
- **Format registry (`converters/__init__.py`)** — one module per `(from, to)` pair, registered by name; adding a format means adding a module + one `register()` call, not touching the API/UI/CLI/MCP layers
- **Upload size cap** — `MAX_UPLOAD_BYTES` (default 25MB) enforced in the app layer; Starlette does not cap multipart body size by default

# 3 Access Surfaces

Three ways to reach the same conversion engine, matching knowledge-index's dual REST+MCP precedent (D-015) plus a browser UI (new for this stack — knowledge-index has none):

| Surface | Path | Auth |
|---|---|---|
| REST API (CLI/agents) | `POST /v1/convert` | `API_KEY` bearer token, app-level |
| Browser UI | `GET /`, `POST /ui/convert` | Traefik Authentik forward-auth (no app-level check) |
| MCP tool (agents) | `/mcp/sse`, `/mcp/messages` | `API_KEY` bearer token, app-level |

`/v1/convert` and `/ui/convert` share the same underlying `_run_conversion()` — the split exists purely at the auth/routing layer, not duplicated conversion logic. `/formats` is unauthenticated (read-only capability discovery) and used by the CLI, the UI's format picker, and MCP clients alike.

# 4 Phased Format Rollout

| Phase | Pair(s) | Status |
|---|---|---|
| 1 | md⇄pdf | Implemented |
| 2 | html⇄{md,pdf} | Deferred — likely via pandoc's native HTML support |
| 3 | docx⇄{md,pdf,html} | Deferred — pandoc native first; LibreOffice-headless fallback only if fidelity is insufficient |
| 4 | xlsx→{csv,md,json} | Deferred — output shape (per-sheet CSV vs. structured JSON) not yet decided |

Each unimplemented pair returns HTTP 501 from `/v1/convert` and `/ui/convert` (mirrors knowledge-index's `TAVILY_API_KEY`-gated 501 pattern) rather than a confusing downstream error.
