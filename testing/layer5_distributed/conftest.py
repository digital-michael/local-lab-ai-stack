# testing/layer5_distributed/conftest.py
#
# Shared fixtures for Layer 5 distributed tests.
#
# Node discovery: reads configs/nodes/*.json, filters status == "active".
# All tests use alias as the stable identity per D-026.
#
# Install dependencies:
#   pip install pytest httpx pytest-asyncio

import datetime
import glob
import json
import os
import subprocess

import httpx
import pytest

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

_THIS_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.dirname(os.path.dirname(_THIS_DIR))
NODES_DIR = os.path.join(PROJECT_ROOT, "configs", "nodes")
RESULTS_DIR = os.path.join(_THIS_DIR, "results")

LITELLM_BASE_URL = os.environ.get("LITELLM_URL", "http://localhost:9000")


# ---------------------------------------------------------------------------
# Node loading helpers
# ---------------------------------------------------------------------------

def load_active_nodes() -> list[dict]:
    """Return all node dicts where status == 'active', sorted by alias."""
    nodes = []
    for nf in sorted(glob.glob(os.path.join(NODES_DIR, "*.json"))):
        with open(nf) as f:
            n = json.load(f)
        if n.get("status") == "active":
            nodes.append(n)
    return nodes


def load_active_workers() -> list[dict]:
    """Return active nodes with profile != 'controller'."""
    return [n for n in load_active_nodes() if n.get("profile") != "controller"]


# ---------------------------------------------------------------------------
# Secret resolution
# ---------------------------------------------------------------------------

def _read_secret(name: str) -> str:
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
# Session fixtures
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def litellm_master_key() -> str:
    key = _read_secret("litellm_master_key")
    if not key:
        pytest.skip("litellm_master_key not available (env or Podman secret)")
    return key


@pytest.fixture(scope="session")
def litellm_headers(litellm_master_key: str) -> dict:
    return {"Authorization": f"Bearer {litellm_master_key}"}


@pytest.fixture(scope="session")
def http_client() -> httpx.Client:
    with httpx.Client(base_url=LITELLM_BASE_URL, timeout=120.0) as client:
        yield client


@pytest.fixture(scope="session")
def active_workers() -> list[dict]:
    workers = load_active_workers()
    if not workers:
        pytest.skip("No active worker nodes found in configs/nodes/")
    return workers


# ---------------------------------------------------------------------------
# Metrics recorder — collects per-request records, writes results on teardown
# ---------------------------------------------------------------------------

class MetricsRecorder:
    def __init__(self, suite: str):
        self.suite = suite
        self.run_id = datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%SZ")
        self.results: list[dict] = []

    def record(
        self,
        test_id: str,
        node_alias: str,
        model: str,
        ttft_ms: float | None,
        total_ms: float,
        tokens_per_sec: float | None,
        passed: bool,
        error: str | None = None,
    ) -> None:
        self.results.append({
            "test_id": test_id,
            "node_alias": node_alias,
            "model": model,
            "ttft_ms": ttft_ms,
            "total_ms": total_ms,
            "tokens_per_sec": tokens_per_sec,
            "passed": passed,
            "error": error,
        })

    def write(self) -> str:
        os.makedirs(RESULTS_DIR, exist_ok=True)
        path = os.path.join(RESULTS_DIR, f"{self.run_id}.json")
        payload = {
            "run_id": self.run_id,
            "suite": self.suite,
            "results": self.results,
        }
        with open(path, "w") as f:
            json.dump(payload, f, indent=2)
        return path


@pytest.fixture(scope="session")
def metrics_recorder(request) -> MetricsRecorder:
    recorder = MetricsRecorder(suite="L2")
    yield recorder
    path = recorder.write()
    print(f"\nL2 metrics written to: {path}")
