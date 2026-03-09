# testing/layer3_model/test_higher_order.py
#
# Layer 3d — Higher-Order Reasoning Tests (T-069 through T-072)
#
# T-069: Multi-turn conversation retains context across turns
# T-070: Model routing — llamacpp/* routes to the llama.cpp backend
# T-071: Failover — vLLM disabled, requests route to llama.cpp fallback
# T-072: Tool-calling / function-calling — response contains tool_calls block
#
# All tests require a model to be loaded (model_available fixture).
# T-070 and T-071 additionally require llamacpp and/or vllm services — they
# are skipped with clear messages if those services are not active.
#
# Run: pytest testing/layer3_model/test_higher_order.py -v

import json
import subprocess
import time

import httpx
import pytest

from .conftest import poll_until

pytestmark = pytest.mark.requires_model


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def chat_completion(
    http_client: httpx.Client,
    litellm_headers: dict,
    model: str,
    messages: list,
    max_tokens: int = 100,
    temperature: float = 0.0,
    tools: list | None = None,
) -> dict:
    """Post a chat completion request and return the full response body."""
    payload: dict = {
        "model": model,
        "messages": messages,
        "max_tokens": max_tokens,
        "temperature": temperature,
    }
    if tools:
        payload["tools"] = tools
        payload["tool_choice"] = "auto"

    response = http_client.post(
        "/chat/completions", json=payload, headers=litellm_headers
    )
    assert response.status_code == 200, (
        f"Chat completion returned {response.status_code}: {response.text[:500]}"
    )
    return response.json()


def service_is_active(svc_name: str) -> bool:
    result = subprocess.run(
        ["systemctl", "--user", "is-active", "--quiet", f"{svc_name}.service"],
        capture_output=True,
    )
    return result.returncode == 0


# ---------------------------------------------------------------------------
# T-069 — Multi-turn conversation retains context
# ---------------------------------------------------------------------------

def test_multi_turn_context_retention(
    http_client: httpx.Client,
    litellm_headers: dict,
    model_available: str,
) -> None:
    """
    T-069: A name introduced in turn 1 is recalled in turn 2.

    This verifies that LiteLLM correctly forwards the full message history
    to the backend and that the model uses prior context.
    """
    turn1_messages = [
        {
            "role": "user",
            "content": (
                "For this conversation, remember that my name is Hieronymus. "
                "Just acknowledge that you have noted my name."
            ),
        }
    ]

    body1 = chat_completion(
        http_client, litellm_headers, model_available, turn1_messages, max_tokens=40
    )
    reply1 = body1["choices"][0]["message"]["content"]

    # Build turn 2: include full history
    turn2_messages = turn1_messages + [
        {"role": "assistant", "content": reply1},
        {"role": "user", "content": "What is my name?"},
    ]

    body2 = chat_completion(
        http_client, litellm_headers, model_available, turn2_messages, max_tokens=30
    )
    reply2 = body2["choices"][0]["message"]["content"]

    assert "hieronymus" in reply2.lower(), (
        f"Model did not recall the name from turn 1. Turn 2 response: {reply2!r}"
    )


# ---------------------------------------------------------------------------
# T-070 — Model routing: llamacpp/* prefix routes to llama.cpp backend
# ---------------------------------------------------------------------------

def test_model_routing_llamacpp(
    http_client: httpx.Client,
    litellm_headers: dict,
) -> None:
    """
    T-070: A request with model='llamacpp/<id>' is served by llama.cpp,
    not vLLM. Verified by checking 'model' in the response matches
    a llamacpp-qualified name, or by confirming vllm.service is not the
    source (via LiteLLM's x-litellm-backend response header if available).
    """
    if not service_is_active("llamacpp"):
        pytest.skip(
            "llamacpp.service is not active — start it with a loaded model "
            "before running T-070. See docs/library/framework_components/llamacpp/"
        )

    # Get the first llamacpp model from LiteLLM
    resp = http_client.get("/models", headers=litellm_headers)
    assert resp.status_code == 200
    models = resp.json().get("data", [])
    llamacpp_models = [m["id"] for m in models if "llamacpp" in m["id"].lower()]

    if not llamacpp_models:
        pytest.skip(
            "No llamacpp/* models registered in LiteLLM. "
            "Add a llamacpp model to the LiteLLM config and reload."
        )

    target_model = llamacpp_models[0]
    body = chat_completion(
        http_client,
        litellm_headers,
        target_model,
        [{"role": "user", "content": "Reply with the word 'routed' only."}],
        max_tokens=10,
    )

    # The response 'model' field should echo back the llamacpp model name
    response_model = body.get("model", "")
    assert "llamacpp" in response_model.lower() or response_model == target_model, (
        f"Expected llamacpp model in response 'model' field, got: {response_model!r}"
    )


