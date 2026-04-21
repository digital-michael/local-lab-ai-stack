from __future__ import annotations

import importlib.util
import json
import os
import sys
import time
from pathlib import Path

import jwt
import pytest
from fastapi.testclient import TestClient


REPO_ROOT = Path(__file__).resolve().parents[2]
APP_PATH = REPO_ROOT / "services" / "m2m-gateway" / "app.py"
CONTAINERFILE_PATH = REPO_ROOT / "services" / "m2m-gateway" / "Containerfile"
TEST_SECRET = "test-m2m-secret"


def _load_gateway_module(module_name: str):
    spec = importlib.util.spec_from_file_location(module_name, APP_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Unable to load module from {APP_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def _token(*, sub: str, wf: str, aud: str = "local-m2m-gateway", scopes: list[str] | str = "") -> str:
    claims = {
        "sub": sub,
        "wf": wf,
        "aud": aud,
    }
    if isinstance(scopes, list):
        claims["scope"] = scopes
    else:
        claims["scope"] = scopes
    return jwt.encode(claims, TEST_SECRET, algorithm="HS256")


@pytest.fixture()
def gateway(monkeypatch):
    monkeypatch.setenv("M2M_JWT_SECRET", TEST_SECRET)
    monkeypatch.setenv("M2M_JWT_ALGORITHM", "HS256")
    monkeypatch.setenv("M2M_JWT_AUDIENCE", "local-m2m-gateway")
    monkeypatch.setenv("M2M_JWT_ISSUER", "")
    monkeypatch.setenv("M2M_JWKS_URL", "")
    monkeypatch.setenv("M2M_DEFAULT_ALLOW_DYNAMIC_SOURCES", "false")
    monkeypatch.setenv("M2M_TRUSTED_INTEROP_ENABLED", "false")
    monkeypatch.setenv("M2M_TRUSTED_ALLOW_PROJECT_PAIRS", "proj-a:proj-b")
    monkeypatch.setenv("M2M_LEASE_DEFAULT_MINUTES", "30")
    monkeypatch.setenv("M2M_LEASE_AUTO_EXTEND_MAX_HOURS", "1")
    monkeypatch.setenv("M2M_LEASE_APPROVAL_MAX_HOURS", "12")
    monkeypatch.setenv("M2M_BREAK_GLASS_ALLOWED_SCOPES", "m2m.jobs.extend.high")
    monkeypatch.setenv("M2M_BREAK_GLASS_EXTENSION_SCOPE", "m2m.jobs.extend.high")
    monkeypatch.setenv("M2M_AUDIT_RETENTION_SOURCE", "prometheus_default")
    monkeypatch.setenv("M2M_PROMETHEUS_RETENTION_DAYS", "15")
    monkeypatch.setenv("M2M_AUDIT_RETENTION_DAYS_OVERRIDE", "")

    workflow_policy = {
        "workflows": {
            "wf-alpha": {
                "allowed_sources": ["ki", "minio"],
                "allowed_models": ["gpt-4o"],
                "allowed_tools": ["summarize"],
                "allowed_publication_adapters": ["scorm"],
            }
        }
    }
    monkeypatch.setenv("M2M_WORKFLOW_POLICY_JSON", json.dumps(workflow_policy))
    monkeypatch.setenv(
        "M2M_PUBLICATION_ADAPTERS_JSON",
        json.dumps({"scorm": {"version": "1.2", "target_format": "scorm-2004"}}),
    )

    module = _load_gateway_module("m2m_gateway_test_module")
    module._jobs.clear()
    module._approvals.clear()
    module._audit_events.clear()

    with TestClient(module.app) as client:
        yield module, client


def test_unauthenticated_requests_fail_closed(gateway):
    _, client = gateway
    response = client.post("/m2m/v1/jobs/start", json={"workflow_id": "wf-alpha", "project_id": "proj-a"})
    assert response.status_code == 401


def test_wrong_audience_token_is_rejected(gateway):
    _, client = gateway
    token = _token(sub="svc-a", wf="wf-alpha", aud="wrong-aud", scopes="m2m.jobs.start")
    response = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert response.status_code == 401


def test_cross_workflow_access_is_denied(gateway):
    _, client = gateway
    token_alpha = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.jobs.heartbeat"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token_alpha}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    token_beta = _token(sub="svc-a", wf="wf-beta", scopes="m2m.jobs.heartbeat")
    heartbeat = client.post(
        f"/m2m/v1/jobs/{job_id}/heartbeat",
        headers={"Authorization": f"Bearer {token_beta}"},
    )
    assert heartbeat.status_code == 403
    detail = heartbeat.json().get("detail", {})
    assert detail.get("code") == "cross_workflow_job_access"
    assert "trace_id" in detail


def test_trusted_interop_disabled_blocks_cross_platform_attach(gateway):
    _, client = gateway
    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.context.attach"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    attach = client.post(
        "/m2m/v1/context/attach",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "job_id": job_id,
            "source_type": "ki",
            "source_id": "doc-1",
            "cross_platform": True,
            "target_project_id": "proj-b",
            "metadata": {"query": "hello", "collection": "default", "top_k": 1},
        },
    )
    assert attach.status_code == 403
    detail = attach.json().get("detail", {})
    assert detail.get("code") == "trusted_interop_disabled"


