# configs/litellm/hooks.py
#
# LiteLLM hooks — content review (D-039) + ambient RAG injection (D-030).
#
# Execution order (registered in proxy_config.yaml):
#   1. ContentReviewHook.async_pre_call_hook  — regex gates A/B/C; raises on violation
#   2. AsyncRAGHook.async_pre_call_hook       — KI context injection
#
# ContentReviewHook (D-039 Phase 1):
#   Evaluates all user/system message content against three categories of
#   deterministic regex patterns before any inference or KI query occurs.
#   Category A: security violations (jailbreak, container escape, code injection, exfil)
#   Category B: privacy / PII (SSN, payment card, cross-user data references)
#   Category C: credential detection (API keys, private keys, env assignments)
#   Hard-rejects with a generic error on any match. Logs event to stderr as
#   structured JSON (captured by Promtail → Loki). Never logs matched values.
#   Controlled by REVIEW_ENABLED env var (default: true).
#
# AsyncRAGHook (D-030):
#   Fires before every inference request routed through the LiteLLM proxy.
#   Queries the Knowledge Index (/query) with the last user message, and
#   injects the top-k results as additional system message context.
#   No-op when KI_BASE_URL is unset or empty. RAG failure is always non-fatal.
#
# Environment:
#   REVIEW_ENABLED — set to 'false' to disable content review (not for production)
#   KI_BASE_URL    — base URL of the Knowledge Index (e.g. http://knowledge-index.ai-stack:8100)
#   KI_API_KEY     — Bearer token for Knowledge Index API access (from knowledge_index_api_key secret)

import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone
from typing import Optional

import httpx

try:
    from litellm.integrations.custom_logger import CustomLogger
except ImportError:
    # Fallback stub so the module can be imported in dev/test without litellm installed
    class CustomLogger:  # type: ignore
        pass

# ---------------------------------------------------------------------------
# Content Review — patterns (Category A / B / C) — compiled once at import
# ---------------------------------------------------------------------------

_SECURITY_PATTERNS: list[tuple[re.Pattern, str]] = [
    p for p in [
        # LLM jailbreaking
        (re.compile(r'\bignore\s+(all\s+)?previous\s+instructions?\b', re.I), 'jailbreak:ignore-previous'),
        (re.compile(r'\bact\s+as\s+(if\s+you\s+(were|are)\b|a\s+|an?\s+)', re.I), 'jailbreak:act-as'),
        (re.compile(r'\b(DAN|developer\s+mode|jailbreak|unrestricted\s+mode|STAN|DUDE)\b', re.I), 'jailbreak:mode-switch'),
        (re.compile(r'\bpretend\s+(you\s+are|to\s+be)\b', re.I), 'jailbreak:pretend'),
        (re.compile(r'\byour\s+(true|real|actual|hidden)\s+(self|purpose|instructions?)\b', re.I), 'jailbreak:hidden-self'),
        (re.compile(r'\bsystem\s*prompt\s*(is|was|should|will)\b', re.I), 'jailbreak:system-prompt-disclosure'),
        # Container / host escape
        (re.compile(r'\b(nsenter|unshare|pivot_root|chroot)\b', re.I), 'escape:container-syscall'),
        (re.compile(r'/proc/(self|[0-9]+)/(ns|fd|mem|maps)\b'), 'escape:proc-traversal'),
        (re.compile(r'\b--privileged\b', re.I), 'escape:privileged-flag'),
        (re.compile(r'\b(cap_sys_admin|cap_net_admin|setuid)\b', re.I), 'escape:capability'),
        # Privilege escalation
        (re.compile(r'\bsudo\s+(-[si]|bash|sh|su\b)', re.I), 'privesc:sudo-shell'),
        (re.compile(r'\bsu\s+(-\s+)?root\b', re.I), 'privesc:su-root'),
        (re.compile(r'\b/etc/(passwd|shadow|sudoers)\b', re.I), 'privesc:sensitive-file'),
        # Code / command injection
        (re.compile(r'\beval\s*\(', re.I), 'injection:eval'),
        (re.compile(r'__import__\s*\('), 'injection:dunder-import'),
        (re.compile(r'\bsubprocess\.(call|run|Popen|check_output)\s*\(', re.I), 'injection:subprocess'),
        (re.compile(r'\bos\.(system|popen|execv?[ep]?)\s*\(', re.I), 'injection:os-exec'),
        # Exfiltration / outbound fetch patterns in documents
        (re.compile(r'\b(curl|wget|fetch|requests\.get)\s+https?://', re.I), 'exfil:outbound-fetch-command'),
        (re.compile(r'\b(base64|b64decode|atob)\b.*\beval\b', re.I | re.S), 'exfil:encoded-exec'),
        # Denial of service (resource exhaustion)
        (re.compile(r'(.)\1{2000,}', re.S), 'dos:repeated-char'),
        # Package injection
        (re.compile(r'\b(pip|pip3)\s+install\s+(?!-r\s)', re.I), 'inject:pip-install'),
        (re.compile(r'\b(npm|yarn)\s+(install|add)\s+', re.I), 'inject:npm-install'),
        (re.compile(r'\bapt(-get)?\s+install\s+', re.I), 'inject:apt-install'),
    ]
]

