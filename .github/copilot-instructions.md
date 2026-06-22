# Copilot Workspace Instructions — local-lab-ai-stack

## Session Protocol: Locked-In

At the start of every new conversation, before responding to the user's first request, you MUST:

1. **Determine context type:** `user-request` · `session-resume` · `delegation` · `unknown`
2. **Select a profile** based on task scope (see `/home/3pdx7/Documents/Entities/frameworks/llm-agent-framework/governance/agent-context-protocol.md` for profile definitions):
   - Single narrow task / bug fix → `minimal`
   - Standard work session → `standard`
   - Architecture, design, L3/L4, cross-cutting → `full`
   - Invoked as subagent → `subagent` (confirm what parent injected; do not load autonomously)
3. **Load context** for the selected profile:
   - `minimal`: scan `docs/governance/lessons-learned.md` for sections relevant to the task
   - `standard`: above + read `/home/3pdx7/Documents/Entities/frameworks/llm-agent-domains/meta/local-lab-ai-stack/review_log.md` (last 20 lines) + check active todo list
   - `full`: above + read `docs/decisions.md` (last 30 lines) + `/home/3pdx7/Documents/Entities/frameworks/llm-agent-domains/meta/local-lab-ai-stack/dynamics.md`
4. **Emit the declaration** as the first block of your first response:

```
Locked-In | <context-type> | profile:<name>
   loaded: <aspect> [x]  <aspect> [x]  ...
```

or if context could not be loaded:

```
Not Locked-In | <context-type> | profile:none
   missing: <aspect>  — [brief reason]
```

**Do not repeat the declaration on subsequent turns.** Load once; do not reload unless the user explicitly requests it or a significant mid-session state change is detected. Note staleness inline as `[may be stale — loaded N turns ago]` rather than silently reloading.

For delegation specifics (parent obligations, subagent receipt format, gap escalation), see `/home/3pdx7/Documents/Entities/frameworks/llm-agent-framework/governance/agent-context-protocol.md`.

Full protocol definition: `/home/3pdx7/Documents/Entities/frameworks/llm-agent-framework/governance/agent-context-protocol.md`.

---

## Session Protocol: Flush-to-Disk

The agent cannot predict compaction. Durable knowledge MUST be written to disk proactively — do not rely on the conversation summary to carry architectural decisions, lessons, or status changes forward.

### Narrow Flush — trigger immediately, no announcement

| What happened | Write to |
|---|---|
| New architecture decision reached | `docs/decisions.md` |
| BL item status changes (started / blocked / done) | `docs/wip/plan.md` |
| Bug, workaround, or non-obvious lesson discovered | `docs/governance/lessons-learned.md` |
| New operational procedure established or changed | `output/CENTAURI-playbook.md` |
| Feature shipped or scope changed | `docs/features.md` |

Write the narrow flush inline as part of completing the work — not as a separate step.

### Broad Flush — required before every git commit

Before staging any commit, verify all of the following are current. Announce: `"Flushing session state before commit..."` and list which files were updated.

1. `docs/decisions.md` — all decisions made in session recorded
2. `docs/wip/plan.md` — all BL status changes reflected
3. `/home/3pdx7/Documents/Entities/frameworks/llm-agent-domains/meta/local-lab-ai-stack/review_log.md` — session entry written (what was done, decided, and is pending)
4. `docs/governance/lessons-learned.md` — all new lessons captured
5. `output/CENTAURI-playbook.md` — new procedures or updated runbooks included
6. `docs/features.md` — if features shipped or changed

**Never commit without a broad flush.** If the broad flush surfaces new content, include those files in the commit.

---

## This Repository

- **Default profile for this repo:** `standard`
- **Lessons learned:** `docs/governance/lessons-learned.md`
- **Meta review log:** `/home/3pdx7/Documents/Entities/frameworks/llm-agent-domains/meta/local-lab-ai-stack/review_log.md`
- **Active decisions:** `docs/decisions.md`
- **Machine-readable SSOT:** `configs/config.json`
- **Session-start load order:** `/home/3pdx7/Documents/Entities/frameworks/llm-agent-domains/cts/local-lab-ai-stack/README.md`

---

## General Directives

- Follow the session-start load order in `/home/3pdx7/Documents/Entities/frameworks/llm-agent-domains/cts/local-lab-ai-stack/README.md` before modifying any file in this repo.
- When a task touches a specific component, read all three files in `docs/library/framework_components/<component>/` first.
- Record new bugs, workarounds, and lessons in `docs/governance/lessons-learned.md`.
- Keep todos active: mark in-progress before starting, completed immediately after finishing.
- Prefer `standard` profile. Upgrade to `full` when the work shifts from mechanical to design-heavy; suggest model upgrade (Opus) at the same time.

## Commit Hygiene — Hard Rule

Git commit messages MUST contain only content explicitly provided or approved by the operator/user.

**Prohibited without explicit user request:**
- AI attribution lines (`Co-authored-by: GitHub Copilot`, `Created by Claude`, `Generated by ...`, or any equivalent)
- Hyperlinks to AI products, services, or vendor documentation
- Any advertising, promotional, or branding content injected by a model or tool

Write commit messages as if the human wrote them: type, scope, description, and body drawn entirely from the work done. Nothing else.
