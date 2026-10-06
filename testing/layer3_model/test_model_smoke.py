# testing/layer3_model/test_model_smoke.py
#
# Layer 3e — Model Smoke Test (T-098, T-099)
#
# T-098: Single-turn "Hello." smoke check for every model LiteLLM currently
#        has registered — enumerated from GET /model/info, the same source
#        scripts/model-inventory.sh reads its roster from. A model disabled
#        via configs/config.json's `"enabled": false` (and therefore absent
#        from configure.sh's generated LiteLLM config) is correctly invisible
#        here too — it was never written to LiteLLM's model table.
# T-099: Same conversation (full message history carried forward, matching
#        the test_higher_order.py multi-turn pattern) — asks a basic
#        arithmetic question to confirm the model is actually reasoning,
#        not just echoing.
#
# Deliberately NOT gated behind the model_available/default_test_model
# fixtures — this test enumerates every registered model and is meant to
# double as an on-demand availability smoke test, not just a full-suite
# citizen. A model with no backend running fails its own parametrized case
# so broken models are visible individually rather than skipping the module.
#
# Run (every registered model):
#   pytest testing/layer3_model/test_model_smoke.py -v
# Run (one model, by id):
#   pytest testing/layer3_model/test_model_smoke.py -v -k "<model-id-substring>"
# Or: make test-model-smoke

import httpx
import pytest

from .conftest import LITELLM_BASE_URL, _read_secret
from .test_higher_order import chat_completion

MAX_TOKENS = 60


# ---------------------------------------------------------------------------
# Build parametrize list at collection time — one test ID per registered model
# ---------------------------------------------------------------------------

def _registered_models() -> tuple[dict[str, set], str]:
    """
    Unique model_name -> model_info.tags set, from LiteLLM's GET /model/info.
    Returns (models, skip_reason) — skip_reason is "" when models is usable.
    """
    master_key = _read_secret("litellm_master_key")
    if not master_key:
        return {}, (
            "litellm_master_key not available — "
            "set LITELLM_MASTER_KEY env var or provision the Podman secret"
        )

    try:
        response = httpx.get(
            f"{LITELLM_BASE_URL}/model/info",
            headers={"Authorization": f"Bearer {master_key}"},
            timeout=15.0,
        )
        response.raise_for_status()
        entries = response.json().get("data", [])
    except Exception as exc:
        return {}, f"LiteLLM /model/info not reachable: {exc}"

    models = {
        e["model_name"]: set(e.get("model_info", {}).get("tags") or [])
        for e in entries
        if e.get("model_name")
    }
    if not models:
        return {}, "LiteLLM /model/info returned no registered models"

    return models, ""


_models, _skip_reason = _registered_models()
_model_params = (
    [pytest.param(name, id=name) for name in sorted(_models)]
    if _models
    else [pytest.param(None, id="no-models-registered")]
)


# ---------------------------------------------------------------------------
# T-098 / T-099 — "Hello." then, same session, basic arithmetic
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("model_name", _model_params)
def test_model_smoke_hello_and_arithmetic(
    http_client: httpx.Client, litellm_headers: dict, model_name: str | None
) -> None:
    """T-098/T-099: every registered model answers 'Hello.' then, in the same
    conversation, correctly answers 'What is 2 and 2 added together?'."""
    if model_name is None:
        pytest.skip(_skip_reason)

    # Only "thinking"-tagged models (Ollama reasoning models that can spend the
    # whole max_tokens budget on hidden chain-of-thought) get reasoning_effort.
    # Sent to every model, this breaks providers whose LiteLLM config doesn't
    # recognize the value at all (confirmed: Anthropic 500s on "disable").
    reasoning_effort = "disable" if "thinking" in _models.get(model_name, set()) else None

    turn1_messages = [{"role": "user", "content": "Hello."}]
    try:
        body1 = chat_completion(
            http_client, litellm_headers, model_name, turn1_messages,
            max_tokens=MAX_TOKENS, reasoning_effort=reasoning_effort,
        )
    except AssertionError as exc:
        pytest.fail(f"[{model_name}] T-098 'Hello.' request failed: {exc}")

    reply1 = body1["choices"][0]["message"]["content"]
    assert reply1 and reply1.strip(), (
        f"[{model_name}] T-098: empty response to 'Hello.'"
    )

    turn2_messages = turn1_messages + [
        {"role": "assistant", "content": reply1},
        {"role": "user", "content": "What is 2 and 2 added together?"},
    ]
    try:
        body2 = chat_completion(
            http_client, litellm_headers, model_name, turn2_messages,
            max_tokens=MAX_TOKENS, reasoning_effort=reasoning_effort,
        )
    except AssertionError as exc:
        pytest.fail(f"[{model_name}] T-099 arithmetic request failed: {exc}")

    reply2 = body2["choices"][0]["message"]["content"].lower()
    assert "4" in reply2 or "four" in reply2, (
        f"[{model_name}] T-099: expected an answer containing '4' or 'four', "
        f"got: {reply2!r}"
    )
