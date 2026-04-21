from __future__ import annotations

import json
import logging
import os
import time
import uuid
from dataclasses import dataclass
from threading import Lock
from typing import Any

import httpx
import jwt
from jwt import PyJWKClient
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field


APP_NAME = "m2m-gateway"
JWT_AUDIENCE = os.environ.get("M2M_JWT_AUDIENCE", "local-m2m-gateway")
JWT_ALGORITHM = os.environ.get("M2M_JWT_ALGORITHM", "HS256")
JWT_SECRET = os.environ.get("M2M_JWT_SECRET", "")
JWT_ISSUER = os.environ.get("M2M_JWT_ISSUER", "")
JWKS_URL = os.environ.get("M2M_JWKS_URL", "")
TRUSTED_INTEROP_ENABLED = os.environ.get("M2M_TRUSTED_INTEROP_ENABLED", "false").lower() == "true"
TRUSTED_ALLOW_PROJECT_PAIRS = os.environ.get("M2M_TRUSTED_ALLOW_PROJECT_PAIRS", "")
TRUSTED_TEMPLATE_SET_JSON = os.environ.get("M2M_TRUSTED_TEMPLATE_SET_JSON", "{}")
TRUSTED_SCOPE_TEMPLATE_MAP_JSON = os.environ.get("M2M_TRUSTED_SCOPE_TEMPLATE_MAP_JSON", "{}")
WORKFLOW_POLICY_JSON = os.environ.get("M2M_WORKFLOW_POLICY_JSON", "{}")
DEFAULT_ALLOW_DYNAMIC_SOURCES = os.environ.get("M2M_DEFAULT_ALLOW_DYNAMIC_SOURCES", "false").lower() == "true"
LITELLM_BASE_URL = os.environ.get("M2M_LITELLM_BASE_URL", "http://litellm.ai-stack:4000")
LITELLM_API_KEY = os.environ.get("M2M_LITELLM_API_KEY", "")
KI_BASE_URL = os.environ.get("M2M_KI_BASE_URL", "http://knowledge-index.ai-stack:8100")
KI_API_KEY = os.environ.get("M2M_KI_API_KEY", "")
SKILL_RUNNER_URL = os.environ.get("M2M_SKILL_RUNNER_URL", "")
REQUEST_TIMEOUT_SECONDS = float(os.environ.get("M2M_REQUEST_TIMEOUT_SECONDS", "20"))
BREAK_GLASS_ALLOWED_SCOPES = {
    s.strip() for s in os.environ.get("M2M_BREAK_GLASS_ALLOWED_SCOPES", "m2m.jobs.extend.high").split(",") if s.strip()
}
BREAK_GLASS_EXTENSION_SCOPE = os.environ.get("M2M_BREAK_GLASS_EXTENSION_SCOPE", "m2m.jobs.extend.high")
PUBLICATION_ADAPTERS_JSON = os.environ.get("M2M_PUBLICATION_ADAPTERS_JSON", "{}")
AUDIT_RETENTION_SOURCE = os.environ.get("M2M_AUDIT_RETENTION_SOURCE", "prometheus_default")
PROMETHEUS_RETENTION_DAYS = int(os.environ.get("M2M_PROMETHEUS_RETENTION_DAYS", "15"))
AUDIT_RETENTION_DAYS_OVERRIDE = os.environ.get("M2M_AUDIT_RETENTION_DAYS_OVERRIDE", "").strip()

LEASE_DEFAULT_MINUTES = int(os.environ.get("M2M_LEASE_DEFAULT_MINUTES", "30"))
LEASE_AUTO_EXTEND_MAX_HOURS = int(os.environ.get("M2M_LEASE_AUTO_EXTEND_MAX_HOURS", "24"))
LEASE_APPROVAL_MAX_HOURS = int(os.environ.get("M2M_LEASE_APPROVAL_MAX_HOURS", "168"))
HEARTBEAT_INTERVAL_SECONDS = int(os.environ.get("M2M_HEARTBEAT_INTERVAL_SECONDS", "60"))
HEARTBEAT_MISS_GRACE = int(os.environ.get("M2M_HEARTBEAT_MISS_GRACE", "3"))

_jwks_client = PyJWKClient(JWKS_URL) if JWKS_URL else None
_logger = logging.getLogger(APP_NAME)
if not _logger.handlers:
    logging.basicConfig(level=logging.INFO)


app = FastAPI(title=APP_NAME, version="0.1.0")


