# testing/layer5_distributed/test_l1_liveness.py
#
# Layer 5 — L1 Liveness (T-500 through T-5xx)
#
# Verifies each active worker node's Ollama endpoint is reachable and
# responding. Probes directly to http://<node.address>:11434/api/tags —
# no LiteLLM involvement.
#
# Pass/fail: binary. A failing node is hard-failed, not soft-failed.
# Intended to run after every deploy and before L2 routing tests.
#
# Run: pytest testing/layer5_distributed/test_l1_liveness.py -v
#
# Environment:
#   LITELLM_URL   — unused by L1; overridden in conftest if needed
#   OLLAMA_PORT   — override if Ollama runs on a non-default port (default: 11434)

import os

import httpx
import pytest

import model_choices

from .conftest import load_active_workers

OLLAMA_PORT = int(os.environ.get("OLLAMA_PORT", "11434"))

# ---------------------------------------------------------------------------
# Build parametrize list at collection time — one test ID per active node
# ---------------------------------------------------------------------------

_workers = load_active_workers()
_worker_params = [
    pytest.param(node, id=node["alias"])
    for node in _workers
]

if not _worker_params:
    # If no workers yet, define a single placeholder that skips
    _worker_params = [pytest.param({}, id="no-workers")]


# ---------------------------------------------------------------------------
# T-500 — Ollama /api/tags reachable on each active worker
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("node", _worker_params)
def test_ollama_liveness(node: dict) -> None:
    """T-500+: Ollama /api/tags responds 200 on each active worker node."""
    if not node:
        pytest.skip("No active worker nodes configured")

    alias = node["alias"]
    address = node.get("address") or node.get("address_fallback", "")
    if not address:
        pytest.fail(f"Node '{alias}' has no address or address_fallback set")

    url = f"http://{address}:{OLLAMA_PORT}/api/tags"

    try:
        with httpx.Client(timeout=15.0) as client:
            response = client.get(url)
    except httpx.ConnectError as exc:
        pytest.fail(
            f"[{alias}] Cannot connect to Ollama at {url}: {exc}\n"
            f"  Confirm Ollama is running on {address} and port {OLLAMA_PORT} is reachable."
        )
    except httpx.TimeoutException as exc:
        pytest.fail(f"[{alias}] Timeout connecting to Ollama at {url}: {exc}")

    assert response.status_code == 200, (
        f"[{alias}] Ollama /api/tags returned HTTP {response.status_code} "
        f"(expected 200). URL: {url}. Body: {response.text[:300]}"
    )

    body = response.json()
    assert "models" in body, (
        f"[{alias}] Ollama /api/tags response missing 'models' key. Body: {body}"
    )


# ---------------------------------------------------------------------------
# T-501 — Models declared for the node in testing/models.json are present
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("node", _worker_params)
def test_ollama_declared_models_present(node: dict) -> None:
    """T-501+: Each model testing/models.json declares for the node appears in Ollama's model list."""
    if not node:
        pytest.skip("No active worker nodes configured")

    alias = node["alias"]
    address = node.get("address") or node.get("address_fallback", "")
    declared_models = model_choices.worker_models(alias)

    if not declared_models:
        pytest.fail(
            f"Worker '{alias}' has no models in testing/models.json \"workers\" -- "
            f"declare what it serves (from scripts/model-inventory.sh on the controller)"
        )

    if not address:
        pytest.fail(f"Node '{alias}' has no address set")

    url = f"http://{address}:{OLLAMA_PORT}/api/tags"
    with httpx.Client(timeout=15.0) as client:
        response = client.get(url)

    assert response.status_code == 200, (
        f"[{alias}] /api/tags returned {response.status_code}"
    )

    available = {m["name"] for m in response.json().get("models", [])}
    missing = [m for m in declared_models if m not in available]

    assert not missing, (
        f"[{alias}] Declared model(s) not found in Ollama: {missing}\n"
        f"  Available: {sorted(available)}\n"
        f"  Run: ollama pull <model> on {address}"
    )
