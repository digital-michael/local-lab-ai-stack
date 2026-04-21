# Localhost M2M Access MVP (Open WebUI + Gateway)

**Status:** Draft (MVP-first)
**Date:** 2026-04-19
**Audience:** Operators and implementation agents

Cross-reference: `m2m-localhost-mvp-checklist.md`

---

## 1 Goal

Provide secure, localhost-only machine-to-machine access to LLM/RAG/skills while preserving strict isolation between:
- user chats
- named M2M services
- per-workflow execution contexts

MVP includes trusted cross-platform sharing for approved project pairs under explicit policy/template controls.

This design treats Open WebUI as an operations/audit surface, not the primary security boundary.

---

## 2 MVP Security Boundary

**Authoritative boundary:** local M2M gateway policy engine.

**Non-authoritative boundary:** Open WebUI project/folder grouping (operational visibility only).

All M2M calls must terminate at the gateway first. The gateway decides:
- identity
- scope
- model/tool/context access
- lease/heartbeat validity
- rate/throughput policy

---

## 3 Aligned Decisions (Resolved)

### D-M2M-001 Identity granularity

- One named M2M identity per calling service.
- Policies are **per-workflow** under that identity.
- Each identity is mapped to one Open WebUI M2M project/folder namespace for audit/troubleshooting.

### D-M2M-002 Context-source access mode

- Default mode: **default-deny** for dynamic context sources.
- Optional runtime setting: `default_allow_dynamic_sources` (disabled by default).
- If enabled, setting must be time-bounded and audit logged.

### D-M2M-003 Human approval channel

- Break-glass and privilege overrides are approved through **web approval**.
- Approval is operation-scoped and time-bounded.
- Admin UI/view is an MVP extension point (can start as a minimal review page).

### D-M2M-004 Long-running policy (replaces "unlimited")

- "Unlimited" is replaced by **long-running** policy class.
- Jobs start with low default lease TTL.
- Jobs may request extension before expiry.
- Extension beyond threshold requires web approval.
- Heartbeat required to keep lease active.

### D-M2M-005 Break-glass governance

- Break-glass is human-enabled ("sudo-like"), narrow-scope, and auto-expiring.
- Every break-glass action requires:
  - reason code
  - approver identity
  - TTL
  - explicit scope list

### D-M2M-006 Retention default

- Audit retention is configurable.
- Default retention inherits Prometheus retention duration.

### D-M2M-007 Dynamic sources and KI authority

- Dynamic access to context/KI/file sources is allowed by policy.
- Knowledge Index privileges remain authoritative.
- Any privilege escalation against KI policy requires explicit human approval.

### D-M2M-008 Trusted interoperability profile and domain split (MVP scope)

- Trusted integration for approved project pairs is part of MVP and is enabled through an explicit profile, not a global default.
- Reusable governed assets live in Knowledge Index.
- Specialized/private project lessons remain in MinIO + Open WebUI project-bound context.
- External publication format/protocol mapping is handled by publication adapters, decoupled from KI core schema and policy model.
- Policy and entitlement templates are required and versioned to reduce semantic drift across projects.

---

## 4 Standards and Existing Solutions to Reuse

Priority is existing solutions already in this stack and broadly adopted standards.

1. OAuth 2.1 style M2M auth using Client Credentials grant.
2. JWT access tokens with short lifetime.
3. No refresh tokens for M2M in MVP; services request a new access token when needed.
4. Authentik as authorization server (existing stack component).
5. Gateway-side policy enforcement and token validation.
6. Existing heartbeat pattern from node lifecycle adapted for job leases.

Notes:
- Use mTLS-bound credentials only if a concrete local process identity requirement appears.
- Start with bearer JWT + strict localhost binding for MVP.

---

## 5 MVP Architecture

```text
Local Service (named M2M client)
  -> Authentik token endpoint (client credentials)
  -> Local M2M Gateway (127.0.0.1 only)
     -> Policy engine (workflow scope, lease, rate class)
     -> Open WebUI project context adapter (ops visibility)
     -> LiteLLM / Knowledge Index / skill endpoints
  -> Structured response + audit event
```

### 5.1 Localhost constraints

- Gateway bind: `127.0.0.1` only.
- Optional secondary bind: Unix domain socket for high-assurance local clients.
- No LAN/WAN bind in MVP.

### 5.2 Namespace model

- `service_name` (identity)
- `workflow_id` (policy unit)
- `project_id` (Open WebUI operational grouping)
- `context_set` (dynamic source selection, policy-gated)

---

## 6 Token and Lease Model (MVP)

### 6.1 Token

- Token type: JWT access token.
- Grant: Client Credentials.
- Default token TTL: 10 minutes.
- Rotation: client re-mints token; no refresh token in MVP.

Required claims:
- `sub` = service identity
- `aud` = local-m2m-gateway
- `scope` = workflow and capability scopes
- `wf` = workflow id
- `sid` = service id

