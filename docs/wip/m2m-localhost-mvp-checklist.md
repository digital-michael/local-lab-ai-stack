# Localhost M2M Access MVP - Implementation Checklist

**Status:** Draft
**Date:** 2026-04-20
**Depends on:** `m2m-localhost-mvp.md`

---

## Purpose

Execution checklist for the localhost M2M MVP using existing stack components and standards-first choices:

- Authentik client credentials
- gateway-enforced policy boundary
- Open WebUI for operational grouping/audit visibility
- lease + heartbeat for long-running workflows

---

## 0 Decision Lock (pre-build)

- [ ] D0.1 Confirm one named identity per calling service
- [ ] D0.2 Confirm per-workflow policy scope under each identity
- [ ] D0.3 Confirm default-deny dynamic context mode (default-allow optional setting remains off)
- [ ] D0.4 Confirm web approval for break-glass and high-scope lease extension
- [ ] D0.5 Confirm long-running profile replaces unlimited profile
- [ ] D0.6 Confirm audit retention default inherits Prometheus retention
- [ ] D0.7 Confirm trusted interoperability profile is explicit opt-in and off by default
- [ ] D0.8 Confirm KI vs MinIO/Open WebUI domain split for reusable vs project-bound content

Exit criteria:

- All eight decisions are recorded as accepted in project notes before coding starts.

---

## 1 Config Schema Delta (MVP)

Add an `m2m` block to `configs/config.json` and document it.

- [x] C1.1 Add `m2m.localhost_only` (bool, default `true`)
- [x] C1.2 Add `m2m.token_ttl_minutes` (int, default `10`)
- [x] C1.3 Add `m2m.lease_default_minutes` (int, default `30`)
- [x] C1.4 Add `m2m.lease_auto_extend_max_hours` (int, default `24`)
- [x] C1.5 Add `m2m.lease_approval_max_hours` (int, default `168`)
- [x] C1.6 Add `m2m.heartbeat_interval_seconds` (int, default `60`)
- [x] C1.7 Add `m2m.heartbeat_miss_grace` (int, default `3`)
- [x] C1.8 Add `m2m.default_allow_dynamic_sources` (bool, default `false`)
- [x] C1.9 Add `m2m.retention.source` (enum, default `prometheus_default`)
- [x] C1.10 Add `m2m.approvals.channel` (enum, default `web`)
- [x] C1.11 Add `m2m.approvals.require_reason_code` (bool, default `true`)

Exit criteria:

- `configure.sh validate` passes with new schema fields.

---

## 2 Auth Foundation (use existing Authentik)

- [ ] A2.1 Create M2M OAuth client(s) in Authentik for named service identities
- [ ] A2.2 Configure client credentials grant only for those clients
- [ ] A2.3 Set audience to gateway API
- [ ] A2.4 Set short access token TTL (10m default)
- [x] A2.5 Document secret handling path using Podman secrets (no plaintext in tracked files)

Exit criteria:

- Named service can mint access token and gateway validates token claims.

---

## 3 Gateway Skeleton (localhost-only)

- [x] G3.1 Create local M2M gateway service (new internal component)
- [x] G3.2 Bind only to `127.0.0.1` in MVP
- [x] G3.3 Add health/readiness endpoints
- [x] G3.4 Add strict auth middleware (reject missing/invalid token)
- [x] G3.5 Enforce `aud`, `sub`, `scope`, and workflow claims

Exit criteria:

- Calls without valid token fail closed.

---

## 4 Policy Engine (per-workflow)

- [x] P4.1 Define policy object: `service_name`, `workflow_id`, `policy_class`, allowed models/tools/context sources
- [x] P4.2 Enforce default-deny for dynamic context attach
- [x] P4.3 Add optional `default_allow_dynamic_sources` setting (off by default)
- [x] P4.4 Add reasoned denial responses with policy trace ID
- [x] P4.5 Add policy decision logs

Exit criteria:

- Unauthorized model/tool/context requests are denied with auditable reason.

---

## 5 Lease and Heartbeat (long-running)

- [x] L5.1 Add `jobs/start` endpoint with lease issuance
- [x] L5.2 Add `jobs/heartbeat` endpoint with grace counter
- [x] L5.3 Add `jobs/extend` endpoint with threshold checks
- [x] L5.4 Auto-allow extension up to 24h total runtime
- [x] L5.5 Require approval for extension beyond 24h (up to 7d max)
- [x] L5.6 Reap stale jobs after missed heartbeat grace window

Exit criteria:

- Long-running jobs remain active only while lease + heartbeat are valid.

---

## 6 Approval Flow (web channel)

- [x] W6.1 Add approval request object (requestor, scope, reason code, TTL)
- [x] W6.2 Add approve/deny decision endpoint for web admin flow
- [x] W6.3 Enforce auto-expiry on approved elevations
- [x] W6.4 Record approver identity and timestamps
- [x] W6.5 Restrict break-glass to explicit scope list only

Exit criteria:

- Break-glass path is human-enabled, time-boxed, and fully audited.

---

## 7 Integrations (existing components)

