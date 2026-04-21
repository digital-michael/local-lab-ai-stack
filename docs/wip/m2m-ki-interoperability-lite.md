# M2M + Knowledge Index Interoperability (Lite Touch)

Status: Draft
Date: 2026-04-20
Audience: Operators and implementation agents

Primary reference: m2m-localhost-mvp.md

---

## 1) Purpose

Capture a fast alignment for how M2M localhost security and Knowledge Index sharing should work for the current trusted multi-project scenario, without a deep design dive.

This document is intentionally short and decision-oriented.

---

## 2) Current Scenario Assumptions

1. Projects are in a trusted relationship.
2. One project is localhost-only and contains reusable general library knowledge and private content.
3. Full sharing is desired for this integration.
4. Sharing must be regulated to avoid project drift.
5. Monetization readiness is a near-term consideration.
6. External publication standards are postponed for this integration and handled via publication adapters later.

---

## 3) Fast Alignment Decisions

### A. Internal vs external separation

Use two planes:

1. Internal knowledge plane:
- Knowledge Index remains focused on custody, provenance, policy, and retrieval.
- Shared usage across trusted projects is allowed.

2. External publication plane:
- Publication adapters handle external format/protocol mapping.
- Adapter logic remains decoupled from Knowledge Index core schema and policy model.

### B. Domain separation strategy

Use Knowledge Index for reusable governed library assets.
Use MinIO + Open WebUI project-bound content for specialized lessons learned and private project context.

This avoids overloading Knowledge Index with mixed intent.

### C. Security boundary strategy

Treat M2M gateway authn/authz as the authoritative enforcement point.
Knowledge Index policy remains authoritative for content and source privileges.

Net effect:
- Gateway controls who can request.
- Knowledge Index controls what may be served.

### D. Regulation strategy

Policy and entitlement templates are required for consistency.
Templates should be versioned and reviewed to prevent semantic drift between projects.

---

## 4) Primary Concern Disposition

1. Policy sprawl risk:
- Reduced by mandatory templates and review gates.
- Residual risk is process drift, not architecture.

2. Mixed intent in one KI:
- Addressed by separating specialized lessons into MinIO/Open WebUI.

3. Adapter leakage into KI core:
- Addressed if adapter boundaries are explicit and one-way.
- Rule: external adapter transforms outputs, KI core model does not mutate per external target.

4. Future less-trusted integrations:
- Addressed by M2M gateway as trust choke point.
- Important: current trusted mode must be an explicit profile, not the global default.

---

## 5) Scope Boundary for This Track

In scope now:
1. Trusted integration posture.
2. Regulated full sharing for this project pair.
3. Template-first policy/entitlement operating model.
4. Clear KI vs MinIO/Open WebUI responsibility split.

Out of scope now:
1. External publication standard lock-in.
2. Full cross-org interoperability protocol finalization.
3. Deep adapter implementation design.

---

## 6) Handoff to Follow-on Integration Context

The next design context should focus on:

1. Concrete template set
- Baseline entitlement templates.
- Baseline policy templates.
- Template versioning and approval workflow.

2. Gateway enforcement contract
- Required token claims.
- Scope-to-policy mapping.
- Default deny/allow matrix.

3. KI boundary contract
- Which content types enter KI vs stay in MinIO/Open WebUI.
- Promotion path from private/project-bound to reusable library asset.

4. Publication adapter contract
- Inputs from KI.
- Output targets.
- Validation and audit requirements.

---

## 7) One-Line Summary

For this trusted localhost M2M phase: keep KI as the regulated reusable asset layer, keep specialized lessons in MinIO/Open WebUI, enforce access at gateway + KI policy layers, and postpone external publication standard lock-in to decoupled adapters.
