# Copilot Workspace Instructions — llm-agent-local-2

## Session Protocol: Locked-In

At the start of every new conversation, before responding to the user's first request, you MUST:

1. **Determine context type:** `user-request` · `session-resume` · `delegation` · `unknown`
2. **Select a profile** based on task scope (see `/memories/locked-in.md` for profile definitions):
   - Single narrow task / bug fix → `minimal`
   - Standard work session → `standard`
   - Architecture, design, L3/L4, cross-cutting → `full`
   - Invoked as subagent → `subagent` (confirm what parent injected; do not load autonomously)
3. **Load context** for the selected profile:
   - `minimal`: scan `/memories/repo/lessons-learned.md` for sections relevant to the task
   - `standard`: above + read `docs/meta_local/review_log.md` (last 20 lines) + check active todo list
   - `full`: above + read `docs/meta_local/decisions.md` (last 30 lines) + `docs/meta/meta_dynamics.md`
4. **Emit the declaration** as the first block of your first response:

```
🔒 Locked-In | <context-type> | profile:<name>
   loaded: <aspect> ✓  <aspect> ✓  ...
```

or if context could not be loaded:

```
⚠ Not Locked-In | <context-type> | profile:none
   missing: <aspect>  — [brief reason]
```

**Do not repeat the declaration on subsequent turns.** Load once; do not reload unless the user explicitly requests it or a significant mid-session state change is detected. Note staleness inline as `[may be stale — loaded N turns ago]` rather than silently reloading.

For delegation specifics (parent obligations, subagent receipt format, gap escalation), see `/memories/locked-in-delegation.md`.

Full protocol definition (tooling-agnostic): `docs/meta/meta_context_protocol.md`.

---

## This Repository

- **Default profile for this repo:** `standard`
- **Lessons learned:** `/memories/repo/lessons-learned.md`
- **Meta review log:** `docs/meta_local/review_log.md`
- **Active decisions:** `docs/meta_local/decisions.md`
- **Agent governance:** `README-agent.md` (read before modifying any file)
- **Machine-readable SSOT:** `configs/config.json`

---

## General Directives

- Read `README-agent.md` before modifying any file in this repo.
- When a task touches a specific component, read all three files in `docs/library/framework_components/<component>/` first.
- Record new bugs, workarounds, and lessons in `/memories/repo/lessons-learned.md`.
- Keep todos active: mark in-progress before starting, completed immediately after finishing.
- Prefer `standard` profile. Upgrade to `full` when the work shifts from mechanical to design-heavy; suggest model upgrade (Opus) at the same time.
