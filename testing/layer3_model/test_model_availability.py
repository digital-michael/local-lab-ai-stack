# testing/layer3_model/test_model_availability.py
#
# Layer 3a — Model Availability and Loading (T-055 through T-057)
#
# T-055: No-model gate — LiteLLM returns a structured 4xx error for an
#        unknown model. Expected to PASS (clean error handling is correct
#        behavior). Runs unconditionally, requires no model to be loaded.
#
# T-056: Default model pull — triggers download of models in
#        configs/models.json. Skipped if that file or pull-models.sh
#        do not exist yet (Phase 8c). Polls /models until the model appears.
#
# T-057: Model list non-empty — verifies at least one model is present
#        after T-056. Depends on T-056 passing or a model already loaded.
#
# Run: pytest testing/layer3_model/test_model_availability.py -v

import json
import os
import subprocess
import time

import httpx
import pytest

from .conftest import PROJECT_ROOT, MODELS_FILE, poll_until

LITELLM_BASE_URL = "http://localhost:9000"

# ---------------------------------------------------------------------------
# T-055 — No-model gate: structured error for unknown model
# ---------------------------------------------------------------------------
# This test fires unconditionally — no requires_model fixture. It intentionally
# sends a request for a model that will never exist. The goal is to confirm
# LiteLLM handles the unknown-model case gracefully (4xx + JSON) rather than
# panicking (500) or hanging.
# ---------------------------------------------------------------------------

def test_no_model_returns_structured_error(
    http_client: httpx.Client, litellm_headers: dict
) -> None:
    """T-055: LiteLLM returns a structured 4xx JSON error for an unknown model."""
    payload = {
        "model": "nonexistent-bats-t055-sentinel-model",
        "messages": [{"role": "user", "content": "hello"}],
        "max_tokens": 5,
    }

    response = http_client.post(
        "/chat/completions", json=payload, headers=litellm_headers
    )

    # Must not be a server error
    assert response.status_code < 500, (
        f"LiteLLM returned a server error ({response.status_code}) for an unknown "
        f"model. Expected 4xx. Response body: {response.text[:500]}"
    )

    # Must be in the 4xx range
    assert 400 <= response.status_code < 500, (
        f"Expected HTTP 4xx for unknown model, got {response.status_code}. "
        f"Body: {response.text[:500]}"
    )

    # Must return valid JSON
    try:
        body = response.json()
    except Exception:
        pytest.fail(
            f"LiteLLM response is not valid JSON for unknown model request. "
            f"Raw body: {response.text[:500]}"
        )

    # Must contain an error descriptor
    has_error = "error" in body or "detail" in body or "message" in body
    assert has_error, (
        f"Response JSON does not contain an 'error', 'detail', or 'message' field. "
        f"Body: {body}"
    )


# ---------------------------------------------------------------------------
# T-056 — Pull default models from configs/models.json
# ---------------------------------------------------------------------------
# Skipped if configs/models.json or scripts/pull-models.sh do not yet exist.
# Once the pull script exists, this test runs it and polls /models until
# all default models from the JSON list appear.
# ---------------------------------------------------------------------------

PULL_SCRIPT = os.path.join(PROJECT_ROOT, "scripts", "pull-models.sh")
MODEL_PULL_TIMEOUT = int(os.environ.get("MODEL_PULL_TIMEOUT", "600"))  # 10 min


def test_pull_default_models(
    http_client: httpx.Client, litellm_headers: dict
) -> None:
    """T-056: pull-models.sh downloads all default models; they appear in /models."""
    if not os.path.exists(MODELS_FILE):
        pytest.skip(
            f"configs/models.json not found at {MODELS_FILE} — "
            "create the file as part of Phase 8c before running T-056"
        )

    if not os.path.exists(PULL_SCRIPT):
        pytest.skip(
            f"scripts/pull-models.sh not found — "
            "create the script as part of Phase 8c before running T-056"
        )

    # Read expected model IDs
    with open(MODELS_FILE) as f:
        models_config = json.load(f)
    expected_ids = [m["id"] for m in models_config.get("default_models", [])]

    if not expected_ids:
        pytest.skip("configs/models.json has no entries in 'default_models'")

    # Run the pull script
    result = subprocess.run(
        ["bash", PULL_SCRIPT],
        capture_output=True,
        text=True,
        timeout=MODEL_PULL_TIMEOUT,
    )
    assert result.returncode == 0, (
        f"pull-models.sh exited with {result.returncode}.\n"
        f"stdout: {result.stdout[-2000:]}\n"
        f"stderr: {result.stderr[-2000:]}"
    )

    # Poll /models until all expected models appear (up to 5 min post-pull)
    def all_models_loaded() -> bool:
        resp = http_client.get("/models", headers=litellm_headers)
        if resp.status_code != 200:
            return False
        loaded = {m["id"] for m in resp.json().get("data", [])}
        return all(mid in loaded for mid in expected_ids)

    appeared = poll_until(all_models_loaded, timeout_s=300, interval_s=10)
    assert appeared, (
        f"Not all expected models appeared in LiteLLM /models within 5 minutes. "
        f"Expected: {expected_ids}. "
        f"Check LiteLLM logs: journalctl --user -u litellm.service -n 50"
    )


# ---------------------------------------------------------------------------
# T-057 — Model list is non-empty after pull
# ---------------------------------------------------------------------------
# This is a lighter companion to T-056: it just confirms /models is non-empty.
# If a model was already loaded before T-056 ran (e.g., from a previous run),
# this test still passes — idempotent by design.
# ---------------------------------------------------------------------------

def test_model_list_non_empty(
    http_client: httpx.Client, litellm_headers: dict
) -> None:
    """T-057: LiteLLM /models returns at least one model after T-056."""
    response = http_client.get("/models", headers=litellm_headers)
    assert response.status_code == 200, (
        f"GET /models returned {response.status_code}: {response.text[:300]}"
    )

    body = response.json()
    models = body.get("data", [])
    assert len(models) >= 1, (
        "LiteLLM /models returned an empty 'data' array. "
        "Run T-056 (pull_default_models) or load a model manually before this test."
    )

    # Log the loaded model IDs for visibility in pytest output
    loaded_ids = [m["id"] for m in models]
    print(f"\nLoaded models ({len(loaded_ids)}): {loaded_ids}")