@dataclass
class JobState:
    job_id: str
    service_id: str
    workflow_id: str
    project_id: str
    policy_class: str
    lease_started_at: float
    lease_expires_at: float
    last_heartbeat_at: float
    total_runtime_cap_seconds: int
    extension_seconds_granted: int


@dataclass
class ApprovalState:
    approval_id: str
    job_id: str
    requested_by: str
    requested_scopes: list[str]
    reason_code: str
    status: str
    requested_at: float
    expires_at: float
    decided_at: float | None = None
    approver_id: str | None = None


_jobs: dict[str, JobState] = {}
_jobs_lock = Lock()
_approvals: dict[str, ApprovalState] = {}
_approvals_lock = Lock()
_audit_events: list[dict[str, Any]] = []
_audit_lock = Lock()
_metrics: dict[str, int] = {
    "denied_by_policy_total": 0,
    "lease_expired_total": 0,
    "approval_required_total": 0,
    "approval_denied_total": 0,
    "stale_jobs_reaped_total": 0,
    "heartbeat_miss_total": 0,
    "audit_events_pruned_total": 0,
}
_metrics_lock = Lock()


def _audit_retention_days() -> int:
    if AUDIT_RETENTION_DAYS_OVERRIDE:
        try:
            return max(1, int(AUDIT_RETENTION_DAYS_OVERRIDE))
        except ValueError:
            return max(1, PROMETHEUS_RETENTION_DAYS)
    if AUDIT_RETENTION_SOURCE == "prometheus_default":
        return max(1, PROMETHEUS_RETENTION_DAYS)
    return max(1, PROMETHEUS_RETENTION_DAYS)


def _audit_retention_seconds() -> int:
    return _audit_retention_days() * 24 * 60 * 60


class AuthContext(BaseModel):
    service_id: str
    workflow_id: str
    scopes: list[str]
    token_id: str | None = None


class JobStartRequest(BaseModel):
    workflow_id: str = Field(min_length=1)
    project_id: str = Field(min_length=1)
    policy_class: str = Field(default="strict")


class JobStartResponse(BaseModel):
    job_id: str
    lease_expires_at: float
    heartbeat_interval_seconds: int


class JobHeartbeatResponse(BaseModel):
    job_id: str
    lease_expires_at: float
    stale_after_seconds: int


class JobExtendRequest(BaseModel):
    requested_minutes: int = Field(ge=1)
    approval_id: str | None = None


class JobExtendResponse(BaseModel):
    job_id: str
    approved: bool
    requires_human_approval: bool
    lease_expires_at: float


class ContextAttachRequest(BaseModel):
    job_id: str
    source_type: str = Field(description="ki|minio|openwebui")
    source_id: str
    target_project_id: str | None = None
    cross_platform: bool = False
    metadata: dict[str, Any] = Field(default_factory=dict)


class ActionRequest(BaseModel):
    job_id: str
    payload: dict[str, Any] = Field(default_factory=dict)


class PublicationTransformRequest(BaseModel):
    job_id: str
    adapter: str = Field(min_length=1)
    payload: dict[str, Any] = Field(default_factory=dict)


class ApprovalRequest(BaseModel):
    job_id: str
    reason_code: str
    requested_scopes: list[str]
    ttl_minutes: int = Field(ge=1)


class ApprovalDecision(BaseModel):
    approved: bool
    approver_id: str


def _inc_metric(name: str, by: int = 1) -> None:
    with _metrics_lock:
        _metrics[name] = _metrics.get(name, 0) + by


def _json_log(event: str, **fields: Any) -> None:
    ts = time.time()
    log_payload = {
        "event": event,
        "ts": ts,
        **fields,
    }
    _logger.info(json.dumps(log_payload, separators=(",", ":"), default=str))

    cutoff = ts - _audit_retention_seconds()
    pruned = 0
    with _audit_lock:
        _audit_events.append(log_payload)
        kept = [entry for entry in _audit_events if float(entry.get("ts", 0)) >= cutoff]
        pruned = max(0, len(_audit_events) - len(kept))
        _audit_events[:] = kept
    if pruned:
        _inc_metric("audit_events_pruned_total", pruned)