def test_extension_over_auto_cap_requires_valid_approval(gateway):
    _, client = gateway
    token = _token(
        sub="svc-a",
        wf="wf-alpha",
        scopes=["m2m.jobs.start", "m2m.jobs.extend", "m2m.approval.request", "m2m.approval.decision"],
    )

    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    ext_needs_approval = client.post(
        f"/m2m/v1/jobs/{job_id}/extend",
        headers={"Authorization": f"Bearer {token}"},
        json={"requested_minutes": 120},
    )
    assert ext_needs_approval.status_code == 200
    assert ext_needs_approval.json()["requires_human_approval"] is True

    approval_req = client.post(
        "/m2m/v1/approval/request",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "job_id": job_id,
            "reason_code": "mvp-test",
            "requested_scopes": ["m2m.jobs.extend.high"],
            "ttl_minutes": 10,
        },
    )
    assert approval_req.status_code == 200
    approval_id = approval_req.json()["approval_id"]

    decision = client.post(
        f"/m2m/v1/approval/{approval_id}/decision",
        headers={"Authorization": f"Bearer {token}"},
        json={"approved": True, "approver_id": "admin-1"},
    )
    assert decision.status_code == 200

    ext_with_approval = client.post(
        f"/m2m/v1/jobs/{job_id}/extend",
        headers={"Authorization": f"Bearer {token}"},
        json={"requested_minutes": 120, "approval_id": approval_id},
    )
    assert ext_with_approval.status_code == 200
    assert ext_with_approval.json()["approved"] is True
    assert ext_with_approval.json()["requires_human_approval"] is False

    audit = client.get("/m2m/v1/audit/events?limit=50")
    assert audit.status_code == 200
    assert audit.json()["retention_source"] == "prometheus_default"


def test_disallowed_context_source_is_denied(gateway):
    _, client = gateway
    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.context.attach"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    attach = client.post(
        "/m2m/v1/context/attach",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "job_id": job_id,
            "source_type": "openwebui",
            "source_id": "private-asset",
            "cross_platform": False,
        },
    )
    assert attach.status_code == 403
    detail = attach.json().get("detail", {})
    assert detail.get("code") == "source_not_allowed_for_workflow"


def test_disallowed_model_is_denied(gateway):
    _, client = gateway
    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.infer"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    infer = client.post(
        "/m2m/v1/infer",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "job_id": job_id,
            "payload": {
                "model": "forbidden-model",
                "messages": [{"role": "user", "content": "hi"}],
            },
        },
    )
    assert infer.status_code == 403
    detail = infer.json().get("detail", {})
    assert detail.get("code") == "model_not_allowed"


def test_named_service_namespace_is_preserved(gateway):
    _, client = gateway
    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.context.attach"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    attach = client.post(
        "/m2m/v1/context/attach",
        headers={"Authorization": f"Bearer {token}"},
        json={"job_id": job_id, "source_type": "ki", "source_id": "asset-1", "metadata": {"resolve": False}},
    )
    assert attach.status_code == 200
    assert attach.json()["namespace"] == "svc:svc-a/project:proj-a"


def test_long_running_job_survives_with_heartbeat(gateway):
    module, client = gateway
    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.jobs.heartbeat"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    now = time.time()
    module._jobs[job_id].last_heartbeat_at = now - (module.HEARTBEAT_INTERVAL_SECONDS - 1)
    module._jobs[job_id].lease_expires_at = now + 30

    hb = client.post(
        f"/m2m/v1/jobs/{job_id}/heartbeat",
        headers={"Authorization": f"Bearer {token}"},
    )
    assert hb.status_code == 200
    assert hb.json()["job_id"] == job_id


def test_job_is_reaped_after_heartbeat_stops(gateway):
    module, client = gateway
    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.context.attach"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    now = time.time()
    stale_after = module.HEARTBEAT_INTERVAL_SECONDS * module.HEARTBEAT_MISS_GRACE
    module._jobs[job_id].last_heartbeat_at = now - stale_after - 1
    module._jobs[job_id].lease_expires_at = now + stale_after

    attach = client.post(
        "/m2m/v1/context/attach",
        headers={"Authorization": f"Bearer {token}"},
        json={"job_id": job_id, "source_type": "ki", "source_id": "asset-1", "metadata": {"resolve": False}},
    )
    assert attach.status_code == 404
    assert attach.json()["detail"] == "Job not found"