- [x] I7.1 Add gateway route to LiteLLM calls (respect per-workflow model allowlist)
- [x] I7.2 Add gateway route to Knowledge Index attach/query operations
- [x] I7.3 Add gateway route to skills/tool execution path
- [x] I7.4 Map `service_name` to Open WebUI project/folder namespace metadata for audit visibility
- [x] I7.5 Add trusted interoperability profile toggle and policy gate in gateway
- [x] I7.6 Enforce KI as reusable-governed layer and MinIO/Open WebUI as project-bound layer
- [x] I7.7 Add publication adapter boundary contract (adapter transforms outputs only; KI core schema/policy unchanged)

Exit criteria:

- Gateway mediates all M2M access paths required by MVP.

---

## 8 Python Client Wrapper (MVP ergonomics)

- [ ] Y8.1 Implement simple Python helper for client credentials token minting
- [ ] Y8.2 Implement in-memory token cache with near-expiry renewal
- [ ] Y8.3 Implement heartbeat scheduler helper for long-running jobs
- [ ] Y8.4 Implement extension request helper with approval-required handling
- [ ] Y8.5 Provide one sample workflow integration snippet

Exit criteria:

- External Python service can run long-running workflow without refresh token logic.

---

## 9 Observability and Retention

- [x] O9.1 Add structured audit logs for allow/deny decisions
- [x] O9.2 Add counters for denied-by-policy, lease-expired, approval-required, approval-denied
- [x] O9.3 Add stale-job and heartbeat-miss metrics
- [x] O9.4 Set default audit retention from Prometheus retention
- [x] O9.5 Allow explicit retention override setting

Exit criteria:

- Operator can answer who requested what, when, why it was allowed/denied, and what expired.

---

## 10 Security Validation

- [x] S10.1 Verify no M2M endpoint binds beyond localhost
- [x] S10.2 Verify all unauthenticated requests fail closed
- [x] S10.3 Verify token with wrong audience fails
- [x] S10.4 Verify cross-workflow scope access is denied
- [x] S10.5 Verify break-glass expires and cannot be reused
- [x] S10.6 Verify default-allow mode toggle is off by default

Exit criteria:

- Security checks pass and no bypass path is observed.

---

## 11 MVP Acceptance Test Matrix

- [x] T11.1 Named service starts workflow in its own namespace
- [x] T11.2 Same service denied when requesting disallowed model
- [x] T11.3 Same service denied when attaching disallowed context source
- [x] T11.4 Long-running workflow survives normal duration with heartbeat
- [x] T11.5 Long-running workflow is reaped when heartbeat stops
- [x] T11.6 Extension beyond 24h requires approval and succeeds only if approved
- [x] T11.7 Break-glass action is logged with reason code and auto-expires
- [x] T11.8 Trusted profile enabled: approved project pair can share KI-governed assets across platforms
- [x] T11.9 Trusted profile disabled: cross-platform sharing attempt is denied by default
- [x] T11.10 Project-bound private lessons remain in MinIO/Open WebUI scope unless explicitly promoted

Exit criteria:

- All MVP tests pass in local environment.

---

## 12 Deferred (post-MVP)

- [ ] D12.1 Dual-control approvals for high-risk scopes
- [ ] D12.2 mTLS-bound tokens for high-assurance local clients
- [ ] D12.3 Full web admin console for policy/approval lifecycle
- [ ] D12.4 Advanced KI source trust-tier overlays

---

## 13 Trusted Interoperability Controls (MVP Required)

- [x] T13.1 Define baseline policy templates for trusted project-pair sharing
- [x] T13.2 Define baseline entitlement templates for trusted project-pair sharing
- [x] T13.3 Add template versioning and approval workflow
- [x] T13.4 Add scope-to-template mapping in gateway policy engine
- [x] T13.5 Add template conformance checks in CI or validation workflow

Exit criteria:

- Trusted interoperability mode cannot run without approved template set references.

---

## Suggested Build Order

1. Sections 1-4
2. Sections 5-6
3. Sections 7-8
4. Section 13
5. Sections 9-11
6. Section 12 backlog triage

---

## Implementation Deviations and Unplanned Work

- [x] U0.1 Added automated security/acceptance test module `testing/security/test_m2m_gateway.py` (unplanned unit created to prevent manual-only validation drift)
- [x] U0.2 Added script `scripts/m2m-authentik-bootstrap.sh` to verify issuer/JWKS and optionally apply config values (deviation: bootstrap helper introduced before full Authentik API automation)
- [x] U0.3 Added gateway endpoint `GET /m2m/v1/audit/events` for retained decision log inspection (unplanned but required to make O9 retention behavior observable)
- [x] U0.4 Added runtime bootstrap dependency recovery in local venv (`ensurepip` + pytest install) to unblock test execution (environment deviation; not stack runtime behavior)
- [x] U0.5 Broadened test fixture workflow source policy (`ki,minio`) to validate project-bound cross-platform boundary denial path; maintained separate negative test using `openwebui` source to preserve deny-by-policy coverage
- [x] U0.6 Added trusted interoperability template governance baseline: versioned policy/entitlement templates in `configs/m2m/templates/`, scope-to-template enforcement in gateway, and conformance checks in `configure.sh validate`

Notes:

- These units were implemented to prevent dropped actions and make acceptance status executable.
- Any further replacement of helper-script workflow with full Authentik API automation should preserve current status checks.
