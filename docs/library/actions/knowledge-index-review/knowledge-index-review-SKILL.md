---
name: knowledge-index-review
description: >
  Implement or update the Content Review layer for the Knowledge Index pipeline.
  Applies at two enforcement points: (1) LiteLLM pre-call hook (every inference
  request) and (2) Knowledge Index ingestion endpoints (documents + library
  ingest). Four review categories: Security violations, Privacy violations,
  Credential detection, Content moderation. Hard reject for categories A–C;
  configurable log/queue/reject for category D. Use when: adding content review
  to the stack for the first time; updating detection rules; adding a review
  queue; hardening an existing implementation.
argument-hint: 'Optional: --category A|B|C|D  to scope work to one category'
---

# Knowledge Index — Content Review

Adds a multi-category content review layer to the AI stack inference and
document ingestion paths.  The review layer operates at two enforcement
points and applies four ordered categories of checks.  The goal is to
detect and reject (or queue) harmful, unsafe, or policy-violating content
before it reaches the model or enters the knowledge store — while never
leaking review specifics to the caller.

---

## Enforcement Points

```
User query ──► LiteLLM Proxy ──► AsyncRAGHook (Point 1: inference-time review)
                                      │ rejected? → log + raise
                                      ▼
                               Ollama inference ──► caller

Document ──► KI POST /documents  (Point 2: ingestion-time review)
          or POST /v1/libraries       │ rejected? → log + 422 generic
                                      ▼
                               Qdrant storage
```

| Point | File | Trigger | Hook class |
|---|---|---|---|
| Inference-time | `configs/litellm/hooks.py` | Every chat/completion call | `ContentReviewHook` (new, alongside `AsyncRAGHook`) |
| Ingestion-time | `services/knowledge-index/app.py` | `POST /documents`, `POST /v1/libraries`, `POST /v1/scan` (per-file) | `_review_content()` helper (new) |

---

## Review Categories

Categories are evaluated in priority order.  A match in any category short-circuits
further evaluation for that request — do not fall through to lower categories once a
rejection is determined.

### Category A — Security Violations

**Policy:** Hard reject.  Log rule name and a SHA-256 fingerprint of the offending
segment (never the raw text).  Return generic message to caller.

**Scope:** Both inference (input messages) and ingestion (document text).

Detection patterns — evaluate with `re.search(pattern, text, re.IGNORECASE)`:

```python
SECURITY_PATTERNS = [
    # LLM environment jailbreaking
    (r'\bignore\s+(all\s+)?previous\s+instructions?\b',   'jailbreak:ignore-previous'),
    (r'\bact\s+as\s+(if\s+you\s+(were|are)|a\s+|an?\s+)',  'jailbreak:act-as'),
    (r'\b(DAN|developer\s+mode|jailbreak|unrestricted\s+mode|STAN|DUDE)\b',
                                                            'jailbreak:mode-switch'),
    (r'\bpretend\s+(you\s+are|to\s+be)\b',                'jailbreak:pretend'),
    (r'\byour\s+(true|real|actual|hidden)\s+(self|purpose|instructions?)\b',
                                                            'jailbreak:hidden-self'),
    (r'\bsystem\s*prompt\s*(is|was|should|will)\b',        'jailbreak:system-prompt-disclosure'),
    # Container / host escape
    (r'\b(nsenter|unshare|pivot_root|chroot)\b',          'escape:container-syscall'),
    (r'/proc/(self|[0-9]+)/(ns|fd|mem|maps)\b',            'escape:proc-traversal'),
    (r'\b--privileged\b',                                  'escape:privileged-flag'),
    (r'\b(cap_sys_admin|cap_net_admin|setuid)\b',          'escape:capability'),
    (r'\bcgroup(s|v2)?\b.*\b(write|modify|escape)\b',     'escape:cgroup-write'),
    # Privilege escalation
    (r'\bsudo\s+(-[si]|bash|sh|su\b)',                    'privesc:sudo-shell'),
    (r'\bsu\s+(-\s+)?root\b',                             'privesc:su-root'),
    (r'\bchmod\s+(777|[0-7]{3,4}s)\b',                   'privesc:chmod-suid'),
    (r'\b/etc/(passwd|shadow|sudoers)\b',                 'privesc:sensitive-file'),
    # Code/command injection
    (r'\beval\s*\(',                                       'injection:eval'),
    (r'__import__\s*\(',                                   'injection:dunder-import'),
    (r'\bsubprocess\.(call|run|Popen|check_output)\s*\(', 'injection:subprocess'),
    (r'\bos\.(system|popen|execv?[ep]?)\s*\(',            'injection:os-exec'),
    (r'\bexec\s*\(["\']',                                  'injection:exec-string'),
    # Rerouting / exfiltration
    (r'https?://(?!localhost|127\.|10\.|192\.168\.|172\.1[6-9]\.|172\.2[0-9]\.|172\.3[01]\.)',
                                                            'exfil:external-url-in-doc'),
    (r'\b(curl|wget|fetch|requests\.get)\s+https?://',    'exfil:outbound-fetch-command'),
    (r'\b(base64|b64decode|atob)\b.*\beval\b',            'exfil:encoded-exec'),
    # Denial of service (resource exhaustion patterns)
    (r'(.)\1{2000,}',                                      'dos:repeated-char'),
    (r'(\b\w+\b.{0,20}){500,}',                           'dos:token-flood'),
    # Package injection
    (r'\b(pip|pip3)\s+install\s+(?!-r\s)',                'inject:pip-install'),
    (r'\b(npm|yarn)\s+(install|add)\s+',                   'inject:npm-install'),
    (r'\bapt(-get)?\s+install\s+',                        'inject:apt-install'),
]
```