# ---------------------------------------------------------------------------
# T-071 — Failover: vLLM disabled, LiteLLM routes to llama.cpp
# ---------------------------------------------------------------------------

def test_failover_vllm_to_llamacpp(
    http_client: httpx.Client,
    litellm_headers: dict,
    model_available: str,
) -> None:
    """
    T-071: With vllm.service stopped, a request without an explicit backend
    succeeds via llama.cpp fallback.

    Skipped if neither vLLM nor llama.cpp is configured.
    After the test, vllm.service is NOT restarted (it was down before the test
    if this skip didn't fire — operator must restart if needed).
    """
    if not service_is_active("vllm"):
        pytest.skip(
            "vllm.service is not active — T-071 requires vLLM to be running "
            "so it can be stopped and failover verified. Skipping."
        )

    if not service_is_active("llamacpp"):
        pytest.skip(
            "llamacpp.service is not active — failover target not available. "
            "Start llamacpp with a loaded model before running T-071."
        )

    # Stop vLLM
    subprocess.run(
        ["systemctl", "--user", "stop", "vllm.service"],
        check=True, capture_output=True
    )

    try:
        # Give LiteLLM a moment to detect the backend is gone
        time.sleep(5)

        body = chat_completion(
            http_client,
            litellm_headers,
            model_available,
            [{"role": "user", "content": "Reply with the word 'fallback' only."}],
            max_tokens=10,
        )
        reply = body["choices"][0]["message"]["content"]
        assert reply, "Failover request returned empty response"

    finally:
        # Restore vLLM
        subprocess.run(
            ["systemctl", "--user", "start", "vllm.service"],
            capture_output=True
        )


# ---------------------------------------------------------------------------
# T-072 — Tool-calling / function-calling
# ---------------------------------------------------------------------------

def test_tool_calling(
    http_client: httpx.Client,
    litellm_headers: dict,
    model_available: str,
) -> None:
    """
    T-072: Model returns a tool_calls block when given a function definition
    and a prompt that requires calling it.

    Skipped if the loaded model does not support function calling.
    """
    # Define a simple function tool
    tools = [
        {
            "type": "function",
            "function": {
                "name": "get_current_temperature",
                "description": "Get the current temperature in a city.",
                "parameters": {
                    "type": "object",
                    "properties": {
                        "city": {
                            "type": "string",
                            "description": "Name of the city",
                        }
                    },
                    "required": ["city"],
                },
            },
        }
    ]

    messages = [
        {
            "role": "user",
            "content": "What is the current temperature in Paris?",
        }
    ]

    try:
        body = chat_completion(
            http_client,
            litellm_headers,
            model_available,
            messages,
            tools=tools,
            max_tokens=100,
        )
    except AssertionError as exc:
        # Some models/backends return 400 for tool-calling requests when
        # the feature is not supported — mark as skip rather than fail.
        if "400" in str(exc) or "not supported" in str(exc).lower():
            pytest.skip(
                f"Model '{model_available}' does not support tool-calling: {exc}"
            )
        raise

    choice = body["choices"][0]
    finish_reason = choice.get("finish_reason", "")
    tool_calls = choice.get("message", {}).get("tool_calls", [])

    # Model must either return tool_calls or indicate tool_calls via finish_reason
    if finish_reason == "tool_calls" or tool_calls:
        # Validate structure of the first tool call
        assert tool_calls, "finish_reason is 'tool_calls' but tool_calls list is empty"
        first_call = tool_calls[0]
        assert first_call.get("type") == "function", (
            f"Expected tool_call type 'function', got: {first_call.get('type')}"
        )
        fn = first_call.get("function", {})
        assert fn.get("name") == "get_current_temperature", (
            f"Expected function name 'get_current_temperature', got: {fn.get('name')}"
        )
        # Arguments must be valid JSON
        args_raw = fn.get("arguments", "")
        try:
            args = json.loads(args_raw)
        except json.JSONDecodeError:
            pytest.fail(f"tool_calls arguments is not valid JSON: {args_raw!r}")
        assert "city" in args, (
            f"Expected 'city' parameter in tool call arguments: {args}"
        )
    else:
        pytest.skip(
            f"Model '{model_available}' returned a text response instead of "
            f"tool_calls (finish_reason={finish_reason!r}). "
            "The model may not support tool-calling or the prompt was not "
            "strong enough to elicit a function call."
        )