def _policy_deny(
    *,
    auth: AuthContext | None,
    job: JobState | None,
    code: str,
    message: str,
    status_code: int = 403,
) -> None:
    trace_id = str(uuid.uuid4())
    _inc_metric("denied_by_policy_total")
    _json_log(
        "policy_deny",
        trace_id=trace_id,
        code=code,
        message=message,
        status_code=status_code,
        service_id=(auth.service_id if auth else None),
        workflow_id=(auth.workflow_id if auth else None),
        job_id=(job.job_id if job else None),
    )
    raise HTTPException(status_code=status_code, detail={"code": code, "message": message, "trace_id": trace_id})


def _policy_allow(event: str, *, auth: AuthContext, job: JobState | None, **fields: Any) -> None:
    _json_log(
        event,
        decision="allow",
        service_id=auth.service_id,
        workflow_id=auth.workflow_id,
        job_id=(job.job_id if job else None),
        **fields,
    )


def _parse_workflow_policies() -> dict[str, Any]:
    try:
        parsed = json.loads(WORKFLOW_POLICY_JSON)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    return {}


_workflow_policy = _parse_workflow_policies()


def _parse_publication_adapters() -> dict[str, Any]:
    try:
        parsed = json.loads(PUBLICATION_ADAPTERS_JSON)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    return {}


_publication_adapters = _parse_publication_adapters()


def _parse_trusted_template_set() -> dict[str, Any]:
    try:
        parsed = json.loads(TRUSTED_TEMPLATE_SET_JSON)
        if isinstance(parsed, dict):
            return parsed
    except json.JSONDecodeError:
        pass
    return {}


def _parse_trusted_scope_template_map() -> dict[str, str]:
    try:
        parsed = json.loads(TRUSTED_SCOPE_TEMPLATE_MAP_JSON)
        if isinstance(parsed, dict):
            return {str(k): str(v) for k, v in parsed.items() if str(k).strip() and str(v).strip()}
    except json.JSONDecodeError:
        pass
    return {}


_trusted_template_set = _parse_trusted_template_set()
_trusted_scope_template_map = _parse_trusted_scope_template_map()


def _workflow_rule(workflow_id: str) -> dict[str, Any]:
    rules = _workflow_policy.get("workflows", {})
    if isinstance(rules, dict):
        rule = rules.get(workflow_id, {})
        if isinstance(rule, dict):
            return rule
    return {}


def _allowed_project_pair(project_a: str, project_b: str) -> bool:
    if not project_a or not project_b:
        return False
    pair_key = ":".join(sorted([project_a, project_b]))
    configured_pairs = {
        ":".join(sorted([x.split(":", 1)[0].strip(), x.split(":", 1)[1].strip()]))
        for x in TRUSTED_ALLOW_PROJECT_PAIRS.split(",")
        if ":" in x
    }
    return pair_key in configured_pairs


def _trusted_template_ready_for_cross_platform(required_scope: str) -> tuple[bool, str]:
    template_set_id = str(_trusted_template_set.get("template_set_id") or "")
    version = str(_trusted_template_set.get("version") or "")
    policy_template_path = str(_trusted_template_set.get("policy_template_path") or "")
    entitlement_template_path = str(_trusted_template_set.get("entitlement_template_path") or "")
    approved = bool(_trusted_template_set.get("approved"))

    if not approved:
        return False, "Trusted template set is not approved"
    if not template_set_id or not version:
        return False, "Trusted template set id/version is missing"
    if not policy_template_path or not entitlement_template_path:
        return False, "Trusted template paths are missing"

    mapped_template_set = _trusted_scope_template_map.get(required_scope)
    if mapped_template_set and mapped_template_set != template_set_id:
        return False, "Trusted scope-to-template mapping mismatch"

    return True, "ok"


def _require_scope(auth: AuthContext, required_scope: str) -> None:
    if required_scope not in auth.scopes:
        _policy_deny(
            auth=auth,
            job=None,
            code="missing_scope",
            message=f"Missing required scope: {required_scope}",
            status_code=403,
        )


