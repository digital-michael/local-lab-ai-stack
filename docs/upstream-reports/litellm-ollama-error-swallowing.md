# LiteLLM: Ollama backend errors silently dropped (no log, no exception) or surfaced as an unrelated crash

**Target repo:** https://github.com/BerriAI/litellm
**LiteLLM version:** `v1.105.0` (`ghcr.io/berriai/litellm:v1.105.0`)
**Ollama version:** `0.40.3` (`docker.io/ollama/ollama:0.40.3`)
**Provider:** `ollama_chat/<model>`, called via Open WebUI as a long-running streamed chat completion
**Model:** a large (80B-param MoE) local model, CPU-only inference, `num_ctx=32768`
**Status:** draft — not yet filed

---

## Summary

Over one incident, Ollama's own access log (`[GIN]`) recorded **6 separate requests that genuinely failed with HTTP 500** from the backend itself, each after a long wait (4m50s up to 23m19s). For **all 6**, LiteLLM produced **zero corresponding log output** in that time window — no error, no traceback, nothing. The failure was invisible at the LiteLLM layer and, downstream, the client (Open WebUI) recorded several of these turns as successfully completed with empty content and no error.

A related, second failure mode was also captured with a full traceback: when Ollama's *streaming* response (HTTP `200`, since the header is already committed before the mid-stream error) emits a bare `{"error": "..."}` line instead of the expected `{"message": {...}}` chunk, LiteLLM's response parser raises an **unhandled `KeyError: 'message'`**, which then surfaces to the caller as a generic `400 BadRequestError` that obscures the real underlying Ollama error.

## Bug 1 — Backend 500 produces no LiteLLM log entry at all

### Evidence

Ollama's own GIN access log for the incident window (`docker logs ollama`), filtered to `POST /api/chat`:

```
[GIN] 2026/10/13 - 15:55:32 | 500 |  4m50s  | POST "/api/chat"
[GIN] 2026/10/13 - 16:13:37 | 500 |  3m28s  | POST "/api/chat"
[GIN] 2026/10/13 - 16:51:45 | 500 | 10m20s  | POST "/api/chat"
[GIN] 2026/10/13 - 17:14:23 | 500 | 22m37s  | POST "/api/chat"
[GIN] 2026/10/13 - 17:36:38 | 500 | 22m13s  | POST "/api/chat"
[GIN] 2026/10/13 - 18:10:27 | 500 | 21m10s  | POST "/api/chat"
```

For each of these 6 timestamps, `journalctl -u litellm` in a surrounding ±2 minute window contains **zero** matching lines (checked for any `ERROR`, `InternalServerError`, `BadRequestError`, or model-name reference). LiteLLM's own `/health/liveliness` checks continued returning `200` throughout — the proxy process itself was healthy; it simply never logged anything for these specific failed upstream calls.

Downstream effect confirmed via Open WebUI's own database (`chat_message` table): several assistant turns matching these windows are recorded as `done=1` (completed normally), `error=NULL`, with **content = empty string**. No error ever reached the client in a recoverable form — the user just sees a blank reply with no indication anything went wrong.

### Expected behavior

A `500` from the backend LLM provider should, at minimum, produce a logged error at LiteLLM's proxy layer (visible via `journalctl`/stdout) and should be propagated to the client as a non-2xx response with error details — not silently absorbed.

### Suspected cause (not confirmed against source)

Possibly: an exception raised inside a retry/fallback code path that isn't reached by LiteLLM's own exception-logging middleware, or a case where a long-running streamed request's connection is torn down (client-side timeout, or the backend socket closing) before LiteLLM's own response-handling code gets a chance to log anything. Worth checking the request-cancellation / timeout-handling path for the `ollama_chat` provider specifically, since this only reproduced on long-running (CPU-bound, multi-minute) completions.

---

## Bug 2 — Unhandled `KeyError: 'message'` when Ollama's stream emits a bare error object

### Evidence

Full traceback captured from `journalctl -u litellm`:

```
litellm.llms.custom_httpx.http_handler: ...
litellm.exceptions.BadRequestError: litellm.BadRequestError: Ollama_chatException - KeyError: 'message', Got unexpected response from Ollama: {'error': 'an error was encountered while running the model: unexpected EOF'}
```

This occurred on a request that Ollama's own GIN log shows completed with HTTP `200` (not 500):

```
[GIN] 2026/10/13 - 18:35:11 | 200 | 1m46s | POST "/api/chat"
```

Interpretation: this was a **streamed** response. Ollama had already committed the `200` status line and begun streaming NDJSON chunks before the mid-stream failure occurred, so it can only report the error as an embedded `{"error": "..."}` object in the stream body rather than via the HTTP status code. LiteLLM's Ollama streaming-response parser appears to assume every chunk has a `message` key and raises an unhandled `KeyError` when it doesn't, rather than checking for an `error` key first and raising a clean, descriptive exception.

A second, related instance was captured as a (correctly surfaced, with traceback) `InternalServerError`:

```
litellm.exceptions.InternalServerError: litellm.InternalServerError: Ollama_chatException - {"error":"an error was encountered while running the model: unexpected EOF"}

LiteLLM: model group 'qwen3-coder-next:latest' failed with the error above. No fallback was attempted. LiteLLM Retried: 2 times, LiteLLM Max Retries: 2
```
(Full Python traceback available; happy to attach on request — trimmed here for brevity, goes through `llm_http_handler.py:461` → `http_handler.py:868` → `_raise_masked_async_error` → `main.py:681 acompletion`.)

### Expected behavior

When Ollama's streamed response contains `{"error": "..."}` instead of the expected `{"message": {...}}` shape, LiteLLM should detect the `error` key explicitly and raise a clear exception carrying that message — not fall through to an unguarded dict access that raises `KeyError`, which then gets wrapped as a generic, misleading `400 BadRequestError`.

### Suggested fix

In the Ollama chat response/stream parsing code, check for an `error` key before accessing `message`, e.g.:
```python
if "error" in chunk:
    raise OllamaError(chunk["error"])
message = chunk["message"]  # only reached if no error key
```

---

## Reproduction notes (not yet minimized)

Both bugs were observed in production against a real Ollama backend running a large (80B-param), CPU-only model under heavy load (single inference slot, multi-minute requests). A minimal repro would likely need:
1. A mock/stub Ollama server that (a) accepts a request and then returns a bare `500` after a delay, and (b) accepts a streaming request and emits one normal chunk followed by a line containing only `{"error": "..."}`.
2. LiteLLM configured with `ollama_chat/<model>` pointed at that stub.
3. Confirm: case (a) produces no LiteLLM log output and the client receives no usable error; case (b) raises `KeyError: 'message'` instead of a clean provider error.

We have not yet built this minimal repro — only production log evidence. Recommend building it before filing if a cleaner reproduction is wanted, though the production evidence (6/6 reproducibility on the silent-swallow case) is already fairly strong.
