# Meta — Collaboration & Decision Record
**Last Updated:** 2026-03-08 UTC
**Target Audience:** LLM Agents

---

## Purpose

This document records how the human operator and LLM agent collaborate, make decisions, and improve their shared process. It is a living document — both the human and the agent are expected to maintain it.

**Auto-identification directive:** When working on any task in this repository, the agent should proactively identify aspects that belong in this document and propose additions. This includes but is not limited to: new decisions made, collaboration patterns observed, process improvements discovered, lateral connections to adjacent ideas, and moments where the pairing dynamic produced something neither party would have reached alone. If something feels like it should be recorded here, surface it.

---

## Reinforcement Workflow

This document is part of a closed-loop learning cycle. Without the workflow below, observations get recorded but never alter behavior — a recording cycle, not a reinforcement cycle. The stages are:

```
Observe → Record → Retrieve → Apply → Observe outcome → Update record
   ↑                                                          │
   └──────────────────────────────────────────────────────────┘
```

### Triggers

This workflow is **not** run every session. The human typically works within a single context window for extended periods (weeks to months). Review is triggered by **significant commits** — commits that materialize a decision, complete a milestone, or change the system's shape. Minor fixes, typo corrections, and housekeeping commits do not trigger review.

The agent should use judgment: if a commit would warrant a new entry in the Decision Log (Section 1.2), it's significant enough to trigger the workflow.

### What the Agent Does at Each Trigger

1. **Retrieve.** Re-read the Collaboration Dynamics (Section 2) — specifically the weakness table and any active focus items.
2. **Apply.** Select one recorded weakness or improvement to actively counteract during the current work. State which one and why, briefly, when beginning the task.
3. **Observe outcome.** After the work is done, note whether the applied focus had a visible effect.
4. **Update record.** Add or update entries in the relevant tables: new decisions, changed dynamics, status updates on weaknesses or lateral ideas. Then append a row to the Review Log in [meta_metrics.md](meta_metrics.md).

### Interaction Levels

Not all work benefits equally from agent initiative. The following levels define how much the agent should interrupt, question, or proactively contribute — scaled by the type of work underway. The agent should identify which level applies and operate accordingly.

| Level | Label | When It Applies | Agent Behavior |
|---|---|---|---|
| **0** | **Execute** | Implementation, scheduling, mechanical tasks (writing quadlets, generating configs, applying known patterns) | Do the work. Do not interrupt with suggestions, lateral ideas, or meta-observations. Record decisions silently in meta.md if they arise, but don't discuss them unless asked. |
| **1** | **Inform** | Planning, task breakdown, checklist work, documentation updates | Do the work. Flag deviations from recorded guidance. Note observations for meta.md but present them at natural breakpoints (e.g., end of a task), not inline. Minimal interruption. |
| **2** | **Advise** | Design discussions, evaluating trade-offs, reviewing architecture, selecting between options | Proactively surface relevant precedents from the Decision Log. Offer alternatives. Push back on decisions that contradict recorded rationale. Present lateral observations when relevant. |
| **3** | **Challenge** | Architectural design, service selection, system-shaping decisions, new component introductions | Question assumptions. Propose lateral connections actively. Surface adjacent concepts, features, and risks unprompted. Challenge the framing of the problem, not just the solution. Flag when a decision feels under-examined. |

**Default level:** 1 (Inform). The agent should escalate to a higher level when the work context warrants it, and state the level shift explicitly (e.g., "This is an architectural decision — operating at Level 3").

**Human override:** The human can set the level explicitly at any time (e.g., "Level 0 for this task"). The override applies until the human changes it or the task ends.

### Lateral Thinking Scope

Lateral thinking — surfacing adjacent concepts, unexpected connections, and tangential ideas — is **most valuable** during:
- Architectural design discussions (Level 3)
- Service selection and component evaluation (Level 3)
- Trade-off analysis (Level 2)

It has **moderate value** during:
- Planning and task breakdown (Level 1) — note but don't dwell

It has **low value** during:
- Scheduling and implementation (Level 0) — suppress unless critical

The agent should calibrate its lateral output to the current interaction level. At Level 0, lateral ideas are not surfaced. At Level 3, they are actively pursued.

---

## Table of Contents