def _decode_token(authorization: str | None) -> AuthContext:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")

    if not JWT_SECRET and not _jwks_client:
        # Fail closed by default when JWT verifier config is missing.
        raise HTTPException(status_code=503, detail="JWT verifier not configured")

    token = authorization.split(" ", 1)[1].strip()
    try:
        if _jwks_client:
            signing_key = _jwks_client.get_signing_key_from_jwt(token)
            claims = jwt.decode(
                token,
                signing_key.key,
                algorithms=[JWT_ALGORITHM],
                audience=JWT_AUDIENCE,
                issuer=JWT_ISSUER or None,
                options={"require": ["sub", "aud", "wf"]},
            )
        else:
            claims = jwt.decode(
                token,
                JWT_SECRET,
                algorithms=[JWT_ALGORITHM],
                audience=JWT_AUDIENCE,
                issuer=JWT_ISSUER or None,
                options={"require": ["sub", "aud", "wf"]},
            )
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail=f"Invalid token: {exc}") from exc

    scopes_raw = claims.get("scope", "")
    scopes: list[str]
    if isinstance(scopes_raw, str):
        scopes = scopes_raw.split()
    elif isinstance(scopes_raw, list):
        scopes = [str(s) for s in scopes_raw if str(s).strip()]
    else:
        scopes = []
    if not scopes:
        raise HTTPException(status_code=403, detail="Token has no scopes")

    return AuthContext(
        service_id=str(claims["sub"]),
        workflow_id=str(claims["wf"]),
        scopes=scopes,
        token_id=str(claims.get("jti")) if claims.get("jti") else None,
    )


def _require_auth(authorization: str | None = Header(default=None)) -> AuthContext:
    return _decode_token(authorization)


def _get_job_or_404(job_id: str) -> JobState:
    _reap_stale_jobs(time.time())
    with _jobs_lock:
        job = _jobs.get(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="Job not found")
    return job


def _enforce_job_access(job: JobState, auth: AuthContext) -> None:
    if auth.service_id != job.service_id:
        _policy_deny(
            auth=auth,
            job=job,
            code="cross_service_job_access",
            message="Cross-service job access denied",
        )
    if auth.workflow_id != job.workflow_id:
        _policy_deny(
            auth=auth,
            job=job,
            code="cross_workflow_job_access",
            message="Cross-workflow job access denied",
        )


def _is_job_stale(job: JobState, now: float) -> bool:
    stale_after = HEARTBEAT_INTERVAL_SECONDS * HEARTBEAT_MISS_GRACE
    return (now - job.last_heartbeat_at) > stale_after


def _reap_stale_jobs(now: float) -> None:
    stale_after = HEARTBEAT_INTERVAL_SECONDS * HEARTBEAT_MISS_GRACE
    removed = 0
    with _jobs_lock:
        stale_ids = [
            job_id
            for job_id, job in _jobs.items()
            if (now - job.last_heartbeat_at) > stale_after and now <= (job.lease_expires_at + stale_after)
        ]
        for job_id in stale_ids:
            del _jobs[job_id]
            removed += 1
    if removed:
        _inc_metric("stale_jobs_reaped_total", removed)
        _inc_metric("heartbeat_miss_total", removed)
        _json_log("jobs_reaped", count=removed, reason="heartbeat_miss_grace_exceeded")


def _litellm_headers() -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if LITELLM_API_KEY:
        headers["Authorization"] = f"Bearer {LITELLM_API_KEY}"
    return headers


def _ki_headers() -> dict[str, str]:
    headers = {"Content-Type": "application/json"}
    if KI_API_KEY:
        headers["Authorization"] = f"Bearer {KI_API_KEY}"
    return headers


def _approval_or_none(approval_id: str | None) -> ApprovalState | None:
    if not approval_id:
        return None
    with _approvals_lock:
        return _approvals.get(approval_id)


def _approval_is_valid_for_extension(approval: ApprovalState, job: JobState, now: float) -> bool:
    if approval.job_id != job.job_id:
        return False
    if approval.status != "approved":
        return False
    if approval.expires_at <= now:
        return False
    return BREAK_GLASS_EXTENSION_SCOPE in approval.requested_scopes


@app.get("/health")
def health() -> dict[str, str]:
    return {"status": "ok", "service": APP_NAME}


@app.get("/ready")
def ready() -> dict[str, str]:
    if not JWT_SECRET and not _jwks_client:
        raise HTTPException(status_code=503, detail="JWT verifier not configured")
    return {"status": "ready"}


@app.get("/m2m/v1/metrics")
def metrics() -> dict[str, Any]:
    with _metrics_lock:
        data = dict(_metrics)
    with _jobs_lock:
        active_jobs = len(_jobs)
    with _approvals_lock:
        pending_approvals = sum(1 for a in _approvals.values() if a.status == "pending")
    with _audit_lock:
        retained_audit_events = len(_audit_events)
    return {
        "metrics": data,
        "active_jobs": active_jobs,
        "pending_approvals": pending_approvals,
        "retained_audit_events": retained_audit_events,
        "audit_retention_days": _audit_retention_days(),
        "audit_retention_source": AUDIT_RETENTION_SOURCE,
        "audit_retention_override_enabled": bool(AUDIT_RETENTION_DAYS_OVERRIDE),
    }


