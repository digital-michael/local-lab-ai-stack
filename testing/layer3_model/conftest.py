# testing/layer3_model/conftest.py
#
# Shared fixtures for all Layer 3 pytest test modules.
#
# Install dependencies:
#   pip install pytest httpx pytest-asyncio

import json
import os
import subprocess
import time

import httpx
import pytest

# ---------------------------------------------------------------------------
# Paths and base URLs
# ---------------------------------------------------------------------------

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(_THIS_DIR))
CONFIG_FILE = os.path.join(PROJECT_ROOT, "configs", "config.json")
MODELS_FILE = os.path.join(PROJECT_ROOT, "configs", "models.json")
AI_STACK_DIR = os.environ.get("AI_STACK_DIR", os.path.expanduser("~/ai-stack"))

LITELLM_BASE_URL = "http://localhost:9000"
QDRANT_BASE_URL = "http://localhost:6333"
KNOWLEDGE_INDEX_URL = os.environ.get(
    "KNOWLEDGE_INDEX_URL", "http://localhost:8100"
)


# ---------------------------------------------------------------------------
# Secret resolution
# ---------------------------------------------------------------------------

def _read_secret(name: str) -> str:
    """
    Return a secret value.
    Checks an environment variable (uppercased name) first, then mounts the
    Podman secret into a temporary alpine container to read it.
    Returns empty string if neither source is available.
    """
    env_val = os.environ.get(name.upper(), "")
    if env_val:
        return env_val

    result = subprocess.run(
        [
            "podman", "run", "--rm",
            "--secret", name,
            "docker.io/library/alpine:latest",
            "sh", "-c", f"cat /run/secrets/{name}",
        ],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip() if result.returncode == 0 else ""


# ---------------------------------------------------------------------------
# Session-scoped fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def litellm_master_key() -> str:
    """Resolve LiteLLM master key from env or Podman secret."""
    key = _read_secret("litellm_master_key")
    if not key:
        pytest.skip(
            "litellm_master_key not available — "
            "set LITELLM_MASTER_KEY env var or provision the Podman secret"
        )
    return key


@pytest.fixture(scope="session")
def litellm_headers(litellm_master_key: str) -> dict:
    """Authorization and content-type headers for LiteLLM requests."""
    return {
        "Authorization": f"Bearer {litellm_master_key}",
        "Content-Type": "application/json",
    }


@pytest.fixture(scope="session")
def http_client() -> httpx.Client:
    """
    Synchronous httpx client pointed at LiteLLM.
    Generous timeout for model inference calls (up to 120s).
    """
    with httpx.Client(base_url=LITELLM_BASE_URL, timeout=120.0) as client:
        yield client


@pytest.fixture(scope="session")
def qdrant_api_key() -> str:
    """Resolve Qdrant API key (may be empty if Qdrant runs without auth)."""
    return _read_secret("qdrant_api_key")


@pytest.fixture(scope="session")
def qdrant_headers(qdrant_api_key: str) -> dict:
    headers = {"Content-Type": "application/json"}
    if qdrant_api_key:
        headers["api-key"] = qdrant_api_key
    return headers


@pytest.fixture(scope="session")
def ki_api_key() -> str:
    """Resolve knowledge-index API key from env (KI_API_KEY) or Podman secret."""
    return _read_secret("knowledge_index_api_key")


@pytest.fixture(scope="session")
def ki_headers(ki_api_key: str) -> dict:
    """Auth + content-type headers for knowledge-index requests."""
    h = {"Content-Type": "application/json"}
    if ki_api_key:
        h["Authorization"] = f"Bearer {ki_api_key}"
    return h


@pytest.fixture(scope="session")
def ki_client() -> httpx.Client:
    """HTTP client pointed at knowledge-index."""
    with httpx.Client(base_url=KNOWLEDGE_INDEX_URL, timeout=60.0) as client:
        yield client


@pytest.fixture(scope="session")
def default_test_model() -> str:
    """
    Determine the model identifier to use for reasoning tests.

    Resolution order:
    1. TEST_MODEL environment variable
    2. First entry in configs/models.json default_models list
    3. Hard-coded fallback: llamacpp/phi-3-mini-4k-instruct-q4
    """
    model = os.environ.get("TEST_MODEL", "")
    if model:
        return model

    if os.path.exists(MODELS_FILE):
        with open(MODELS_FILE) as f:
            data = json.load(f)
        models = data.get("default_models", [])
        if models:
            return models[0]["id"]

    # Fallback — will be skipped by model_available if not loaded
    return "llama3.1-8b"


@pytest.fixture(scope="session")
def model_available(
    http_client: httpx.Client,
    litellm_headers: dict,
    default_test_model: str,
) -> str:
    """
    Session fixture that skips the entire test module if no model is loaded
    in LiteLLM, or if the specified test model is not in the model list.

    Returns the model ID string so tests can use it directly::

        def test_something(model_available):
            model_id = model_available
    """
    try:
        response = http_client.get("/models", headers=litellm_headers)
        response.raise_for_status()
        models = response.json().get("data", [])
    except Exception as exc:
        pytest.skip(f"LiteLLM /models not reachable: {exc}")

    if not models:
        pytest.skip(
            "No models loaded in LiteLLM — run T-056 (pull_default_models) first"
        )

    loaded_ids = [m["id"] for m in models]
    if default_test_model not in loaded_ids:
        pytest.skip(
            f"Test model '{default_test_model}' not available. "
            f"Loaded: {loaded_ids}. "
            f"Set TEST_MODEL to one of the loaded model IDs."
        )

    # Warmup ping — verify the backend actually responds to inference.
    # If the underlying provider (e.g. llamacpp) is not yet running, skip
    # rather than fail so that inference tests don't generate spurious failures.
    try:
        warmup_resp = http_client.post(
            "/chat/completions",
            json={
                "model": default_test_model,
                "messages": [{"role": "user", "content": "hi"}],
                "max_tokens": 1,
            },
            headers=litellm_headers,
        )
        if warmup_resp.status_code != 200:
            pytest.skip(
                f"Model '{default_test_model}' is registered but its backend is not "
                f"responding (HTTP {warmup_resp.status_code}). "
                f"Start the inference service (e.g. ollama) then re-run."
            )
    except Exception as exc:
        pytest.skip(
            f"Model '{default_test_model}' warmup inference failed: {exc}. "
            f"Start the inference service (e.g. ollama) then re-run."
        )

    return default_test_model


# ---------------------------------------------------------------------------
# Helper: poll a condition with timeout and interval
# ---------------------------------------------------------------------------

def poll_until(condition_fn, timeout_s: int = 60, interval_s: int = 5) -> bool:
    """
    Call condition_fn() repeatedly until it returns truthy or timeout_s elapses.
    Returns True if condition was met, False if timed out.
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        try:
            if condition_fn():
                return True
        except Exception:
            pass
        time.sleep(interval_s)
    return False
