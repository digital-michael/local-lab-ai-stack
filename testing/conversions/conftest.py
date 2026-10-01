# testing/conversions/conftest.py
#
# Shared fixtures for the conversions service test modules.
#
# Install dependencies:
#   pip install pytest httpx

from __future__ import annotations

import os
import subprocess

import httpx
import pytest

CONVERSIONS_BASE_URL = os.environ.get("CONVERSIONS_URL", "http://localhost:8300")


def _read_secret(name: str) -> str:
    """Return a secret value: env var (uppercased name) first, else the
    Podman secret mounted into a throwaway alpine container. Mirrors
    testing/layer3_model/conftest.py's _read_secret."""
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


@pytest.fixture(scope="session")
def conversions_api_key() -> str:
    return _read_secret("conversions_api_key")


@pytest.fixture(scope="session")
def conversions_headers(conversions_api_key: str) -> dict:
    headers: dict[str, str] = {}
    if conversions_api_key:
        headers["Authorization"] = f"Bearer {conversions_api_key}"
    return headers


@pytest.fixture(scope="session")
def conversions_client() -> httpx.Client:
    with httpx.Client(base_url=CONVERSIONS_BASE_URL, timeout=60.0) as client:
        yield client


@pytest.fixture(scope="session")
def conversions_available(conversions_client: httpx.Client) -> None:
    """Session fixture that skips the whole module if the conversions
    service isn't reachable — same shape as layer3_model's model_available
    skip-gate, applied to a plain service-liveness check."""
    try:
        resp = conversions_client.get("/health")
    except Exception as exc:
        pytest.skip(f"conversions service not reachable at {CONVERSIONS_BASE_URL}: {exc}")
    if resp.status_code != 200:
        pytest.skip(f"conversions service /health returned {resp.status_code}")