@app.get("/m2m/v1/audit/events")
def audit_events(limit: int = 100) -> dict[str, Any]:
    max_items = max(1, min(limit, 1000))
    with _audit_lock:
        events = list(_audit_events[-max_items:])
    return {
        "retention_days": _audit_retention_days(),
        "retention_source": AUDIT_RETENTION_SOURCE,
        "count": len(events),
        "events": events,
    }


@app.post("/m2m/v1/token/introspect")
def token_introspect(auth: AuthContext = Depends(_require_auth)) -> dict[str, Any]:
    return {
        "active": True,
        "service_id": auth.service_id,
        "workflow_id": auth.workflow_id,
        "scopes": auth.scopes,
    }


@app.post("/m2m/v1/jobs/start", response_model=JobStartResponse)
def jobs_start(req: JobStartRequest, auth: AuthContext = Depends(_require_auth)) -> JobStartResponse:
    _require_scope(auth, "m2m.jobs.start")
    if req.workflow_id != auth.workflow_id:
        _policy_deny(auth=auth, job=None, code="workflow_claim_mismatch", message="Workflow claim mismatch")

    now = time.time()
    lease_seconds = LEASE_DEFAULT_MINUTES * 60
    job = JobState(
        job_id=str(uuid.uuid4()),
        service_id=auth.service_id,
        workflow_id=req.workflow_id,
        project_id=req.project_id,
        policy_class=req.policy_class,
        lease_started_at=now,
        lease_expires_at=now + lease_seconds,
        last_heartbeat_at=now,
        total_runtime_cap_seconds=LEASE_APPROVAL_MAX_HOURS * 3600,
        extension_seconds_granted=0,
    )
    with _jobs_lock:
        _jobs[job.job_id] = job

    _policy_allow("jobs_start", auth=auth, job=job, project_id=job.project_id, policy_class=job.policy_class)

    return JobStartResponse(
        job_id=job.job_id,
        lease_expires_at=job.lease_expires_at,
        heartbeat_interval_seconds=HEARTBEAT_INTERVAL_SECONDS,
    )


@app.post("/m2m/v1/jobs/{job_id}/heartbeat", response_model=JobHeartbeatResponse)
def jobs_heartbeat(job_id: str, auth: AuthContext = Depends(_require_auth)) -> JobHeartbeatResponse:
    _require_scope(auth, "m2m.jobs.heartbeat")
    now = time.time()
    with _jobs_lock:
        job = _jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found")
        _enforce_job_access(job, auth)
        if now > job.lease_expires_at:
            _inc_metric("lease_expired_total")
            _policy_deny(auth=auth, job=job, code="lease_expired", message="Lease expired")
        job.last_heartbeat_at = now

    _policy_allow("jobs_heartbeat", auth=auth, job=job)

    return JobHeartbeatResponse(
        job_id=job_id,
        lease_expires_at=job.lease_expires_at,
        stale_after_seconds=HEARTBEAT_INTERVAL_SECONDS * HEARTBEAT_MISS_GRACE,
    )


