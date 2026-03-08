# Meta — Collaboration Directives
**Last Updated:** 2026-03-08 UTC
**Target Audience:** LLM Agents

---

## Purpose

This is the active operating document for human-agent collaboration on this repository. It defines the reinforcement workflow, interaction levels, and lateral thinking scope. It is read every session.

Historical and accumulating content lives in dedicated files:

| File | Content | Access Pattern |
|---|---|---|
| [meta_decisions.md](meta_decisions.md) | Decision record framework and log (D-001+) | Reference on demand; append per decision |
| [meta_dynamics.md](meta_dynamics.md) | Strengths, weaknesses, improvements, eureka moments, lateral ideas | Read at workflow triggers; update periodically |
| [meta_metrics.md](meta_metrics.md) | Review log and derived metrics | Append at workflow triggers |

**Auto-identification directive:** When working on any task in this repository, the agent should proactively identify aspects that belong in the meta files and propose additions. This includes new decisions, collaboration patterns, process improvements, lateral connections, and moments where the pairing dynamic produced something neither party would have reached alone.

---

## Reinforcement Workflow

This document is part of a closed-loop learning cycle. Without the workflow below, observations get recorded but never alter behavior — a recording cycle, not a reinforcement cycle. The stages are:

```
Observe → Record → Retrieve → Apply → Observe outcome → Update record
   ↑                                                          │
   └──────────────────────────────────────────────────────────┘
```

### Triggers

The **primary trigger** is explicit human direction. The human sets the interaction level for a task (e.g., "Level 3 on this") and can invoke the full workflow at any time.

The **secondary trigger** is agent-initiated at significant commits — commits that materialize a decision, complete a milestone, or change the system's shape. Minor fixes, typo corrections, and housekeeping commits do not trigger review. The agent should use judgment: if a commit would warrant a new entry in the Decision Log ([meta_decisions.md](meta_decisions.md)), it's significant enough to trigger the workflow.

The human typically works within a single context window for extended periods (weeks to months). The workflow is designed for this cadence — it is not run every session or on a fixed schedule.

### What the Agent Does at Each Trigger

1. **Retrieve.** Re-read [meta_dynamics.md](meta_dynamics.md) — specifically the weakness table and any active focus items.
2. **Apply.** Select one recorded weakness or improvement to actively counteract during the current work. State which one and why, briefly, when beginning the task.
3. **Observe outcome.** After the work is done, note whether the applied focus had a visible effect.
4. **Update record.** Add or update entries in the relevant files: new decisions in [meta_decisions.md](meta_decisions.md), changed dynamics in [meta_dynamics.md](meta_dynamics.md), status updates on weaknesses or lateral ideas. Then append a row to the Review Log in [meta_metrics.md](meta_metrics.md).

### Interaction Levels

Not all work benefits equally from agent initiative. The following levels define how much the agent should interrupt, question, or proactively contribute — scaled by the type of work underway. The agent should identify which level applies and operate accordingly.

| Level | Label | When It Applies | Agent Behavior |
|---|---|---|---|
| **0** | **Execute** | Implementation, scheduling, mechanical tasks (writing quadlets, generating configs, applying known patterns) | Do the work. Do not interrupt with suggestions, lateral ideas, or meta-observations. Record decisions silently if they arise, but don't discuss them unless asked. |
| **1** | **Inform** | Planning, task breakdown, checklist work, documentation updates | Do the work. Flag deviations from recorded guidance. Note observations but present them at natural breakpoints (e.g., end of a task), not inline. Minimal interruption. |
| **2** | **Advise** | Design discussions, evaluating trade-offs, reviewing architecture, selecting between options | Proactively surface relevant precedents from the Decision Log. Offer alternatives. Push back on decisions that contradict recorded rationale. Present lateral observations when relevant. |
| **3** | **Challenge** | Architectural design, service selection, system-shaping decisions, new component introductions | Question assumptions. Propose lateral connections actively. Surface adjacent concepts, features, and risks unprompted. Challenge the framing of the problem, not just the solution. Flag when a decision feels under-examined. |

**Default level:** 1 (Inform). The agent should escalate to a higher level when the work context warrants it, and state the level shift explicitly (e.g., "This is an architectural decision — operating at Level 3").

**Human override:** The human can set the level explicitly at any time (e.g., "Level 0 for this task" or "Level 3 on this"). The override applies until the human changes it or the task ends.

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

### Reusable Principles

The following principles have been identified through collaboration and should be recognized and applied proactively by the agent:

| Principle | Description | Symptoms That Trigger It | Precedents |
|---|---|---|---|
| **Applied separation of concerns** | When a single artifact serves multiple purposes, audiences, or access patterns, split it by concern. Each resulting artifact should have one reason to change. | A file mixing stable and volatile content; a document serving multiple audiences; an artifact with multiple access patterns or growth rates. | D-001, D-003, D-005, D-009 |

This table will grow as new principles are named. The agent should watch for recurring patterns across decisions and propose additions.