**Caller response (generic — do not vary the wording):**
```
{"error": "Request rejected by content policy.", "code": "POLICY_A"}
```
HTTP status: 422 (KI) / raise `ValueError("Request rejected by content policy.")` (LiteLLM hook).

---

### Category B — Privacy Violations

**Policy:** Hard reject.  Log pattern matched and a count of matches.  Never log
the matched value.

**Scope:** Both enforcement points.

Detection patterns:

```python
PRIVACY_PATTERNS = [
    # PII
    (r'\b\d{3}-\d{2}-\d{4}\b',                            'pii:ssn'),
    (r'\b(?:\d[ -]?){13,16}\b',                           'pii:payment-card'),   # loose; false-pos acceptable
    (r'\b[A-Z]{1,2}\d{6,9}\b',                            'pii:passport-number'),
    (r'\b\+?[0-9]{1,3}[\s.-]?\(?\d{3}\)?[\s.-]?\d{3}[\s.-]?\d{4}\b',
                                                            'pii:phone-number'),
    # Cross-user data leakage
    (r'\b(another|other|different)\s+user[\'s]*\s+(session|data|token|key|password|email)\b',
                                                            'privacy:cross-user-data-reference'),
    (r'\buser[_-]?id[s]?\s*[=:]\s*[^\s]{3,}\b',          'privacy:user-id-disclosure'),
    (r'\bsession[_-]?token[s]?\s*[=:]\s*[^\s]{10,}\b',   'privacy:session-token'),
    # Email addresses in documents (log only — not a hard reject for ingestion
    # unless in a context that implies cross-user leakage)
    # Flag for review rather than hard-reject: see Category D handling note below.
    (r'\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b',
                                                            'pii:email-address'),
]

# Email addresses: flag in inference context (reject), allow in documents
# (flag for review queue — operator may legitimately ingest contact lists).
# Apply differentiated policy: INFERENCE_ONLY_PATTERNS vs BOTH_POINTS_PATTERNS.
INFERENCE_ONLY_PATTERNS = ['pii:email-address']
```

**Caller response:**
```
{"error": "Request rejected by content policy.", "code": "POLICY_B"}
```

---

### Category C — Credential Detection

**Policy:** Hard reject at all times.  Log pattern name, a 8-char hex prefix of the
matched value's SHA-256 hash (for post-incident correlation without storing the
credential), and source endpoint.  Rotate the credential immediately if it belongs
to this system.

**Scope:** Both enforcement points.  Credential leakage is equally dangerous in
inference (where a user might accidentally paste a key) and ingestion (where a
scrape of a config file could land in the vector store).

Detection patterns:

```python
CREDENTIAL_PATTERNS = [
    # Generic high-entropy strings (heuristic — high false-positive risk; use entropy check)
    # Apply only if Shannon entropy > 4.5 AND length > 20 AND no spaces
    # (implement via _high_entropy_check() helper — see §Implementation)
    # Well-known credential formats
    (r'\bsk-[A-Za-z0-9]{20,}\b',                         'cred:openai-key'),
    (r'\bAKIA[0-9A-Z]{16}\b',                             'cred:aws-access-key'),
    (r'\bghp_[A-Za-z0-9]{36}\b',                          'cred:github-pat'),
    (r'\bghs_[A-Za-z0-9]{36}\b',                          'cred:github-actions-secret'),
    (r'\bxox[baprs]-[0-9A-Za-z\-]{10,}\b',               'cred:slack-token'),
    (r'\bAIza[0-9A-Za-z\-_]{35}\b',                       'cred:google-api-key'),
    (r'\bEYJ[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}\.[A-Za-z0-9_\-]{20,}',
                                                            'cred:jwt-token'),
    # Connection strings with embedded credentials
    (r'[a-zA-Z][a-zA-Z0-9+\-.]*://[^:@\s]+:[^@\s]+@',   'cred:url-with-password'),
    # Private keys (multi-line)
    (r'-----BEGIN\s+(RSA|EC|DSA|OPENSSH|PGP)?\s*PRIVATE KEY-----',
                                                            'cred:private-key-pem'),
    # .env / shell assignment of sensitive names
    (r'(?:PASSWORD|SECRET|API_KEY|TOKEN|ACCESS_KEY)\s*=\s*[^\s$\'\"]{6,}',
                                                            'cred:env-assignment'),
    # Podman secret value leakage (exact known format from this stack)
    (r'(?:litellm_master_key|qdrant_api_key|knowledge_index_api_key|flowise_secret_key)\s*[=:]\s*[^\s]{6,}',
                                                            'cred:stack-secret-leaked'),
]
```

**Caller response:**
```
{"error": "Request rejected by content policy.", "code": "POLICY_C"}
```

**Post-rejection action (human/operator):**
- If the matched pattern includes a stack-internal secret name, rotate that secret immediately.
- See §4.4 of the operational playbook for rotation procedures.

---

### Category D — Content Moderation

**Policy:** Always log.  Configurable response mode per subcategory:
- `warn` — allow request, annotate log with flag (default for rant/negativity)
- `queue` — hold for operator review before allowing (see §Review Queue)
- `reject` — hard reject, same generic message as A–C

Default response mode: `warn` for `profanity:mild`; `queue` for `profanity:strong`,
`violence:implied`, `mature:implied`; `reject` for `violence:explicit`, `mature:explicit`.
Override via `REVIEW_D_<SUBCATEGORY>=warn|queue|reject` environment variables.