@app.post("/m2m/v1/jobs/{job_id}/extend", response_model=JobExtendResponse)
def jobs_extend(job_id: str, req: JobExtendRequest, auth: AuthContext = Depends(_require_auth)) -> JobExtendResponse:
    _require_scope(auth, "m2m.jobs.extend")
    now = time.time()
    with _jobs_lock:
        job = _jobs.get(job_id)
        if not job:
            raise HTTPException(status_code=404, detail="Job not found")
        _enforce_job_access(job, auth)

        requested_seconds = req.requested_minutes * 60
        elapsed = max(0, int(now - job.lease_started_at))
        projected_total = elapsed + job.extension_seconds_granted + requested_seconds

        auto_cap = LEASE_AUTO_EXTEND_MAX_HOURS * 3600
        hard_cap = LEASE_APPROVAL_MAX_HOURS * 3600
        if projected_total > hard_cap:
            _policy_deny(auth=auth, job=job, code="extension_exceeds_hard_cap", message="Extension exceeds hard runtime cap")

        requires_approval = projected_total > auto_cap
        if requires_approval:
            _inc_metric("approval_required_total")
            approval = _approval_or_none(req.approval_id)
            if not approval:
                _policy_allow("jobs_extend_requires_approval", auth=auth, job=job, requested_minutes=req.requested_minutes)
                return JobExtendResponse(
                    job_id=job_id,
                    approved=False,
                    requires_human_approval=True,
                    lease_expires_at=job.lease_expires_at,
                )
            if not _approval_is_valid_for_extension(approval, job, now):
                _inc_metric("approval_denied_total")
                _policy_deny(
                    auth=auth,
                    job=job,
                    code="approval_invalid_or_expired",
                    message="Approval is invalid, denied, expired, or missing required scope",
                )

            job.extension_seconds_granted += requested_seconds
            job.lease_expires_at += requested_seconds

            return JobExtendResponse(
                job_id=job_id,
                approved=True,
                requires_human_approval=False,
                lease_expires_at=job.lease_expires_at,
            )

        job.extension_seconds_granted += requested_seconds
        job.lease_expires_at += requested_seconds

    _policy_allow(
        "jobs_extend",
        auth=auth,
        job=job,
        requested_minutes=req.requested_minutes,
        approval_id=req.approval_id,
    )

    return JobExtendResponse(
        job_id=job_id,
        approved=True,
        requires_human_approval=False,
        lease_expires_at=job.lease_expires_at,
    )


@app.post("/m2m/v1/context/attach")
def context_attach(req: ContextAttachRequest, auth: AuthContext = Depends(_require_auth)) -> dict[str, Any]:
    _require_scope(auth, "m2m.context.attach")
    job = _get_job_or_404(req.job_id)
    _enforce_job_access(job, auth)

    rule = _workflow_rule(auth.workflow_id)
    allowed_sources = rule.get("allowed_sources", [])
    if isinstance(allowed_sources, list):
        if allowed_sources:
            if req.source_type not in allowed_sources:
                _policy_deny(
                    auth=auth,
                    job=job,
                    code="source_not_allowed_for_workflow",
                    message=f"Source not allowed for workflow: {req.source_type}",
                )
        elif not DEFAULT_ALLOW_DYNAMIC_SOURCES:
            _policy_deny(
                auth=auth,
                job=job,
                code="dynamic_sources_default_deny",
                message="Dynamic sources are default-deny for this workflow",
            )

    if req.cross_platform and not TRUSTED_INTEROP_ENABLED:
        _policy_deny(
            auth=auth,
            job=job,
            code="trusted_interop_disabled",
            message="Trusted interoperability profile disabled",
        )

    if req.cross_platform:
        ready, reason = _trusted_template_ready_for_cross_platform("m2m.context.attach")
        if not ready:
            _policy_deny(
                auth=auth,
                job=job,
                code="trusted_template_set_missing_or_unapproved",
                message=reason,
            )
        if req.source_type in {"minio", "openwebui"}:
            _policy_deny(
                auth=auth,
                job=job,
                code="project_bound_context_not_shareable",
                message="Project-bound MinIO/OpenWebUI context is not shareable across platforms",
            )
        if not req.target_project_id:
            raise HTTPException(status_code=400, detail="target_project_id is required for cross-platform attach")
        if not _allowed_project_pair(job.project_id, req.target_project_id):
            _policy_deny(
                auth=auth,
                job=job,
                code="project_pair_not_approved",
                message="Project pair not approved for trusted interoperability",
            )

    if req.source_type not in {"ki", "minio", "openwebui"}:
        raise HTTPException(status_code=400, detail="Unsupported source_type")

    # Boundary guard: reusable assets should be KI-backed; private project context stays project-bound.
    if req.source_type == "ki" and req.source_id.startswith("private:"):
        _policy_deny(
            auth=auth,
            job=job,
            code="private_context_in_ki_path",
            message="Private project-bound context not allowed in KI attach path",
        )

    ki_result: dict[str, Any] | None = None
    if req.source_type == "ki":
        do_lookup = bool(req.metadata.get("resolve"))
        if do_lookup:
            query = str(req.metadata.get("query") or req.source_id)
            collection = str(req.metadata.get("collection") or "default")
            top_k = int(req.metadata.get("top_k") or 5)
            try:
                with httpx.Client(base_url=KI_BASE_URL, timeout=REQUEST_TIMEOUT_SECONDS, headers=_ki_headers()) as client:
                    resp = client.post(
                        "/v1/search",
                        json={"query": query, "collection": collection, "top_k": top_k},
                    )
                if resp.status_code >= 400:
                    raise HTTPException(status_code=502, detail=f"Knowledge Index returned {resp.status_code}")
                ki_result = resp.json()
            except httpx.HTTPError as exc:
                raise HTTPException(status_code=502, detail=f"Knowledge Index request failed: {exc}") from exc

    namespace = f"svc:{auth.service_id}/project:{job.project_id}"
    _policy_allow(
        "context_attach",
        auth=auth,
        job=job,
        source_type=req.source_type,
        source_id=req.source_id,
        cross_platform=req.cross_platform,
        target_project_id=req.target_project_id,
        namespace=namespace,
    )

    return {
        "attached": True,
        "job_id": req.job_id,
        "namespace": namespace,
        "source_type": req.source_type,
        "source_id": req.source_id,
        "target_project_id": req.target_project_id,
        "cross_platform": req.cross_platform,
        "ki_result": ki_result,
    }