1. [Decisions](#1-decisions)
2. [Collaboration Dynamics](#2-collaboration-dynamics)
3. [Lateral Thinking](#3-lateral-thinking)

---

# 1 Decisions

Decisions emerge from collaboration. This section records them in two parts: the retrospective (seeded from project history), and the framework for recording future decisions.

## 1.1 Decision Record Framework

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

## 1.2 Decision Log

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

### D-008 — This Document (meta.md)

| Field | Value |
|---|---|
| **Decision** | Create `docs/meta.md` as a collaboration and decision record, targeting LLM agents, with auto-identification directives. |
| **Context** | Decisions were being made through conversation but only recorded indirectly in commit messages. No record of *why* we decided things, who drove them, or what patterns our collaboration produces. |
| **Rationale** | Commit messages capture *what* changed but not the decision process. A meta document lets the agent learn from past collaboration patterns and apply them forward. It also creates a feedback loop — by recording how we work, we can improve how we work. |
| **Driver** | Human-initiated |
| **Trigger** | The human recognized that our process itself is worth documenting and optimizing. A lateral leap from "let's document decisions" to "let's document how we decide." |
| **Commit** | *(this commit)* |

---

# 2 Collaboration Dynamics

This section records observations about how the human and agent work together. It tracks strengths, weaknesses, improvements, and breakthrough moments.

## 2.1 Strengths

| # | Observation |
|---|---|
| S-1 | **Human provides vision; agent provides structure.** The human frames goals loosely and directionally ("I want by-default rules"). The agent translates that into specifics (four numbered rules with inheritance semantics). This division works well — neither side bottlenecks the other. |
| S-2 | **Human catches meta-patterns.** The human excels at noticing when an implicit convention should become explicit (D-004), or when the process itself needs attention (D-008). The agent is less likely to initiate this kind of meta-observation unprompted. |
| S-3 | **Agent can scaffold at scale.** The component library (42 files across 14 directories) was created in a single pass. The agent's ability to generate consistent, structured output at volume is a force multiplier for the human's design intent. |
| S-4 | **Rapid iteration on framing.** The human proposes a concept; the agent asks clarifying questions; the human answers concisely; the agent builds. This loop is tight and efficient — typically one round of questions before execution. |
| S-5 | **Human steers pragmatism.** When the agent could over-engineer (e.g., adding excessive fields to the decision framework), the human sets the bar: "strike a balance between value and pragmatism/cost." This keeps output grounded. |

## 2.2 Weaknesses

| # | Observation |
|---|---|
| W-1 | **Decisions were invisible.** Until this document, the reasoning behind decisions lived only in conversation context that evaporated between sessions. The agent couldn't learn from or reference past decisions. |
| W-2 | **Agent doesn't challenge enough.** The agent tends to execute the human's direction efficiently but rarely pushes back or proposes fundamentally different approaches. More constructive friction could surface better solutions. |
| W-3 | **No persistent model of human priorities.** The agent re-discovers the human's preferences each session (pragmatism over perfection, layered governance, audience separation). There's no mechanism to carry these forward without explicit repetition. |
| W-4 | **Lateral connections are underexploited.** The agent focuses on the stated task and doesn't often say "this reminds me of X, which could apply here." The human has to prompt lateral thinking explicitly. |

## 2.3 Improvements Made

| # | Improvement | Triggered By |
|---|---|---|
| I-1 | Created decision record framework (this file) | W-1 — decisions were invisible |
| I-2 | Codified the `README-agent.md` convention from implicit to explicit | S-2 — human spotted the meta-pattern |
| I-3 | Established auto-identification directive in this document's Purpose | W-4 — agent should surface meta-observations proactively |

## 2.4 Eureka Moments

These are moments where the collaboration produced something neither party would have reached alone.

| # | Moment | What Happened |
|---|---|---|
| E-1 | **Three-doc split (D-001)** | The agent was fixing errors in a monolithic doc and kept running into cross-concern conflicts. The human's single-source-of-truth principle, combined with the agent's structural pain, produced the split. Neither the principle alone nor the editing pain alone would have generated the same result. |
| E-2 | **README-agent.md as an inheritance pattern (D-004)** | Started as "let's add agent instructions." The human asked "should we formalize this?" The agent mapped it to `.gitignore`-style directory scoping. The result — a general-purpose governance inheritance pattern — was more powerful than either the initial request or the agent's first implementation. |
| E-3 | **Meta-documentation as a feedback loop (D-008)** | The human asked for a decision record. Through the clarifying questions, the scope expanded to include collaboration dynamics, lateral thinking, and process improvement. The document became self-referential: it records the process *and* improves it by existing. |

---

# 3 Lateral Thinking

This section captures adjacent concepts, unexpected connections, and ideas that emerged tangentially from stated work. The agent is encouraged to surface these proactively during any task.

**Directive:** Lateral thinking output is governed by the Interaction Levels defined in the Reinforcement Workflow section above. At Level 0–1, suppress or defer. At Level 2, surface when relevant. At Level 3, actively pursue. The agent should tag each entry with the interaction level at which it was surfaced.

## 3.1 Adjacent Ideas Log

| # | Source Task | Lateral Observation | Status |
|---|---|---|---|
| L-1 | D-004 (README-agent.md convention) | The directory-scoped inheritance pattern could generalize beyond agent directives. Other file conventions (e.g., `OWNERS`, `CONVENTIONS.md`) could follow the same most-specific-wins rule, creating a unified "directory metadata" system. | Noted |
| L-2 | D-008 (this document) | If the agent auto-identifies meta.md-worthy content, it's effectively doing continuous retrospectives. This is an agile practice (sprint retros) applied to human-agent pairing — but without the ceremony cost. Could be a model for how other teams use LLM agents. | Noted |
| L-3 | D-002 (JSON config SSOT) | The `config.json` → `configure.sh` → quadlet generation pipeline is a simple form of Infrastructure as Code. If the repo grows to multi-node, this pattern could evolve into a declarative config layer (like Nix or Terraform) without starting from scratch. | Noted |
| L-4 | Component library (D-003) | The three-file pattern (best_practices / security / guidance) could be templated and applied to non-component domains — e.g., `docs/library/processes/deployment/`, `docs/library/processes/backup/`. The pattern isn't component-specific; it's concern-specific. | Noted |
