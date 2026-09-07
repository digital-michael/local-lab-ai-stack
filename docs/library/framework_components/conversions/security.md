# Conversions Service — Security
**Last Updated:** 2026-08-12 UTC

## Purpose
Security standards and hardening guidelines for the Conversions Service in the AI stack. This
service is a new attack surface for this stack in one specific way: it is the first service that
parses **untrusted binary documents** (uploaded PDFs, and later DOCX/XLSX) through third-party
parsing/rendering libraries, rather than only handling text/JSON payloads.

---

## Table of Contents

1. Network Security
2. Input Handling
3. Authentication and Authorization
4. Container Security

## References

- OWASP API Security Top 10: https://owasp.org/www-project-api-security/
- OWASP File Upload Cheat Sheet: https://cheatsheetseries.owasp.org/cheatsheets/File_Upload_Cheat_Sheet.html

---

# 1 Network Security

- Bound to `127.0.0.1` on the host and reached via `ai-stack-net` / Traefik, same as every other
  stack service — no direct external exposure
- **Not routed through Caddy** — Caddy is this repo's external photondatum.space edge, a
  different concern from internal stack services (see the conversions service ADR)
- Browser UI (`/`, `/ui/*`) is fronted by Traefik's Authentik forward-auth; `/v1/*` and `/mcp/*`
  are reachable without an SSO session but require the `API_KEY` bearer token at the app layer —
  see `configs/traefik/dynamic/services.yaml`'s `conversions`/`conversions-api`/`conversions-mcp`
  routers

# 2 Input Handling

- **Upload size cap** (`MAX_UPLOAD_BYTES`, default 25MB) enforced in `app.py` before any bytes
  reach a conversion engine — Starlette does not cap multipart body size by default; unbounded
  upload is a real DoS surface for a service whose whole job is processing file content
- **Every conversion runs inside a per-request `tempfile.TemporaryDirectory()`** — inputs and
  outputs never touch a shared or persistent path, and cleanup is deterministic even on failure
- **Format tokens are validated against a fixed allowlist** (`_SUPPORTED_FORMATS` in `app.py`)
  before any file is written to disk — no format string reaches a shell command or file extension
  unchecked
- **Filenames from the client are never trusted for path construction** — `_run_conversion`
  builds its own `input.<format>` / `output.<format>` names inside the temp directory; the
  client-supplied filename is only used for the response's `Content-Disposition` header
- Malicious/crafted input documents (a PDF designed to exhaust memory or trigger a parser bug in
  `pymupdf4llm`/pandoc) are a known residual risk of any document-conversion service — the size
  cap and per-request container-level resource limits (`configs/config.json`'s `resources` block)
  are the primary mitigation until/unless a stronger sandboxing need is demonstrated
- **DOCX/XLSX phases (deferred):** both formats are zip archives — apply zip-bomb protections
  (max uncompressed size, max entry count) when those converters are implemented; not yet a risk
  since neither format is wired up

# 3 Authentication and Authorization

- `API_KEY` env var (from the `conversions_api_key` Podman secret) guards `/v1/*` and `/mcp/*` —
  same mechanism as knowledge-index's `_check_api_key` (constant is compared directly; not
  constant-time, matching the existing precedent in this codebase)
- Browser access relies on Traefik's Authentik forward-auth (SSO), not the app-level key — a
  browser session never carries the bearer token, by design (see the conversions ADR)
- `/health` and `/formats` are intentionally unauthenticated — neither exposes sensitive data,
  and `/formats` needs to be reachable by an unauthenticated CLI's `--help`-style discovery

# 4 Container Security

- Runs as a non-root user (`conversions`) inside the container — see `Containerfile`
- No persistent volumes — nothing written by a conversion survives past the request's temp
  directory, so there is no data-at-rest concern for uploaded content
- Minimal base image (`python:3.12-slim`) plus only the system packages the conversion engines
  require (`pandoc`, Cairo/Pango libs for WeasyPrint, `fonts-liberation`)
- Apply resource limits: 1 CPU, 1024 MB RAM (see `configs/config.json`) — a crafted or oversized
  document should degrade this one container, not starve the rest of the stack
