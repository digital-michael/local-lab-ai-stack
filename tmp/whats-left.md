# Retrofit: What's Left — local-lab-ai-stack

**Created:** 2026-06-22
**Context:** llm-agent-framework retrofit in progress. Risks 1–6 resolved. Remaining items below.

---

## Decision Needed Before Step 4

### Where do the enforcement rules from `README-agent.md` go?

`./tmp/README-agent.md` §§6–12 contains project hard rules with no current home:

| Section | Rule |
|---|---|
| §6 | Credentials — no secrets in any tracked file, ever |
| §7 | Commit hygiene — no AI attribution without explicit user request |
| §8 | Script rules — shebang, `set -euo pipefail`, `main()` pattern, `--help`, `jq` for all config I/O |
| §9 | Config rules — `config.json` is SSOT; changes via `configure.sh generate-quadlets` |
| §10 | Doc rules — no duplication, component library 3-file structure, skill SKILL.md convention |
| §11 | Deviation policy — note in commit, update guidance file if new standard |
| §12 | File naming conventions — README.md / README-agent.md / best_practices.md / security.md / guidance.md |

**Options:**
1. Inline in `docs/governance/README.md` — simplest; one file for load order + enforcement
2. New file `docs/governance/project-rules.md` — cleaner separation of concerns
3. Promote to `llm-agent-domains/cts/governance-overlay.md` — only if applicable cross-CTS-project (most rules are local-lab-ai-stack-specific; §7 commit hygiene applies broadly)

---

## Remaining Retrofit Steps

### Step 3 — Scaffold `.llm-framework.yml` (project root)

```yaml
infrastructure: /home/3pdx7/Documents/Entities/frameworks/llm-agent-framework
team: /home/3pdx7/Documents/Entities/frameworks/llm-agent-domains/cts
```

### Step 4 — Create `docs/governance/` (4 files)

| File | Content |
|---|---|
| `docs/governance/README.md` | Session-start load order (mirrors domain entry); index of what to read and where; enforcement rules (pending decision above) |
| `docs/governance/lessons-learned.md` | Framework-format index of existing lessons; see dynamics.md and component library for detail |
| `docs/governance/agent-assignment.md` | Copy from `llm-agent-framework/templates/agent-assignment.md` |
| `docs/governance/session-context.md` | Copy from `llm-agent-framework/templates/session-context.md` |

### Step 5 — Populate `docs/governance/lessons-learned.md`

Index — do not duplicate — existing lessons:
- Primary source: `llm-agent-domains/meta/local-lab-ai-stack/dynamics.md` (I-1..I-19, E-1..E-7, L-1..L-13)
- Secondary source: per-session entries in `llm-agent-domains/meta/local-lab-ai-stack/review_log.md`
- Tertiary source: `docs/library/framework_components/` guidance files (component-level lessons already in place)

Framework format has three sections: LLM Agent / Technologist / Tech Stack. Promote recurrent or framework-relevant lessons into those sections; leave project-specific detail in the source files.

### Step 5b — Architecture Addendum

Add `## Current-State Package Map` section to `docs/ai_stack_blueprint/ai_stack_architecture.md`. Do not rewrite the existing doc — addendum only.

Required subsections:
- Package-to-layer mapping table (services/, scripts/, configs/, testing/, docs/)
- Packages with known risks (e.g., god-object candidates, boundary violations)
- External Reusable Components table (`llm-agent-framework`, `llm-agent-framework-tools`)
- Composition rules if any base types must be composed by all implementations

### Step 7 — Retrospective

Log in `docs/governance/lessons-learned.md` under a `## Retrofit Session — 2026-06-22` heading:
- What was created correctly (domain entry, meta migration, path fixes, protocol update)
- What was corrected (llm-agent-local-2 → local-lab-ai-stack renames, broken /memories/ references)
- What was deferred (enforcement rules placement, architecture addendum)

---

## Reference

| What | Where |
|---|---|
| Domain session-start | `llm-agent-domains/cts/local-lab-ai-stack/README.md` |
| Retrofit workflow | `llm-agent-framework/governance/workflows/retrofit-existing-project.md` |
| Hard rules under review | `./tmp/README-agent.md` §§6–12 |
| Meta review log | `llm-agent-domains/meta/local-lab-ai-stack/review_log.md` |
| Meta dynamics | `llm-agent-domains/meta/local-lab-ai-stack/dynamics.md` |
| Framework templates | `llm-agent-framework/templates/` |
