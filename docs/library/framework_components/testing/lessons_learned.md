# Testing — Lessons Learned
**Last Updated:** 2026-03-08 UTC

## Purpose
Empirical findings from designing and writing the 92-item integration test suite (T-001–T-092) for the AI stack. Records decisions, surprises, and patterns that diverged from initial assumptions. See the master plan in `docs/ai_stack_testing.md` and `testing/README.md` for suite overview.

---

## Table of Contents

1. [BATS `skip` vs `fail` for Deferred Services](#1-bats-skip-vs-fail-for-deferred-services)
2. [Authentik Has No Host Port — Use podman exec as Network Proxy](#2-authentik-has-no-host-port--use-podman-exec-as-network-proxy)
3. [pytest Session-Scoped Fixture for Module-Level Skip Gating](#3-pytest-session-scoped-fixture-for-module-level-skip-gating)
4. [RAG Module Skip via autouse Fixture](#4-rag-module-skip-via-autouse-fixture)
5. [Tool-Calling: Skip on 400 or Text Response, Not Fail](#5-tool-calling-skip-on-400-or-text-response-not-fail)
6. [Secret Rotation Restore in Both Pass and Fail Paths](#6-secret-rotation-restore-in-both-pass-and-fail-paths)
7. [`podman inspect --format '{{.Config.User}}'` Is Unreliable as Sole Non-Root Check](#7-podman-inspect---format-configuser-is-unreliable-as-sole-non-root-check)
8. [`ss -tlnp` Column Parsing — Use Column 4 and Match Exactly](#8-ss--tlnp-column-parsing--use-column-4-and-match-exactly)
9. [Set `temperature=0.0` for All Deterministic Reasoning Assertions](#9-set-temperature00-for-all-deterministic-reasoning-assertions)
10. [T-055 Design: Unconditional API Shape Test Before Any Model Is Loaded](#10-t-055-design-unconditional-api-shape-test-before-any-model-is-loaded)

---

## 1. BATS `skip` vs `fail` for Deferred Services

**Discovered:** Batch 2 (layer2_traefik.bats, T-021 and T-024)

### What Happened
Traefik dynamic route configuration files do not exist until `configure.sh` is run for specific services. Writing the tests as outright failures would cause every run of the suite to fail until those files were created, even on a fresh install where the intent is clear.

### Decision
Use `bats skip` with a descriptive diagnostic string whenever a precondition file or service is absent *by design* (i.e., deferred services that have not been deployed yet). The test is not deleted; it auto-activates the moment the precondition is satisfied, with no edits required.

```bash
@test "T-021: Traefik router list includes all expected service routes" {
    [[ -f "$TRAEFIK_DYNAMIC_DIR/services.yml" ]] || \
        skip "Dynamic route config not yet created — run configure.sh first"
    ...
}
```

### Rule
- Use `skip` when a dependency is **intentionally absent** (deferred service, optional feature).
- Use `fail` when the dependency **must already exist** for the test to be valid.
- Always include a skip message that tells the operator exactly what to do to un-skip the test.

---

## 2. Authentik Has No Host Port — Use podman exec as Network Proxy

**Discovered:** Batch 3 (layer2_authentik.bats, T-033–T-035)

### What Happened
Authentik is intentionally not exposed on any host port. It sits behind Traefik on `ai-stack-net` only. Attempting to reach it via `http://localhost:<port>` from the test host always fails. The test cannot use `curl` from the host shell directly.

### Solution
Execute the curl command inside a running container that is already attached to `ai-stack-net`, using `podman exec`:

```bash
local proxy_container
proxy_container=$(podman ps --filter "network=ai-stack-net" --format "{{.Names}}" | head -1)
[[ -n "$proxy_container" ]] || skip "No running container on ai-stack-net to proxy through"

status=$(podman exec "$proxy_container" \
    curl -sf -o /dev/null -w "%{http_code}" http://authentik:9000/api/v3/core/applications/ 2>/dev/null)
```

### Rule
For any service with no host port, find a suitable proxy container on the shared Podman network and execute requests from within it. Do not add a host port just for testing.

---

## 3. pytest Session-Scoped Fixture for Module-Level Skip Gating

**Discovered:** Batch 5 (layer3_model/conftest.py, `model_available` fixture)

### What Happened
Multiple test modules in `layer3_model/` need to be skipped entirely when no model is loaded. Initially considered decorating every test function with `@pytest.mark.skipif(...)`, which would produce N individual SKIP records and requires repeating the condition everywhere.

### Solution
Define a session-scoped fixture (`model_available`) that calls `pytest.skip()` inside itself if the model is unavailable. Any test that requests this fixture is automatically skipped with a single, consistent SKIP record:

```python
@pytest.fixture(scope="session")
def model_available(litellm_master_key: str, http_client: httpx.Client, ...) -> str:
    resp = http_client.get("/models", headers={"Authorization": f"Bearer {litellm_master_key}"})
    if resp.status_code != 200 or not resp.json().get("data"):
        pytest.skip("No models loaded in LiteLLM — deploy a model first")
    return resp.json()["data"][0]["id"]
```

### Rule
Use a session-scoped fixture as a "gate" when an entire module depends on a single precondition. This is cleaner than per-test `skipif` decorators and produces one skip record for the session rather than N.

---

## 4. RAG Module Skip via autouse Fixture

**Discovered:** Batch 6 (test_rag_pipeline.py)

### What Happened
The entire RAG test module is meaningless if the knowledge-index service is unreachable. Rather than guarding every test function individually, the module needed a single "if knowledge-index is down, skip everything" mechanism.

### Solution
Define a module-scoped `autouse=True` fixture that issues `pytest.skip()` if the service is unreachable. Because it is `autouse`, pytest applies it to every test in the module automatically:

```python
@pytest.fixture(scope="module", autouse=True)
def require_knowledge_index(http_client):
    try:
        r = http_client.get(f"{KNOWLEDGE_INDEX_URL}/api/v1/collections")
        if r.status_code not in (200, 401):
            pytest.skip(f"knowledge-index not ready (status {r.status_code})")
    except httpx.ConnectError:
        pytest.skip("knowledge-index not reachable — deploy it first")
```

### Rule
- Use `autouse=True` module-scoped fixtures to gate entire test modules on infrastructure availability.
- Prefer this over `pytest.importorskip` for runtime (not import-time) conditions.

---

## 5. Tool-Calling: Skip on 400 or Text Response, Not Fail

**Discovered:** Batch 6 (test_higher_order.py, T-072)

### What Happened
When a model does not support function-calling, backends react differently:
- Some return HTTP 400 with an error message.
- Others return HTTP 200 with a plain text reply instead of a `tool_calls` block.
Neither case is a legitimate test failure — it is a capability gap in the currently-loaded model.

### Solution
Catch the 400 case in the assertion and convert it to `pytest.skip`. For the 200+text case, check `finish_reason` and `tool_calls` presence; if missing, skip with a diagnostic message:

```python
if finish_reason == "tool_calls" or tool_calls:
    # validate structure
    ...
else:
    pytest.skip(f"Model '{model}' returned text instead of tool_calls — may not support function calling")
```

### Rule
Test capability features (tool-calling, structured output, image input) with `skip` on negative outcomes unless the model's spec guarantees support. Only `fail` if the model is documented to support the feature and the stack is mis-configured.

---

## 6. Secret Rotation Restore in Both Pass and Fail Paths

**Discovered:** Batch 4 (layer2b_lifecycle.bats, T-052)

### What Happened
T-052 tests credential rotation by replacing a secret with a new value, verifying the service rejects the old credential, then restoring the original. On the first draft, the restore step was only executed after a successful assertion. A test failure mid-rotation left the stack in a broken state with no way to recover automatically.

### Solution
Capture the original secret value before the test body, then restore it unconditionally using a BATS `teardown()` function that runs even after a failure:

```bash
setup() {
    ORIGINAL_PG_PASS=$(read_secret postgres_password)
}

teardown() {
    # Always restore the original password
    printf '%s' "$ORIGINAL_PG_PASS" | podman secret create --replace postgres_password - >/dev/null 2>&1 || true
    systemctl --user restart postgres.service 2>/dev/null || true
}
```

### Rule
Any test that mutates live system state (secrets, configs, running services) **must** unconditionally restore that state. In BATS use `teardown()`; in pytest use `yield` fixtures or `addfinalizer`. Never rely on assertions to reach the restore step.

---

## 7. `podman inspect --format '{{.Config.User}}'` Is Unreliable as Sole Non-Root Check

**Discovered:** Batch 6 (security/test_auth_enforcement.py, T-092)

### What Happened
Several official container images (notably Prometheus and Grafana) do not set a `USER` directive in their Dockerfile but drop privileges via their entrypoint script at runtime. `podman inspect --format '{{.Config.User}}'` returns an empty string for these images even though the process runs as a non-root UID.

Treating an empty User field as a failure would produce false positives for well-behaved images.

### Decision
Flag empty User as suspicious (conservatively correct) and document the known exceptions. The test assertion remains strict — any operator-built images must set `USER` explicitly. For upstream images known to drop privs at runtime, add them to an exception list in the test with an explanatory comment.

### Rule
- Always set `USER <non-root>` in custom Dockerfiles/Containerfiles.
- For upstream images that drop privs at runtime, verify with `podman exec <container> id` as a supplementary check, not `inspect`.

---

## 8. `ss -tlnp` Column Parsing — Use Column 4 and Match Exactly

**Discovered:** Batch 6 (layer4_localhost.bats, T-073 / security/test_auth_enforcement.py, T-087)

### What Happened
Initial version used `grep "0.0.0.0:<port>"` directly on `ss -tlnp` output. This produced false positives because:
- IPv6 wildcard `:::5432` is a different address family but the string `5432` appears on the same line.
- Column alignment in `ss` output varies between kernel versions; grepping the raw line is fragile.

### Solution
Extract column 4 (`awk '{print $4}'`) — the "Local Address:Port" field — and match it exactly:

```bash
if ss -tlnp | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*):${port}$"; then
    failed_list+=("$port")
fi
```

### Rule
When parsing `ss` output programmatically, always isolate the Local Address column rather than grepping the full line. Use an anchored regex (`^...$`) to prevent partial matches across IPv4 and IPv6 entries.

---

## 9. Set `temperature=0.0` for All Deterministic Reasoning Assertions

**Discovered:** Batch 5 (test_baseline_reasoning.py, T-058–T-061)

### What Happened
Early drafts of the arithmetic test (T-059, `17 + 25 = ?`) used the model's default temperature. On a quantised model with default settings, occasional sampling noise caused the model to produce `43` or `41` instead of `42`, making the test flaky.

### Solution
Always set `"temperature": 0.0` in any test that makes an exact-string assertion on model output:

```python
body = chat_completion(..., temperature=0.0)
```

Some backends clamp temperature to a small positive floor (e.g. 1e-7) but this is still deterministic enough for test assertions.

### Rule
- Set `temperature=0.0` for all tests asserting on specific text, numbers, or JSON structure.
- Reserve non-zero temperatures for tests that verify output *variety* (currently none in this suite).

---

## 10. T-055 Design: Unconditional API Shape Test Before Any Model Is Loaded

**Discovered:** Batch 5 (test_model_availability.py, T-055)

### What Happened
All Layer 3 tests depend on a loaded model. However, having *no* immediately-runnable test in the layer would mean the entire suite would produce zero results in a fresh environment — providing no signal about whether the LiteLLM API itself is functional.

### Decision
T-055 fires unconditionally and sends a request for a sentinel model name (`test-nonexistent-model-xyzzy`). The expected outcome is not a 200 — it is a clean, well-formed 4xx JSON error body (e.g. `{"error": {"message": "...", "type": "...", "code": 404}}`). A 500 or a non-JSON body indicates a LiteLLM misconfiguration, not an absent model.

```python
def test_litellm_returns_structured_error_for_unknown_model(...):
    resp = http_client.post("/chat/completions", json={"model": "test-nonexistent-model-xyzzy", ...})
    assert resp.status_code in (400, 404, 422)
    body = resp.json()
    assert "error" in body
```

### Rule
Every test layer should contain at least one unconditional "API shape" test that validates the service is up and handling errors correctly, even in a dependency-free state. This provides a baseline signal independent of loaded models or data.
