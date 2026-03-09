# testing/layer3_model/test_baseline_reasoning.py
#
# Layer 3b — Baseline Reasoning Tests (T-058 through T-061)
#
# These tests confirm that the loaded model can handle basic, unambiguous
# prompts correctly. They are intentionally simple — designed to catch
# fundamental failures (model not generating text, malformed responses,
# or grossly wrong output), not to benchmark reasoning quality.
#
# All tests require a model to be loaded (model_available fixture).
# If no model is available, the entire module is skipped with a clear message.
#
# Run: pytest testing/layer3_model/test_baseline_reasoning.py -v
# Run with explicit model: TEST_MODEL=llamacpp/phi-3-mini pytest ...

import json
import re

import httpx
import pytest

pytestmark = pytest.mark.requires_model


# ---------------------------------------------------------------------------
# Shared helper
# ---------------------------------------------------------------------------

def chat(
    http_client: httpx.Client,
    litellm_headers: dict,
    model: str,
    user_message: str,
    max_tokens: int = 50,
    temperature: float = 0.0,
) -> str:
    """
    Send a single-turn chat completion and return the response text.
    temperature=0.0 requests deterministic/greedy output.
    Raises AssertionError on non-200 status.
    """
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": user_message}],
        "max_tokens": max_tokens,
        "temperature": temperature,
    }

    response = http_client.post(
        "/chat/completions", json=payload, headers=litellm_headers
    )

    assert response.status_code == 200, (
        f"Chat completion returned {response.status_code}. "
        f"Body: {response.text[:500]}"
    )

    body = response.json()
    choices = body.get("choices", [])
    assert choices, f"Response has no 'choices': {body}"

    text = choices[0].get("message", {}).get("content", "")
    assert text, f"Choice[0].message.content is empty. Full body: {body}"
    return text.strip()


# ---------------------------------------------------------------------------
# T-058 — Echo / identity
# ---------------------------------------------------------------------------

def test_echo_identity(
    http_client: httpx.Client,
    litellm_headers: dict,
    model_available: str,
) -> None:
    """T-058: Model repeats a given word when explicitly asked."""
    response_text = chat(
        http_client,
        litellm_headers,
        model_available,
        "Repeat the word 'canary' exactly once. Do not add any other text.",
        max_tokens=20,
    )

    assert "canary" in response_text.lower(), (
        f"Expected 'canary' in response but got: {response_text!r}"
    )


# ---------------------------------------------------------------------------
# T-059 — Arithmetic
# ---------------------------------------------------------------------------

def test_arithmetic(
    http_client: httpx.Client,
    litellm_headers: dict,
    model_available: str,
) -> None:
    """T-059: Model correctly computes 17 + 25 = 42."""
    response_text = chat(
        http_client,
        litellm_headers,
        model_available,
        "What is 17 + 25? Respond with just the number, nothing else.",
        max_tokens=10,
    )

    assert "42" in response_text, (
        f"Expected '42' in arithmetic response but got: {response_text!r}"
    )


# ---------------------------------------------------------------------------
# T-060 — Sentiment classification
# ---------------------------------------------------------------------------

def test_classification(
    http_client: httpx.Client,
    litellm_headers: dict,
    model_available: str,
) -> None:
    """T-060: Model classifies an obviously positive statement as 'positive'."""
    response_text = chat(
        http_client,
        litellm_headers,
        model_available,
        (
            "Is the following sentence positive or negative? "
            "Sentence: 'I absolutely love this beautiful day!' "
            "Reply with exactly one word: positive or negative."
        ),
        max_tokens=10,
    )

    # Accept "positive" anywhere in the response (handles "Positive.", "positive\n", etc.)
    assert re.search(r"\bpositive\b", response_text, re.IGNORECASE), (
        f"Expected 'positive' in classification response but got: {response_text!r}"
    )

    # Also assert the model did not say 'negative'
    assert not re.search(r"\bnegative\b", response_text, re.IGNORECASE), (
        f"Model classified a clearly positive statement as negative: {response_text!r}"
    )


# ---------------------------------------------------------------------------
# T-061 — JSON output
# ---------------------------------------------------------------------------

def test_json_output(
    http_client: httpx.Client,
    litellm_headers: dict,
    model_available: str,
) -> None:
    """T-061: Model returns valid JSON with the correct schema when instructed."""
    response_text = chat(
        http_client,
        litellm_headers,
        model_available,
        (
            'Return a JSON object with exactly one key "status" set to the string "ok". '
            "Return only the raw JSON object, no code fences, no explanation."
        ),
        max_tokens=30,
        temperature=0.0,
    )

    # Strip any markdown code fences the model might add despite instructions
    clean = re.sub(r"^```(?:json)?|```$", "", response_text.strip(), flags=re.MULTILINE).strip()

    try:
        parsed = json.loads(clean)
    except json.JSONDecodeError as exc:
        pytest.fail(
            f"Model response is not valid JSON.\n"
            f"Raw response: {response_text!r}\n"
            f"After stripping fences: {clean!r}\n"
            f"Error: {exc}"
        )

    assert parsed.get("status") == "ok", (
        f"Expected {{\"status\": \"ok\"}} but got: {parsed}"
    )