**Scope:** Primarily inference-time (user messages, model output via `async_post_call_hook`).
Apply to ingestion also, but with higher thresholds (operator-curated documents may
contain legitimate mature content in metadata — flag, don't hard-reject).

Detection approach for Category D:

```python
# Keyword-based first pass (fast, deterministic)
# Supplement with an LLM-based classifier call for ambiguous cases
# when REVIEW_D_CLASSIFIER_URL is set (see §Configuration).

PROFANITY_STRONG = [  # abbreviated — expand with your policy wordlist
    # Store wordlists in configs/review/profanity_strong.txt (one word per line, gitignored)
    # Load at module init: PROFANITY_STRONG = set(open('configs/review/profanity_strong.txt').read().split())
    # Do not embed wordlists in source — they are themselves "bad language" in doc context
]

VIOLENCE_EXPLICIT = [
    r'\b(kill|murder|execute|shoot|stab)\s+(?:the\s+)?(?:user|person|target|operator)\b',
    r'\b(bomb|explosive|detonate)\s+(placed?|set|trigger)\b',
    r'\bhow\s+to\s+(make|build|assemble)\s+(?:a\s+)?(?:bomb|weapon|explosive)\b',
]

MATURE_EXPLICIT = [
    # NSFW keyword patterns — store in configs/review/mature_explicit.txt (gitignored)
]
```

**Review queue (Category D — `queue` mode):**
See §Review Queue Implementation below.

**Caller response when `reject`:**
```
{"error": "Request rejected by content policy.", "code": "POLICY_D"}
```

---

## Logging Format

All review events MUST be written as structured JSON to stderr (captured by Promtail):

```json
{
  "ts": "2026-04-07T14:23:01.123Z",
  "level": "WARN",
  "event": "content_review",
  "enforcement_point": "litellm_hook",
  "category": "A",
  "rule": "jailbreak:ignore-previous",
  "action": "rejected",
  "request_id": "<litellm request uuid or ki endpoint path>",
  "content_hash": "<sha256 hex of full input[:1024]>",
  "match_hash": "<hex[:8] of sha256 of matched segment>"
}
```

**Never log:**
- The raw matched string or the full request content
- User-identifying information beyond the request ID
- The offending content itself (logging it creates a secondary exposure vector)

Use this helper at both enforcement points:

```python
import hashlib, json, sys
from datetime import datetime, timezone

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
```

Loki query to monitor review events:
```logql
{container_name=~"litellm|knowledge-index"} |= "content_review" | json
  | category="A" or category="B" or category="C"
```

---

## Review Queue Implementation (Category D)

When response mode is `queue`, the ingestion request is accepted (HTTP 202) but
not stored in Qdrant.  The content is held in a `review_queue` SQLite/PostgreSQL
table pending operator approval.

### Database schema

Add to `services/knowledge-index/app.py` in `_init_db()`:

```python
conn.execute(text("""
    CREATE TABLE IF NOT EXISTS review_queue (
        id          TEXT PRIMARY KEY,
        created_at  TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
        category    TEXT NOT NULL DEFAULT 'D',
        rule        TEXT NOT NULL,
        source      TEXT NOT NULL,          -- 'inference' or 'ingestion'
        status      TEXT NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending','approved','rejected')),
        reviewed_at TIMESTAMP,
        reviewed_by TEXT,
        content_hash TEXT NOT NULL,         -- sha256 of the content (for correlation)
        metadata    TEXT NOT NULL DEFAULT '{}'
    )
"""))
```

### Operator review endpoints

Add to `app.py` — both endpoints require `KI_ADMIN_KEY`:

```python
@app.get("/v1/review")          # list pending queue items
@app.patch("/v1/review/{id}")   # approve or reject: body {"status": "approved"|"rejected"}
```

### Inference-time queuing

At the LiteLLM hook, queuing means: log the event, allow the inference to
proceed (do not reject), but annotate the response.  The LiteLLM hook cannot
hold a request for async operator review — it is not a pipeline pause point.
Instead: log, annotate, increment a Prometheus counter, and optionally suppress
the response if configured to reject after N accumulated violations from the
same source.

---

## Implementation Steps

### Step 1 — Add `ContentReviewHook` to `configs/litellm/hooks.py`

```python
# After the AsyncRAGHook class and before the module-level singleton

import re
import hashlib
import sys
from datetime import datetime, timezone

# Compile all patterns once at import time
_SEC_COMPILED  = [(re.compile(p, re.IGNORECASE | re.DOTALL), name) for p, name in SECURITY_PATTERNS]
_PRIV_COMPILED = [(re.compile(p, re.IGNORECASE), name) for p, name in PRIVACY_PATTERNS]
_CRED_COMPILED = [(re.compile(p, re.IGNORECASE | re.DOTALL), name) for p, name in CREDENTIAL_PATTERNS]


class ContentReviewHook(CustomLogger):
    """
    LiteLLM callback that reviews user messages for policy violations
    before inference.  Hard rejects categories A–C; configurable for D.
    """

    async def async_pre_call_hook(
        self,
        user_api_key_dict,
        cache,
        data: dict,
        call_type: str,
    ):
        if call_type not in ("completion", "acompletion"):
            return data

        messages = data.get("messages", [])
        user_content = " ".join(
            m.get("content", "") for m in messages
            if m.get("role") in ("user", "system") and isinstance(m.get("content"), str)
        )
        if not user_content:
            return data

        request_id = str(data.get("litellm_call_id", "unknown"))
        _review_or_raise(user_content, enforcement_point="litellm_hook", request_id=request_id)
        return data


def _review_or_raise(text: str, *, enforcement_point: str, request_id: str) -> None:
    """
    Apply all review categories.  Raise ValueError on rejection.
    ValueError propagates to the caller as an error response from LiteLLM.
    """
    for pattern, rule in _SEC_COMPILED:
        m = pattern.search(text)
        if m:
            _log_review_event(
                enforcement_point=enforcement_point, category="A", rule=rule,
                action="rejected", request_id=request_id,
                full_content=text, matched_segment=m.group(0),
            )
            raise ValueError("Request rejected by content policy.")

    for pattern, rule in _PRIV_COMPILED:
        m = pattern.search(text)
        if m:
            _log_review_event(
                enforcement_point=enforcement_point, category="B", rule=rule,
                action="rejected", request_id=request_id,
                full_content=text, matched_segment=m.group(0),
            )
            raise ValueError("Request rejected by content policy.")

    for pattern, rule in _CRED_COMPILED:
        m = pattern.search(text)
        if m:
            _log_review_event(
                enforcement_point=enforcement_point, category="C", rule=rule,
                action="rejected", request_id=request_id,
                full_content=text, matched_segment=m.group(0),
            )
            raise ValueError("Request rejected by content policy.")

    # Category D — warn/queue/reject per subcategory (implementation in Phase 2+)
    # Placeholder: implement when profanity/violence/mature wordlists are ready.


# Add to module-level singletons:
content_review_hook = ContentReviewHook()
```

Register the new hook in `configs/litellm/proxy_config.yaml`:

```yaml
litellm_settings:
  callbacks:
    - hooks.async_rag_hook
    - hooks.content_review_hook   # ADD THIS LINE
```

> **Order matters:** review runs first if listed before `async_rag_hook`.
> List `content_review_hook` first to avoid wasting a KI query on content
> that will ultimately be rejected.  Swap the order above accordingly.

---

### Step 2 — Add `_review_content()` to `services/knowledge-index/app.py`

```python
def _review_content(text: str, *, source_endpoint: str) -> None:
    """
    Apply content review to ingested document text.
    Raises HTTPException(422) on hard rejection (categories A–C).
    Queues and returns normally for category D queue-mode matches.
    """
    import re, hashlib
    for pattern, rule in _SEC_COMPILED:
        m = pattern.search(text)
        if m:
            _log_review_event(
                enforcement_point="ki_ingestion", category="A", rule=rule,
                action="rejected", request_id=source_endpoint,
                full_content=text, matched_segment=m.group(0),
            )
            raise HTTPException(status_code=422, detail="Document rejected by content policy.")
    # ... repeat for B and C ...
```

Call `_review_content(body.content, source_endpoint="/documents")` at the top
of the `POST /documents` handler, before any chunking or embedding occurs.

For `POST /v1/libraries`: extract and review the manifest metadata + any
`README`-equivalent content from the `.ai-library` package before storing.

---

### Step 3 — Wordlist files (Category D)

Create (manually, do not commit wordlists to git — they are policy-sensitive):

```
configs/review/profanity_strong.txt      # one word/phrase per line
configs/review/profanity_mild.txt
configs/review/mature_explicit.txt
```

Add to `.gitignore`:
```
configs/review/
```

Load at module init (both `hooks.py` and `app.py`):

```python
def _load_wordlist(path: str) -> set[str]:
    try:
        return {line.strip().lower() for line in open(path) if line.strip()}
    except FileNotFoundError:
        return set()

_PROFANITY_STRONG = _load_wordlist("configs/review/profanity_strong.txt")
```

---

## Configuration Reference

| Environment Variable | Default | Description |
|---|---|---|
| `REVIEW_ENABLED` | `true` | Master switch — set `false` to disable review globally (do not use in production) |
| `REVIEW_CATEGORIES` | `A,B,C,D` | Comma-separated list of active categories |
| `REVIEW_D_PROFANITY_MILD` | `warn` | Response mode for mild profanity |
| `REVIEW_D_PROFANITY_STRONG` | `queue` | Response mode for strong profanity |
| `REVIEW_D_VIOLENCE_IMPLIED` | `queue` | Response mode for implied violence |
| `REVIEW_D_VIOLENCE_EXPLICIT` | `reject` | Response mode for explicit violence |
| `REVIEW_D_MATURE_IMPLIED` | `queue` | Response mode for implied mature content |
| `REVIEW_D_MATURE_EXPLICIT` | `reject` | Response mode for explicit mature content |
| `REVIEW_D_CLASSIFIER_URL` | _(unset)_ | Optional: URL of an LLM classifier for ambiguous D cases |
| `REVIEW_LOG_LEVEL` | `WARN` | Log level for review events (`INFO` adds allow events) |

Add these to `configs/config.json` under the relevant service's `env` block
so they are picked up by the quadlet generator.  These are policy settings,
not secrets — they may be committed.

---

## Phase 1 — Collect State Before Implementing

Run before any code changes to establish a baseline:

```bash
# Confirm current hook registration
grep -n "callbacks" configs/litellm/proxy_config.yaml

# Confirm current hooks.py exports
grep -n "^[a-z_].*= Async" configs/litellm/hooks.py

# Check existing log output for any pre-existing review events
podman exec loki logcli query '{container_name=~"litellm|knowledge-index"}' \
  --limit 20 --since=1h 2>/dev/null | grep -i "content_review" || echo "(none)"

# Confirm KI endpoints are live
curl -sf -H "Authorization: Bearer $(podman secret inspect knowledge_index_api_key \
  --showsecret --format '{{.SecretData}}')" \
  http://localhost:8100/health | python3 -m json.tool
```

---

## Phase 2 — Quality Checklist

Verify each item before declaring the implementation complete:

- [ ] `content_review_hook` is listed in `proxy_config.yaml` callbacks **before** `async_rag_hook`
- [ ] `ContentReviewHook.async_pre_call_hook` is called and raises `ValueError` on match
- [ ] `_review_content()` is called in `POST /documents` before any Qdrant write
- [ ] `_review_content()` is called in `POST /v1/libraries` before any DB write
- [ ] All patterns are compiled once at import; no per-request `re.compile()`
- [ ] Log records contain `content_hash` and `match_hash` but **not** the raw matched text
- [ ] Caller receives only generic `"code": "POLICY_X"` — no rule name, no matched content
- [ ] Category D wordlist files are gitignored and the `.gitignore` entry is committed
- [ ] `REVIEW_ENABLED=false` is tested: all checks skip, inference proceeds normally
- [ ] BATS test or pytest fixture verifies a known jailbreak pattern returns `POLICY_A`
- [ ] BATS test or pytest fixture verifies a known credential pattern returns `POLICY_C`
- [ ] Loki query `{container_name="litellm"} |= "content_review"` returns review events

---

## Open Items / Future Work

Track in `docs/meta_local/review_log.md` backlog:

1. **Output filtering** — `async_post_call_hook` to review model output before returning
   to caller (catches LLM-generated policy violations, not just user input)
2. **Indirect prompt injection via RAG** — adversarial documents in the knowledge store
   that inject instructions when retrieved; requires reviewing retrieved context in
   `AsyncRAGHook` before injecting into the system message
3. **Multi-turn accumulation** — detect gradual context manipulation across a conversation
   by reviewing the full message history, not just the last user message
4. **Adversarial encoding bypass** — Unicode homoglyphs, base64/rot13 obfuscation,
   zero-width characters used to evade regex patterns; requires normalization pass
   before pattern matching
5. **Multilingual coverage** — current patterns are English-centric; non-English
   jailbreaks and profanity need language-aware detection
6. **Model-based classifier** — supplement regex with a lightweight classifier (e.g.,
   `Llama Guard` or `ShieldLM`) for high-confidence ambiguous category D cases;
   wire via `REVIEW_D_CLASSIFIER_URL`
7. **Rate limiting / abuse detection** — track violations per source IP or user API key;
   after N violations in a window, escalate response mode automatically
8. **Operator alerting** — emit Prometheus counter `content_review_violations_total`
   labelled by category; wire alert in `configs/prometheus/rules/` when count
   exceeds threshold in 24h window
9. **Review queue drain notifications** — alert when `review_queue` has > N pending
   items; prevents operator blind spots
10. **Audit trail immutability** — forward review logs to an append-only store
    (e.g., MinIO object storage) for tamper-evident audit trail; standard Loki
    retention (7 days) is insufficient for compliance use cases