def test_break_glass_reason_logged_and_auto_expires(gateway):
    module, client = gateway
    token = _token(
        sub="svc-a",
        wf="wf-alpha",
        scopes=["m2m.jobs.start", "m2m.jobs.extend", "m2m.approval.request", "m2m.approval.decision"],
    )
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    approval_req = client.post(
        "/m2m/v1/approval/request",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "job_id": job_id,
            "reason_code": "ops-emergency",
            "requested_scopes": ["m2m.jobs.extend.high"],
            "ttl_minutes": 5,
        },
    )
    assert approval_req.status_code == 200
    approval_id = approval_req.json()["approval_id"]

    audit = client.get("/m2m/v1/audit/events?limit=100")
    assert audit.status_code == 200
    events = audit.json()["events"]
    assert any(e.get("event") == "approval_request" and e.get("reason_code") == "ops-emergency" for e in events)

    decision = client.post(
        f"/m2m/v1/approval/{approval_id}/decision",
        headers={"Authorization": f"Bearer {token}"},
        json={"approved": True, "approver_id": "admin-1"},
    )
    assert decision.status_code == 200

    module._approvals[approval_id].expires_at = time.time() - 1
    extend = client.post(
        f"/m2m/v1/jobs/{job_id}/extend",
        headers={"Authorization": f"Bearer {token}"},
        json={"requested_minutes": 120, "approval_id": approval_id},
    )
    assert extend.status_code == 403
    detail = extend.json().get("detail", {})
    assert detail.get("code") == "approval_invalid_or_expired"


def test_bind_is_localhost_only_in_containerfile():
    content = CONTAINERFILE_PATH.read_text(encoding="utf-8")
    assert "--host", "127.0.0.1" in ("--host", "127.0.0.1")
    assert "--host\", \"127.0.0.1\"" in content


def test_approval_expiry_cannot_be_reused(gateway):
    module, client = gateway
    token = _token(
        sub="svc-a",
        wf="wf-alpha",
        scopes=["m2m.jobs.start", "m2m.jobs.extend", "m2m.approval.request", "m2m.approval.decision"],
    )
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    approval_req = client.post(
        "/m2m/v1/approval/request",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "job_id": job_id,
            "reason_code": "expire-test",
            "requested_scopes": ["m2m.jobs.extend.high"],
            "ttl_minutes": 1,
        },
    )
    assert approval_req.status_code == 200
    approval_id = approval_req.json()["approval_id"]

    decision = client.post(
        f"/m2m/v1/approval/{approval_id}/decision",
        headers={"Authorization": f"Bearer {token}"},
        json={"approved": True, "approver_id": "admin-1"},
    )
    assert decision.status_code == 200

    module._approvals[approval_id].expires_at = time.time() - 1
    extend = client.post(
        f"/m2m/v1/jobs/{job_id}/extend",
        headers={"Authorization": f"Bearer {token}"},
        json={"requested_minutes": 120, "approval_id": approval_id},
    )
    assert extend.status_code == 403
    detail = extend.json().get("detail", {})
    assert detail.get("code") == "approval_invalid_or_expired"


def test_default_allow_off_denies_dynamic_sources(gateway):
    _, client = gateway
    token = _token(sub="svc-a", wf="wf-dynamic", scopes=["m2m.jobs.start", "m2m.context.attach"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-dynamic", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    attach = client.post(
        "/m2m/v1/context/attach",
        headers={"Authorization": f"Bearer {token}"},
        json={"job_id": job_id, "source_type": "openwebui", "source_id": "ctx-1"},
    )
    assert attach.status_code == 403
    detail = attach.json().get("detail", {})
    assert detail.get("code") == "dynamic_sources_default_deny"


def test_trusted_interop_enabled_allows_approved_pair(gateway):
    module, client = gateway
    module.TRUSTED_INTEROP_ENABLED = True

    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.context.attach"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    attach = client.post(
        "/m2m/v1/context/attach",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "job_id": job_id,
            "source_type": "ki",
            "source_id": "asset-1",
            "cross_platform": True,
            "target_project_id": "proj-b",
            "metadata": {"resolve": False},
        },
    )
    assert attach.status_code == 200
    assert attach.json()["attached"] is True


def test_project_bound_sources_denied_for_cross_platform(gateway):
    module, client = gateway
    module.TRUSTED_INTEROP_ENABLED = True

    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.context.attach"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    attach = client.post(
        "/m2m/v1/context/attach",
        headers={"Authorization": f"Bearer {token}"},
        json={
            "job_id": job_id,
            "source_type": "minio",
            "source_id": "private-lesson-1",
            "cross_platform": True,
            "target_project_id": "proj-b",
        },
    )
    assert attach.status_code == 403
    detail = attach.json().get("detail", {})
    assert detail.get("code") == "project_bound_context_not_shareable"


def test_publication_adapter_transform_contract(gateway):
    _, client = gateway
    token = _token(sub="svc-a", wf="wf-alpha", scopes=["m2m.jobs.start", "m2m.publish.transform"])
    start = client.post(
        "/m2m/v1/jobs/start",
        headers={"Authorization": f"Bearer {token}"},
        json={"workflow_id": "wf-alpha", "project_id": "proj-a"},
    )
    assert start.status_code == 200
    job_id = start.json()["job_id"]

    transform = client.post(
        "/m2m/v1/publish/transform",
        headers={"Authorization": f"Bearer {token}"},
        json={"job_id": job_id, "adapter": "scorm", "payload": {"title": "lesson"}},
    )
    assert transform.status_code == 200
    body = transform.json()
    assert body["contract"]["ki_core_unchanged"] is True
    assert body["contract"]["adapter_transform_only"] is True