_PRIVACY_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r'\b\d{3}-\d{2}-\d{4}\b'), 'pii:ssn'),
    (re.compile(r'\b(?:\d[ -]?){13,16}\b'), 'pii:payment-card'),
    (re.compile(r'\b\+?[0-9]{1,3}[\s.\-]?\(?\d{3}\)?[\s.\-]?\d{3}[\s.\-]?\d{4}\b'), 'pii:phone-number'),
    (re.compile(
        r'\b(another|other|different)\s+user[\'s]*\s+(session|data|token|key|password|email)\b', re.I),
        'privacy:cross-user-data-reference'),
    (re.compile(r'\bsession[_-]?token[s]?\s*[=:]\s*\S{10,}\b', re.I), 'privacy:session-token'),
    # Email addresses in inference context (not applied to document ingestion)
    (re.compile(r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b'), 'pii:email-address'),
]
# Patterns applied to inference only (not document ingestion)
_PRIVACY_INFERENCE_ONLY: frozenset[str] = frozenset({'pii:email-address'})

_CREDENTIAL_PATTERNS: list[tuple[re.Pattern, str]] = [
    (re.compile(r'\bsk-[A-Za-z0-9]{20,}\b'), 'cred:openai-key'),
    (re.compile(r'\bAKIA[0-9A-Z]{16}\b'), 'cred:aws-access-key'),
    (re.compile(r'\bghp_[A-Za-z0-9]{36}\b'), 'cred:github-pat'),
    (re.compile(r'\bghs_[A-Za-z0-9]{36}\b'), 'cred:github-actions-secret'),
    (re.compile(r'\bxox[baprs]-[0-9A-Za-z\-]{10,}\b', re.I), 'cred:slack-token'),
    (re.compile(r'\bAIza[0-9A-Za-z\-_]{35}\b'), 'cred:google-api-key'),
    (re.compile(r'EYJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}'), 'cred:jwt-token'),
    (re.compile(r'[a-zA-Z][a-zA-Z0-9+\-.]*://[^:@\s]+:[^@\s]+@'), 'cred:url-with-password'),
    (re.compile(r'-----BEGIN\s+(?:RSA|EC|DSA|OPENSSH|PGP)?\s*PRIVATE KEY-----'), 'cred:private-key-pem'),
    (re.compile(
        r'(?:PASSWORD|SECRET|API_KEY|TOKEN|ACCESS_KEY)\s*=\s*[^\s$\'"]{6,}', re.I),
        'cred:env-assignment'),
    (re.compile(
        r'(?:litellm_master_key|qdrant_api_key|knowledge_index_api_key|flowise_secret_key)\s*[=:]\s*\S{6,}',
        re.I),
        'cred:stack-secret-leaked'),
]

_REVIEW_ENABLED: bool = os.environ.get("REVIEW_ENABLED", "true").lower() not in ("false", "0", "no")


def _log_review_event(
    *,
    enforcement_point: str,
    category: str,
    rule: str,
    action: str,
    request_id: str,
    full_content: str,
    matched_segment: str,
) -> None:
    """Write a structured review event to stderr. Never logs raw content or matched values."""
    record = {
        "ts": datetime.now(timezone.utc).isoformat(),
        "level": "WARN",
        "event": "content_review",
        "enforcement_point": enforcement_point,
        "category": category,
        "rule": rule,
        "action": action,
        "request_id": request_id,
        "content_hash": hashlib.sha256(full_content[:1024].encode()).hexdigest(),
        "match_hash": hashlib.sha256(matched_segment.encode()).hexdigest()[:8],
    }
    print(json.dumps(record), file=sys.stderr, flush=True)


def _review_or_raise(
    text: str,
    *,
    enforcement_point: str,
    request_id: str,
    skip_inference_only: bool = False,
) -> None:
    """
    Apply Category A/B/C review patterns. Raises ValueError on any match.
    skip_inference_only=True omits patterns flagged as inference-only
    (used at ingestion endpoints where, e.g., email addresses are acceptable).
    """
    if not _REVIEW_ENABLED:
        return

    for pattern, rule in _SECURITY_PATTERNS:
        m = pattern.search(text)
        if m:
            _log_review_event(
                enforcement_point=enforcement_point, category="A", rule=rule,
                action="rejected", request_id=request_id,
                full_content=text, matched_segment=m.group(0),
            )
            raise ValueError("Request rejected by content policy.")

    for pattern, rule in _PRIVACY_PATTERNS:
        if skip_inference_only and rule in _PRIVACY_INFERENCE_ONLY:
            continue
        m = pattern.search(text)
        if m:
            _log_review_event(
                enforcement_point=enforcement_point, category="B", rule=rule,
                action="rejected", request_id=request_id,
                full_content=text, matched_segment=m.group(0),
            )
            raise ValueError("Request rejected by content policy.")

    for pattern, rule in _CREDENTIAL_PATTERNS:
        m = pattern.search(text)
        if m:
            _log_review_event(
                enforcement_point=enforcement_point, category="C", rule=rule,
                action="rejected", request_id=request_id,
                full_content=text, matched_segment=m.group(0),
            )
            raise ValueError("Request rejected by content policy.")


# ---------------------------------------------------------------------------
# ContentReviewHook — LiteLLM callback (D-039 Phase 1)
# ---------------------------------------------------------------------------

class ContentReviewHook(CustomLogger):
    """
    LiteLLM callback that reviews user/system message content for policy
    violations (Categories A/B/C) before inference. Hard-rejects on match.
    Must be registered before AsyncRAGHook in proxy_config.yaml so that
    rejected content never triggers a KI query.
    """

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: str,
    ) -> Optional[dict]:
        if call_type not in ("completion", "acompletion"):
            return data

        messages: list = data.get("messages", [])
        text = " ".join(
            m.get("content", "") for m in messages
            if m.get("role") in ("user", "system") and isinstance(m.get("content"), str)
        )
        if not text:
            return data

        request_id = str(data.get("litellm_call_id", "unknown"))
        _review_or_raise(text, enforcement_point="litellm_hook", request_id=request_id)
        return data


