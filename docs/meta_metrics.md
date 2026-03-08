# Meta Metrics — Reinforcement Workflow Performance
**Last Updated:** 2026-03-08 UTC
**Target Audience:** LLM Agents

---

## Purpose

This file tracks the raw performance data of the reinforcement workflow defined in [meta.md](meta.md). It exists as a separate file to keep meta.md focused on process and decisions while this file accumulates the data needed to evaluate whether the workflow actually works.

**Phase 1 (current):** Collect one row per significant-commit trigger. Low overhead, raw data only.
**Phase 2 (after ~10–15 entries):** Derive aggregate metrics from the log — driver distribution trends, level distribution, whether applied focus items correlate with observed improvements. Phase 2 structure will be added when the data warrants it.

---

## Table of Contents

1. [Review Log](#1-review-log)
2. [Derived Metrics](#2-derived-metrics-phase-2)

---

# 1 Review Log

One row per reinforcement workflow trigger. The agent appends a row after completing steps 1–4 of the workflow (Retrieve → Apply → Observe outcome → Update record).

| Date | Trigger Commit | Interaction Level | Focus Item Applied | Outcome Observed | Decisions Recorded | Lateral Ideas Surfaced | Driver |
|---|---|---|---|---|---|---|---|
| *(no entries yet)* | | | | | | | |

### Field Definitions

| Field | Description |
|---|---|
| **Date** | Date of the review (YYYY-MM-DD) |
| **Trigger Commit** | Short hash and subject of the commit that triggered the review |
| **Interaction Level** | The level (0–3) at which the work was conducted |
| **Focus Item Applied** | Which weakness (W-n) or improvement (I-n) from meta.md Section 2 was selected to counteract |
| **Outcome Observed** | Did the applied focus visibly affect behavior? `yes` / `no` / `unclear` + one sentence |
| **Decisions Recorded** | Count of new D-entries added to meta.md this cycle |
| **Lateral Ideas Surfaced** | Count of new L-entries added to meta.md this cycle |
| **Driver** | Who initiated the review: `human` (prompted) or `agent` (self-initiated at trigger) |

---

# 2 Derived Metrics (Phase 2)

This section will be populated after the Review Log accumulates ~10–15 entries. Metrics to derive will include:

- **Driver distribution over time** — is the agent initiating more reviews as the workflow matures?
- **Level distribution** — what proportion of work happens at each interaction level?
- **Focus-to-outcome correlation** — do applied focus items (W-n, I-n) produce "yes" outcomes, or do they stay "unclear"?
- **Agent-initiated decision trend** — is the count of agent-driven decisions (D-entries with driver=agent) increasing?
- **Lateral idea rate at Level 3** — does the agent surface more ideas during architectural work?
- **Weakness lifecycle** — do recorded weaknesses eventually move to "improved" or do they persist indefinitely?

These metrics answer the core question: **does exercising this workflow produce measurably different behavior over time?**

Phase 2 structure will be designed based on what the actual data reveals, not on predictions.
