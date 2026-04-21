from __future__ import annotations

import importlib.util
import pathlib
import sys
import time

import httpx


def _load_client_module():
    project_root = pathlib.Path(__file__).resolve().parents[2]
    client_path = project_root / "services" / "m2m-gateway" / "client.py"
    module_name = "test_m2m_gateway_client_module"
    spec = importlib.util.spec_from_file_location(module_name, client_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def test_token_cache_reuse_and_forced_renew():
    module = _load_client_module()

    token_calls = {"count": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url).endswith("/oauth/token"):
            token_calls["count"] += 1
            token_value = f"token-{token_calls['count']}"
            return httpx.Response(200, json={"access_token": token_value, "expires_in": 120})
        if request.url.path == "/m2m/v1/jobs/start":
            return httpx.Response(200, json={"job_id": "job-1", "lease_expires_at": time.time() + 60})
        return httpx.Response(404)

    transport = httpx.MockTransport(handler)
    client = module.M2MGatewayClient(
        gateway_base_url="http://127.0.0.1:8787",
        token_url="http://auth.local/oauth/token",
        client_id="svc-a",
        client_secret="secret",
        transport=transport,
    )

    token_1 = client.get_access_token()
    token_2 = client.get_access_token()
    token_3 = client.get_access_token(force_renew=True)

    assert token_1 == "token-1"
    assert token_2 == "token-1"
    assert token_3 == "token-2"
    assert token_calls["count"] == 2


def test_extension_flow_with_approval_required_response():
    module = _load_client_module()

    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url).endswith("/oauth/token"):
            return httpx.Response(200, json={"access_token": "token-1", "expires_in": 120})
        if request.url.path == "/m2m/v1/jobs/job-1/extend":
            body = request.read().decode("utf-8")
            if "approval-1" in body:
                return httpx.Response(
                    200,
                    json={
                        "job_id": "job-1",
                        "approved": True,
                        "requires_human_approval": False,
                        "lease_expires_at": time.time() + 120,
                    },
                )
            return httpx.Response(
                200,
                json={
                    "job_id": "job-1",
                    "approved": False,
                    "requires_human_approval": True,
                    "lease_expires_at": time.time() + 60,
                },
            )
        return httpx.Response(404)

    client = module.M2MGatewayClient(
        gateway_base_url="http://127.0.0.1:8787",
        token_url="http://auth.local/oauth/token",
        client_id="svc-a",
        client_secret="secret",
        transport=httpx.MockTransport(handler),
    )

    first = client.request_extension("job-1", 120)
    second = client.request_extension("job-1", 120, approval_id="approval-1")

    assert first["requires_human_approval"] is True
    assert first["approved"] is False
    assert second["approved"] is True
    assert second["requires_human_approval"] is False


def test_heartbeat_loop_runs_configured_iterations(monkeypatch):
    module = _load_client_module()

    heartbeat_calls = {"count": 0}

    def handler(request: httpx.Request) -> httpx.Response:
        if str(request.url).endswith("/oauth/token"):
            return httpx.Response(200, json={"access_token": "token-1", "expires_in": 120})
        if request.url.path == "/m2m/v1/jobs/job-1/heartbeat":
            heartbeat_calls["count"] += 1
            return httpx.Response(200, json={"job_id": "job-1", "lease_expires_at": time.time() + 60})
        return httpx.Response(404)

    client = module.M2MGatewayClient(
        gateway_base_url="http://127.0.0.1:8787",
        token_url="http://auth.local/oauth/token",
        client_id="svc-a",
        client_secret="secret",
        transport=httpx.MockTransport(handler),
    )

    monkeypatch.setattr(module.time, "sleep", lambda _seconds: None)
    responses = client.run_heartbeat_loop("job-1", interval_seconds=1, max_iterations=3)

    assert heartbeat_calls["count"] == 3
    assert len(responses) == 3