@app.post("/m2m/v1/infer")
def infer(req: ActionRequest, auth: AuthContext = Depends(_require_auth)) -> dict[str, Any]:
    _require_scope(auth, "m2m.infer")
    job = _get_job_or_404(req.job_id)
    _enforce_job_access(job, auth)
    now = time.time()
    if _is_job_stale(job, now):
        _policy_deny(auth=auth, job=job, code="job_heartbeat_stale", message="Job heartbeat stale")
    if now > job.lease_expires_at:
        _inc_metric("lease_expired_total")
        _policy_deny(auth=auth, job=job, code="lease_expired", message="Lease expired")

    rule = _workflow_rule(auth.workflow_id)
    allowed_models = rule.get("allowed_models", [])
    model = req.payload.get("model")
    if allowed_models:
        if not model:
            raise HTTPException(status_code=400, detail="model is required by workflow policy")
        if model not in allowed_models:
            _policy_deny(auth=auth, job=job, code="model_not_allowed", message="Model not allowed for workflow")

    try:
        with httpx.Client(base_url=LITELLM_BASE_URL, timeout=REQUEST_TIMEOUT_SECONDS, headers=_litellm_headers()) as client:
            resp = client.post("/v1/chat/completions", json=req.payload)
        if resp.status_code >= 400:
            raise HTTPException(status_code=502, detail=f"LiteLLM returned {resp.status_code}")
        inference_result = resp.json()
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"LiteLLM request failed: {exc}") from exc

    _policy_allow("infer", auth=auth, job=job, model=model)

    return {
        "accepted": True,
        "job_id": req.job_id,
        "result": inference_result,
    }


@app.post("/m2m/v1/skill/execute")
def skill_execute(req: ActionRequest, auth: AuthContext = Depends(_require_auth)) -> dict[str, Any]:
    _require_scope(auth, "m2m.skill.execute")
    job = _get_job_or_404(req.job_id)
    _enforce_job_access(job, auth)

    rule = _workflow_rule(auth.workflow_id)
    allowed_tools = rule.get("allowed_tools", [])
    tool_name = str(req.payload.get("tool_name") or "")
    if isinstance(allowed_tools, list) and allowed_tools:
        if tool_name not in [str(t) for t in allowed_tools]:
            _policy_deny(auth=auth, job=job, code="tool_not_allowed", message="Tool not allowed for workflow")

    execution_result: dict[str, Any]
    if SKILL_RUNNER_URL:
        try:
            with httpx.Client(base_url=SKILL_RUNNER_URL, timeout=REQUEST_TIMEOUT_SECONDS, headers={"Content-Type": "application/json"}) as client:
                resp = client.post("/execute", json=req.payload)
            if resp.status_code >= 400:
                raise HTTPException(status_code=502, detail=f"Skill runner returned {resp.status_code}")
            execution_result = resp.json()
        except httpx.HTTPError as exc:
            raise HTTPException(status_code=502, detail=f"Skill runner request failed: {exc}") from exc
    else:
        execution_result = {
            "executed": True,
            "tool_name": tool_name,
            "mode": "noop",
        }

    _policy_allow("skill_execute", auth=auth, job=job, tool_name=tool_name)

    return {
        "accepted": True,
        "job_id": req.job_id,
        "result": execution_result,
    }


