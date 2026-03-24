# configs/litellm/hooks.py
#
# LiteLLM async_pre_call_hook — ambient RAG injection (D-030).
#
# Fires before every inference request routed through the LiteLLM proxy.
# Queries the Knowledge Index (/query) with the last user message, and
# injects the top-k results as additional system message context.
#
# No-op conditions:
#   - call_type is not a chat/completion request
#   - KI_BASE_URL env var is unset or empty
#   - KI returns no results (empty, offline, or query produces no matches)
#   - Any exception (RAG failure is always non-fatal)
#
# Environment:
#   KI_BASE_URL    — base URL of the Knowledge Index (e.g. http://knowledge-index.ai-stack:8100)
#   KI_API_KEY     — Bearer token for Knowledge Index API access (from knowledge_index_api_key secret)

import os
from typing import Optional

import httpx

try:
    from litellm.integrations.custom_logger import CustomLogger
except ImportError:
    # Fallback stub so the module can be imported in dev/test without litellm installed
    class CustomLogger:  # type: ignore
        pass

_KI_BASE_URL: str = os.environ.get("KI_BASE_URL", "").rstrip("/")
_KI_API_KEY: str = os.environ.get("KI_API_KEY", "")

_RAG_TOP_K: int = int(os.environ.get("KI_RAG_TOP_K", "3"))


class AsyncRAGHook(CustomLogger):
    """
    LiteLLM callback that injects Knowledge Index context into the system
    message before each chat completion request (D-030).
    """

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: str,
    ) -> Optional[dict]:
        # Only handle chat completions
        if call_type not in ("completion", "acompletion"):
            return data

        # Re-read env vars at call time so the hook responds to live config changes
        ki_base = os.environ.get("KI_BASE_URL", "").rstrip("/")
        ki_key = os.environ.get("KI_API_KEY", "")

        if not ki_base:
            return data

        messages: list = data.get("messages", [])
        if not messages:
            return data

        # Use last user message as the search query
        user_content = next(
            (m.get("content", "") for m in reversed(messages) if m.get("role") == "user"),
            "",
        )
        if not user_content or not isinstance(user_content, str):
            return data

        try:
            headers: dict = {}
            if ki_key:
                headers["Authorization"] = f"Bearer {ki_key}"

            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.post(
                    f"{ki_base}/query",
                    json={"query": user_content, "top_k": _RAG_TOP_K},
                    headers=headers,
                )

            if resp.status_code != 200:
                return data

            results: list = resp.json().get("results", [])
            context_parts = [
                r.get("content", "").strip()
                for r in results
                if r.get("content", "").strip()
            ]
            if not context_parts:
                return data

            context = "\n\n".join(context_parts)
            injection = (
                "Relevant context from the knowledge index "
                "(use if helpful, ignore if not relevant to the question):\n\n"
                f"{context}"
            )

            # Augment existing system message or prepend a new one
            sys_messages = [m for m in messages if m.get("role") == "system"]
            if sys_messages:
                sys_messages[0]["content"] = sys_messages[0]["content"] + "\n\n" + injection
            else:
                data["messages"] = [{"role": "system", "content": injection}] + messages

        except Exception:
            # RAG failure is always non-fatal — inference proceeds without context
            pass

        return data