### 6.2 Lease + heartbeat

- Job lease default TTL: 30 minutes.
- Auto-extension window (no human approval): up to 24 hours total runtime.
- Approval-required extension window: >24 hours up to 7 days.
- Hard cap: 7 days per run in MVP.
- Heartbeat interval: every 60 seconds.
- Grace period: 3 missed heartbeats.

If heartbeat expires:
- lease becomes invalid
- further tool/model calls denied
- job marked stale/reaped

---

## 7 Policy Classes (MVP)

### 7.1 `strict`

- low rate + low concurrency
- short lease only
- no privileged tools

### 7.2 `sustained`

- moderate throughput
- longer lease budget
- selected tool access

### 7.3 `long_running`

- high sustained throughput
- heartbeat + lease extension required
- approval for high-risk scope changes

### 7.4 `break_glass`

- manually enabled via web approval
- minimum required scope only
- short TTL, full audit, automatic revocation

---

## 8 Default Policy Values (Configurable)

```yaml
m2m:
  localhost_only: true
  token_ttl_minutes: 10
  lease_default_minutes: 30
  lease_auto_extend_max_hours: 24
  lease_approval_max_hours: 168   # 7 days
  heartbeat_interval_seconds: 60
  heartbeat_miss_grace: 3
  default_allow_dynamic_sources: false
  retention:
    source: prometheus_default
    override_days: null
  approvals:
    channel: web
    require_reason_code: true
    allowed_scopes:
      - m2m.jobs.extend.high
  publication_adapters:
    enabled: true
    registry: []
```

---

## 9 MVP API Surface (Gateway)

- `POST /m2m/v1/token/introspect` (internal)
- `POST /m2m/v1/jobs/start`
- `POST /m2m/v1/jobs/{job_id}/heartbeat`
- `POST /m2m/v1/jobs/{job_id}/extend`
- `POST /m2m/v1/context/attach`
- `POST /m2m/v1/infer`
- `POST /m2m/v1/skill/execute`
- `POST /m2m/v1/approval/request`
- `POST /m2m/v1/approval/{id}/decision` (web admin)
- `POST /m2m/v1/publish/transform` (adapter-only publication transform)
- `GET /m2m/v1/audit/events` (retained audit event inspection)

---

## 10 Python Client Guidance (MVP)

Use a small Python client wrapper:
- obtains client-credentials token
- caches token until near-expiry
- re-mints automatically
- sends heartbeat on long-running jobs
- handles extension requests and approval-required responses

Rationale:
- avoids refresh-token complexity
- simpler operational model for external M2M clients
- aligns with standard OAuth client-credentials usage

---

## 11 Audit Requirements

Each decision/action logs:
- service identity
- workflow id
- job id
- requested scope(s)
- policy class
- approval id (if any)
- allow/deny outcome
- reason code
- timestamps

Audit log retention defaults to Prometheus retention, with explicit override support.

---

## 12 MVP Non-Goals

- Multi-host remote M2M exposure
- Cross-project data sharing without trusted-profile policy controls
- Persistent break-glass grants
- Unbounded runtime without lease controls

Note: trusted cross-project sharing is available only through an explicit trusted interoperability profile with template-governed controls.

---

## 13 Rollout Sequence (MVP-first)

1. Implement localhost gateway skeleton + policy config.
2. Integrate Authentik client-credentials token validation.
3. Add identity/workflow scoping + default-deny context policy.
4. Add lease + heartbeat + extension controls.
5. Add minimal web approval flow for break-glass and extensions.
6. Add Open WebUI project mapping for audit visibility.
7. Implement trusted interoperability profile controls (policy/entitlement templates, KI/MinIO boundary checks).
8. Add dashboards/alerts for stale jobs, denied calls, and approval queue.

---

## 14 Open Items (Post-MVP)

- Dual-control approvals for high-risk operations.
- mTLS-bound tokens for high-assurance local clients.
- Full operator UI for policy and approval management.
- Finer-grained KI privilege overlays and source trust tiers.

## 15 Trusted Interoperability Overlay (Workflow-level)

This overlay applies only when explicitly enabled for a trusted project pair.

1. Two-plane model:
- Internal knowledge plane: KI custody, provenance, retrieval policy.
- External publication plane: adapters translate KI outputs to external standards.

2. Domain boundary:
- KI stores reusable governed library knowledge.
- MinIO/Open WebUI store specialized project-bound context and private lessons.

3. Enforcement split:
- Gateway remains authoritative for requester identity and scope.
- KI remains authoritative for source/content privileges.

4. Regulation model:
- Template-first policy and entitlement sets are mandatory.
- Templates are versioned, reviewed, and promoted through change control.

5. Default posture:
- Trusted profile is off by default.
- Default deployment remains localhost-only with default-deny dynamic source access.