@app.post("/m2m/v1/publish/transform")
def publication_transform(req: PublicationTransformRequest, auth: AuthContext = Depends(_require_auth)) -> dict[str, Any]:
    _require_scope(auth, "m2m.publish.transform")
    job = _get_job_or_404(req.job_id)
    _enforce_job_access(job, auth)

    rule = _workflow_rule(auth.workflow_id)
    allowed_adapters = rule.get("allowed_publication_adapters", [])
    if isinstance(allowed_adapters, list) and allowed_adapters:
        if req.adapter not in [str(a) for a in allowed_adapters]:
            _policy_deny(
                auth=auth,
                job=job,
                code="publication_adapter_not_allowed",
                message="Publication adapter not allowed for workflow",
            )

    adapter_cfg = _publication_adapters.get(req.adapter, {})
    if not isinstance(adapter_cfg, dict):
        adapter_cfg = {}

    transformed = {
        "adapter": req.adapter,
        "adapter_version": str(adapter_cfg.get("version") or "0"),
        "target_format": str(adapter_cfg.get("target_format") or "generic"),
        "data": req.payload,
    }

    _policy_allow(
        "publication_transform",
        auth=auth,
        job=job,
        adapter=req.adapter,
        target_format=transformed["target_format"],
    )

    return {
        "accepted": True,
        "job_id": req.job_id,
        "result": transformed,
        "contract": {
            "ki_core_unchanged": True,
            "adapter_transform_only": True,
        },
    }


@app.post("/m2m/v1/approval/request")
def approval_request(req: ApprovalRequest, auth: AuthContext = Depends(_require_auth)) -> dict[str, Any]:
    _require_scope(auth, "m2m.approval.request")
    job = _get_job_or_404(req.job_id)
    _enforce_job_access(job, auth)
    if not req.reason_code.strip():
        raise HTTPException(status_code=400, detail="reason_code is required")

    for requested_scope in req.requested_scopes:
        if requested_scope not in BREAK_GLASS_ALLOWED_SCOPES:
            _policy_deny(
                auth=auth,
                job=job,
                code="break_glass_scope_not_allowed",
                message=f"Requested scope not allowed for break-glass: {requested_scope}",
            )

    now = time.time()
    approval = ApprovalState(
        approval_id=str(uuid.uuid4()),
        job_id=req.job_id,
        requested_by=auth.service_id,
        requested_scopes=req.requested_scopes,
        reason_code=req.reason_code,
        status="pending",
        requested_at=now,
        expires_at=now + (req.ttl_minutes * 60),
    )
    with _approvals_lock:
        _approvals[approval.approval_id] = approval

    _policy_allow(
        "approval_request",
        auth=auth,
        job=job,
        approval_id=approval.approval_id,
        reason_code=req.reason_code,
        requested_scopes=req.requested_scopes,
        ttl_minutes=req.ttl_minutes,
    )

    return {
        "approval_id": approval.approval_id,
        "status": approval.status,
        "job_id": approval.job_id,
        "reason_code": approval.reason_code,
        "requested_scopes": approval.requested_scopes,
        "ttl_minutes": req.ttl_minutes,
        "requested_at": approval.requested_at,
        "expires_at": approval.expires_at,
    }


@app.post("/m2m/v1/approval/{approval_id}/decision")
def approval_decision(approval_id: str, req: ApprovalDecision, auth: AuthContext = Depends(_require_auth)) -> dict[str, Any]:
    _require_scope(auth, "m2m.approval.decision")
    now = time.time()
    with _approvals_lock:
        approval = _approvals.get(approval_id)
        if not approval:
            raise HTTPException(status_code=404, detail="Approval request not found")
        if approval.expires_at <= now:
            approval.status = "expired"
            _inc_metric("approval_denied_total")
            raise HTTPException(status_code=409, detail="Approval request expired")
        approval.status = "approved" if req.approved else "denied"
        approval.approver_id = req.approver_id
        approval.decided_at = now
    if not req.approved:
        _inc_metric("approval_denied_total")

    _json_log(
        "approval_decision",
        decision=approval.status,
        approval_id=approval_id,
        approver_id=req.approver_id,
        recorded_by=auth.service_id,
        job_id=approval.job_id,
        requested_by=approval.requested_by,
        requested_scopes=approval.requested_scopes,
    )

    return {
        "approval_id": approval_id,
        "approved": req.approved,
        "approver_id": req.approver_id,
        "recorded_by": auth.service_id,
        "status": approval.status,
        "decided_at": approval.decided_at,
        "expires_at": approval.expires_at,
    }
