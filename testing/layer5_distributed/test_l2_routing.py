# testing/layer5_distributed/test_l2_routing.py
#
# Layer 5 — L2 Routing + Coherence (T-510 through T-5xx)
#
# Verifies LiteLLM routes to the correct worker node by model-affinity alias,
# and that the model returns coherent output. Uses per-node alias routes
# registered by pull-models.sh (format: ollama/<model>@<alias>).
#
# Metrics captured per request: ttft_ms, total_ms, tokens_per_sec.
# Results written to testing/layer5_distributed/results/<timestamp>.json.
#
# Run: pytest testing/layer5_distributed/test_l2_routing.py -v
#
# Environment:
#   LITELLM_URL         — LiteLLM base URL (default: http://localhost:9000)
#   LITELLM_MASTER_KEY  — auth token (auto-read from Podman secret if unset)

import json
import time
from typing import Generator

import httpx
import pytest

from .conftest import (
    LITELLM_BASE_URL,
    MetricsRecorder,
    load_active_workers,
)

# ---------------------------------------------------------------------------
# Prompt cases — 4 fixed cases per node
# ---------------------------------------------------------------------------

_PROMPT_CASES = [
    {
        "case_id": "echo",
        "prompt": "Repeat the word 'apple' exactly once.",
        "assert_contains": ["apple"],
    },
    {
        "case_id": "arithmetic",
        "prompt": "What is 7 plus 8? Reply with the number only.",
        "assert_contains": ["15"],
    },
    {
        "case_id": "instruction_following",
        "prompt": "List exactly three colors. Use a numbered list.",
        "assert_contains": ["1", "2", "3"],
    },
    {
        "case_id": "single_turn_context",
        "prompt": "My name is Alex. What is my name?",
        "assert_contains": ["Alex"],
    },
]

# ---------------------------------------------------------------------------
# Build parametrize list at collection time
# ---------------------------------------------------------------------------

_workers = load_active_workers()

_routing_params = []
for _node in _workers:
    _alias = _node["alias"]
    _models = _node.get("models", [])
    if not _models:
        continue
    _model = _models[0]  # first declared model
    _route_id = f"ollama/{_model}@{_alias}"
    for _case in _PROMPT_CASES:
        _routing_params.append(
            pytest.param(
                _node, _route_id, _case,
                id=f"{_alias}::{_case['case_id']}",
            )
        )

if not _routing_params:
    _routing_params = [pytest.param({}, "", {}, id="no-workers")]


# ---------------------------------------------------------------------------
# T-510 — LiteLLM routes to correct node and returns coherent output
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("node,route_id,case", _routing_params)
def test_l2_routing_coherence(
    node: dict,
    route_id: str,
    case: dict,
    http_client: httpx.Client,
    litellm_headers: dict,
    metrics_recorder: MetricsRecorder,
) -> None:
    """T-510+: LiteLLM routes to alias target and model response is coherent."""
    if not node or not route_id or not case:
        pytest.skip("No active worker nodes configured")

    alias = node["alias"]
    case_id = case["case_id"]
    test_id = f"{alias}::{case_id}"

    payload = {
        "model": route_id,
        "messages": [{"role": "user", "content": case["prompt"]}],
        "max_tokens": 64,
        "stream": True,
    }

    ttft_ms: float | None = None
    total_ms: float = 0.0
    completion_text = ""
    completion_tokens = 0
    error_msg: str | None = None
    passed = False

    t_start = time.monotonic()

    try:
        with http_client.stream(
            "POST",
            "/chat/completions",
            json=payload,
            headers=litellm_headers,
            timeout=120.0,
        ) as response:
            if response.status_code != 200:
                body = response.read().decode(errors="replace")
                error_msg = f"HTTP {response.status_code}: {body[:300]}"
                raise AssertionError(error_msg)

            first_token = True
            for raw_line in response.iter_lines():
                if not raw_line or raw_line == "data: [DONE]":
                    continue
                if raw_line.startswith("data: "):
                    raw_line = raw_line[len("data: "):]
                try:
                    chunk = json.loads(raw_line)
                except json.JSONDecodeError:
                    continue

                delta = (
                    chunk.get("choices", [{}])[0]
                    .get("delta", {})
                    .get("content", "")
                )
                if delta:
                    if first_token:
                        ttft_ms = (time.monotonic() - t_start) * 1000
                        first_token = False
                    completion_text += delta
                    completion_tokens += 1

        total_ms = (time.monotonic() - t_start) * 1000
        tokens_per_sec = (
            (completion_tokens / (total_ms / 1000)) if total_ms > 0 else None
        )

        # Coherence assertion: each expected fragment must appear in the response
        lower_response = completion_text.lower()
        for fragment in case["assert_contains"]:
            assert fragment.lower() in lower_response, (
                f"[{alias}][{case_id}] Expected '{fragment}' in response.\n"
                f"  Route: {route_id}\n"
                f"  Prompt: {case['prompt']}\n"
                f"  Response: {completion_text[:400]}"
            )

        passed = True

    except AssertionError as exc:
        error_msg = str(exc)
        total_ms = (time.monotonic() - t_start) * 1000
        tokens_per_sec = None

    finally:
        metrics_recorder.record(
            test_id=test_id,
            node_alias=alias,
            model=route_id,
            ttft_ms=round(ttft_ms, 2) if ttft_ms is not None else None,
            total_ms=round(total_ms, 2),
            tokens_per_sec=round(tokens_per_sec, 2) if tokens_per_sec else None,
            passed=passed,
            error=error_msg,
        )

    if not passed:
        pytest.fail(error_msg or f"[{alias}][{case_id}] Test failed without recorded error")
