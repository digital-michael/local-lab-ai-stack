# Open WebUI: failed completions saved as successful with empty content and no error

**Target repo:** https://github.com/open-webui/open-webui
**Open WebUI version:** `v0.12.0` (`ghcr.io/open-webui/open-webui:v0.12.0`)
**Backend:** LiteLLM proxy (`v1.105.0`) → Ollama (`0.40.3`), `ollama_chat/<model>` provider
**Status:** draft — not yet filed
**Related:** see companion report `litellm-ollama-error-swallowing.md` — this may be downstream of a LiteLLM-side bug rather than purely an Open WebUI bug; filing both since the fix on this side (detect and surface a failed/empty stream) is valid regardless of upstream root cause.

---

## Summary

During a long chat session using a slow (CPU-bound, large MoE) local model, several assistant turns were recorded in Open WebUI's own database as **successfully completed** (`chat_message.done = 1`) with **`error = NULL`** and **`content` = an empty string**. The user experienced this as the assistant silently producing nothing, with no visible indication that anything had gone wrong — no error banner, no retry prompt, nothing distinguishing it from a model that legitimately generated zero tokens.

Independently confirmed via the backend's own access log: at least one of these turns coincides with a real `HTTP 500` from the upstream LLM backend after a multi-minute wait (Ollama's own `[GIN]` log: `2026/10/13 - 15:55:32 | 500 | 4m50s | POST "/api/chat"`), meaning a genuine backend failure occurred and was not surfaced anywhere in the UI.

## Evidence

Direct query against Open WebUI's `webui.db` SQLite database, `chat_message` table, for the affected chat:

```
id       = ...988a784deb01
role     = assistant
model_id = qwen3-coder-next:latest
done     = 1
error    = null
content  = ""   (length 2 in the raw JSON-encoded column, i.e. the literal empty string)
```

Several other turns in the same conversation show the same shape (`done=1`, `error=null`, empty content) at different points in the session, all following unusually long user-perceived "thinking" periods.

By contrast, a *different* failure in the same session was correctly captured with a populated `error` field:
```
error = {"content":"litellm.InternalServerError: Ollama_chatException - {\"error\":\"an error was encountered while running the model: unexpected EOF\"}\n\nLiteLLM: model group 'qwen3-coder-next:latest' failed with the error above. No fallback was attempted."}
```
This confirms Open WebUI *does* have a code path for recording a backend error against a message — it just isn't triggered consistently. Specifically, it appears to depend on whether LiteLLM itself raised a visible exception (see companion report) vs. the backend connection simply failing/closing without LiteLLM logging or propagating anything — in the latter case, Open WebUI appears to treat "stream ended with no content and no exception" as a normal empty completion rather than a failure state.

## Expected behavior

A chat completion that:
- produced zero content, **and**
- took an unusually long time relative to the model's normal behavior, **and/or**
- corresponds to a backend request that did not return a normal successful response

...should be flagged to the user in some visible way (an error banner, a "response failed" indicator, a retry affordance) rather than being indistinguishable from a model that chose to say nothing. At minimum, Open WebUI should not need an upstream exception to be raised in order to detect "this stream produced nothing" — an empty final content with no stream-completion signal (e.g., no proper `finish_reason`, or a connection that closed unexpectedly) should itself be treated as an error condition.

## Suggested areas to look at

- Wherever Open WebUI consumes the streaming response from its backend (LiteLLM proxy) and ultimately writes the `chat_message` row — check whether a connection error/early stream termination is being caught and discarded rather than recorded in the `error` column.
- Whether there's a generic "empty response" check at all, independent of whether an exception was raised upstream.

## Reproduction notes (not yet minimized)

Observed only in production against a real, slow backend. A minimal repro would need a stub backend that accepts a streaming chat request, sends no content chunks, and then closes the connection without an explicit error payload — confirm whether Open WebUI records this as `done=1`/`error=null`/empty content (reproducing the bug) or correctly flags it as failed.
