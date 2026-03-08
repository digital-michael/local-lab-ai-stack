# Meta Decisions — Decision Record
**Last Updated:** 2026-03-08 UTC
**Target Audience:** LLM Agents

---

## Purpose

This file records decisions made during collaboration between the human operator and LLM agent. It is the canonical location for the decision record framework and the decision log. For the active workflow directives that govern how decisions are made, see [meta.md](meta.md).

---

## Table of Contents

1. [Decision Record Framework](#1-decision-record-framework)
2. [Decision Log](#2-decision-log)

---

# 1 Decision Record Framework

Each decision is recorded with the following fields:

| Field | Description |
|---|---|
| **ID** | Sequential identifier (D-001, D-002, ...) |
| **Decision** | What was decided |
| **Context** | What problem or question prompted it |
| **Options Considered** | Alternatives that were on the table (if applicable) |
| **Rationale** | Why this option won |
| **Driver** | Who drove the decision: `human`, `agent`, or `joint` |
| **Trigger** | What prompted the decision: a blocker, a question, a pattern recognition, a lateral insight |
| **Commit** | The commit(s) where this materialized (if applicable) |

Not every field is required for every decision. Favor capturing the decision and rationale over completeness for its own sake.

---

# 2 Decision Log

### D-001 — Three-Document Split

| Field | Value |
|---|---|
| **Decision** | Split the monolithic architecture document into three: architecture (design), implementation (procedures), configuration (tunable values) |
| **Context** | The original document tried to serve three audiences — someone understanding the system, someone deploying it, and someone tuning it. Sections were fighting each other, and updates to one concern risked breaking another. |
| **Options Considered** | (1) Keep one doc with clear section boundaries. (2) Split into two (design vs. operations). (3) Split into three by concern. |
| **Rationale** | Three-way split maps cleanly to single-source-of-truth: each fact lives in exactly one file. Deployment procedures don't interleave with port numbers. Schema rationale doesn't crowd out architecture diagrams. |
| **Driver** | Joint |
| **Trigger** | Pattern recognition — the agent saw repeated cross-concern conflicts while editing; the human validated the separation principle. |
| **Commit** | `1de9dd4` |

---

### D-002 — JSON Config as Machine-Readable Single Source of Truth

| Field | Value |
|---|---|
| **Decision** | Use `configs/config.json` as the machine-readable SSOT for all service definitions, with `configure.sh` as the CRUD interface. |
| **Context** | Configuration values were scattered across markdown docs and scripts. No single place to read or write a port number, image tag, or secret name. |
| **Options Considered** | (1) YAML config files. (2) Environment `.env` files per service. (3) A single JSON file with a shell-based CRUD tool. |
| **Rationale** | JSON is natively parseable by `jq` (already a project dependency), avoids the quoting pitfalls of `.env` files, and a single file keeps the SSOT principle intact. The shell wrapper (`configure.sh`) provides validation and generation, keeping the JSON clean. |
| **Driver** | Joint |
| **Trigger** | Blocker — couldn't generate quadlets or provision secrets without a single authoritative source for service definitions. |
| **Commit** | `75caab2`, `c4c8bfd` |

---

### D-003 — Component Library: Three Files Per Component

| Field | Value |
|---|---|
| **Decision** | Every component gets a directory under `docs/library/framework_components/` with exactly three files: `best_practices.md`, `security.md`, `guidance.md`. |
| **Context** | Needed a place for component-specific knowledge that was normative (the agent must follow it) but separate from the system-level architecture docs. |
| **Options Considered** | (1) A single `components.md` file with sections. (2) One file per component. (3) Three files per component, split by concern. |
| **Rationale** | The three-file split separates industry knowledge (best_practices) from project opinions (guidance) from hardening rules (security). This lets us update vendor recommendations without touching project decisions, and vice versa. It also makes compliance checkable — an agent can read just `security.md` for a focused review. |
| **Driver** | Joint |
| **Trigger** | Scaling problem — component knowledge didn't fit in the architecture doc and had no home. |
| **Commit** | `c94029d` |

---

### D-004 — README-agent.md as Directory-Scoped Agent Governance

| Field | Value |
|---|---|
| **Decision** | Files named `README-agent.md` are directive documents for LLM agents, scoped to their directory and all descendants. Most-specific wins; parent rules apply where child doesn't override. |
| **Context** | We had created `README-agent.md` files at two levels (repo root, framework_components) but never formalized what the convention *means*. The human asked: "should we mention this as a default adherence/guidance mechanism?" |
| **Options Considered** | (1) Informal convention, no rules. (2) A single top-level agent config file. (3) Directory-scoped inheritance with explicit rules. |
| **Rationale** | Directory-scoped inheritance mirrors how `.gitignore`, `.editorconfig`, and similar tools work — familiar pattern, scales naturally as the repo grows, and allows governance to be layered without a monolithic rule file. |
| **Driver** | Human-initiated, jointly refined |
| **Trigger** | The human recognized an implicit pattern and asked whether it should be explicit. A meta-observation about our own tooling. |
| **Commit** | `a9b8040` |

---

### D-005 — Audience Separation (Human vs. Agent Docs)

| Field | Value |
|---|---|
| **Decision** | `README.md` targets humans. `README-agent.md` targets LLM agents. Never mix audiences. |
| **Context** | Early on, architecture docs included both human-readable narrative and agent-specific directives in the same files, creating ambiguity about tone and audience. |
| **Rationale** | Agents need precision, cross-references, and compliance rules. Humans need narrative, context, and onboarding. Mixing audiences dilutes both. Separation lets each document optimize for its reader. |
| **Driver** | Joint |
| **Trigger** | Observation — the architecture doc header says "LLM-Agent Focused" but the README.md is clearly for humans. The split crystallized when we created the first `README-agent.md`. |
| **Commit** | `52f612f`, `3b07fef` |

---

### D-006 — Shell Script Standards (--help, main(), set -euo pipefail)

| Field | Value |
|---|---|
| **Decision** | All scripts must support `--help`/`-h`, use the `main()` function pattern, and start with `set -euo pipefail`. Codified in shell-scripting guidance. |
| **Context** | Scripts were being created ad hoc. Needed a baseline for consistency, safety, and discoverability. |
| **Rationale** | `--help` makes scripts self-documenting. `main()` prevents global-scope side effects. `set -euo pipefail` catches errors early instead of silently continuing. These are cheap conventions with outsized reliability payoff. |
| **Driver** | Agent-proposed, human-approved |
| **Trigger** | The agent noticed inconsistency across scripts while adding `--help` support. Proposed codifying it as guidance. |
| **Commit** | `bd4be38`, `0685c46` |

---

### D-007 — Checklist as Central Task Tracker

| Field | Value |
|---|---|
| **Decision** | Use `ai_stack_checklist.md` as the master task tracker, organized by blockers, deferrables, and future features. |
| **Context** | Implementation tasks were embedded in the architecture doc's "Implementation Tracking" section. As the list grew, it cluttered the design document. |
| **Rationale** | A dedicated checklist file keeps task state separate from design rationale. It can be updated frequently without touching the architecture doc. The blocker/deferrable/future split provides clear prioritization. |
| **Driver** | Joint |
| **Trigger** | The architecture doc was getting unwieldy with inline task tracking. |
| **Commit** | `75caab2` |

---

### D-008 — meta.md as Collaboration & Decision Record

| Field | Value |
|---|---|
| **Decision** | Create `docs/meta.md` as a collaboration and decision record, targeting LLM agents, with auto-identification directives. |
| **Context** | Decisions were being made through conversation but only recorded indirectly in commit messages. No record of *why* we decided things, who drove them, or what patterns our collaboration produces. |
| **Rationale** | Commit messages capture *what* changed but not the decision process. A meta document lets the agent learn from past collaboration patterns and apply them forward. It also creates a feedback loop — by recording how we work, we can improve how we work. |
| **Driver** | Human-initiated |
| **Trigger** | The human recognized that our process itself is worth documenting and optimizing. A lateral leap from "let's document decisions" to "let's document how we decide." |
| **Commit** | `edc14d9` |

---

### D-009 — Meta File Separation of Concerns

| Field | Value |
|---|---|
| **Decision** | Split meta.md into four files by concern: `meta.md` (active directives/workflow), `meta_decisions.md` (decision record), `meta_dynamics.md` (collaboration dynamics + lateral thinking), `meta_metrics.md` (review log + derived metrics). |
| **Context** | meta.md was ~270 lines and growing. It mixed always-read directives with append-only historical data. Different sections had different access patterns (read every session vs. reference on demand vs. append at triggers) and different growth rates. |
| **Options Considered** | (1) Keep one file, manage length. (2) Split into two (directives vs. data). (3) Split by concern into four files matching access pattern and growth rate. |
| **Rationale** | Applied separation of concerns: each file has a single reason to change, a clear access pattern, and a predictable growth trajectory. meta.md stays small as the always-read "operating system." Historical/accumulating content moves to files that are read when the workflow says to read them, not on every session. This is the same principle that drove D-001 (three-doc split) and D-003 (three files per component) — the human recognizes it as a reusable pattern. |
| **Driver** | Human-initiated, jointly refined |
| **Trigger** | The agent flagged meta.md's length as a scaling pressure point; the human proposed the split and named the underlying principle ("applied separation of concerns"). |
| **Commit** | *(this commit)* |