# ---------------------------------------------------------------------------
# AsyncRAGHook state
# ---------------------------------------------------------------------------

_KI_API_KEY: str = os.environ.get("KI_API_KEY", "")

_RAG_TOP_K: int = int(os.environ.get("KI_RAG_TOP_K", "3"))

# Models that default to chain-of-thought / thinking mode and should have it
# disabled at the proxy level unless the caller explicitly opts in.
_THINKING_MODELS: tuple[str, ...] = ("qwen3",)


def _maybe_disable_thinking(data: dict) -> None:
    """Disable thinking mode for Qwen3 models via reasoning_effort=none.

    Qwen3's thinking mode consumes the entire max_tokens budget for the reasoning
    chain before generating any content, returning empty content for small limits.
    LiteLLM's ollama_chat provider maps reasoning_effort=none → think:false in the
    Ollama API body, which fully disables thinking regardless of token budget.

    Does nothing if the caller has already set reasoning_effort or think preference.
    """
    model: str = data.get("model", "").lower()
    if not any(m in model for m in _THINKING_MODELS):
        return
    # Caller already specified a preference — respect it
    if "reasoning_effort" in data:
        return
    if "think" in data:
        return
    extra_body: dict = data.get("extra_body") or {}
    if "think" in extra_body:
        return
    # Disable thinking via the OpenAI-compat reasoning_effort parameter.
    # ollama_chat maps "none" → think:false in the Ollama request body.
    data["reasoning_effort"] = "none"


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

        # Disable thinking mode by default for models that enable it implicitly
        _maybe_disable_thinking(data)

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


# Module-level singletons registered by LiteLLM via get_instance_fn.
# proxy_config.yaml references these by dotted name (must be instances,
# not classes, for isinstance(cb, CustomLogger) checks to pass).
# Registration order in proxy_config.yaml: content_review_hook first,
# async_rag_hook second — review before RAG query.
content_review_hook = ContentReviewHook()
async_rag_hook = AsyncRAGHook()
