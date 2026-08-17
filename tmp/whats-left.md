# Retrofit: What's Left — local-lab-ai-stack

**Created:** 2026-06-22 (CENTAURI, first attempt)
**Updated:** 2026-07-29 (this Mac, retrofit completed against the plan below)

---

## Status: Retrofit Complete (this workstation), One Real Gap Remains

The 2026-06-22 plan below was carried out on 2026-07-29, with one change: domain is
`photon-datum`, not `cts` (this repo doesn't fit `cts`'s "Go desktop apps" scope; see
`docs/governance/lessons-learned.md` retrospective). All path references now use the portable
`~/Documents/Entities/frameworks/...` form instead of the CENTAURI-only absolute path.

**Done:**
- `.llm-framework.yml` scaffolded (photon-datum domain)
- `docs/governance/{README.md, lessons-learned.md, agent-assignment.md, session-context.md}` created
- Enforcement rules from `README-agent.md` §§6–12 kept in `README-agent.md` itself (option 1 variant — restored to root rather than duplicated into `docs/governance/README.md`)
- Architecture addendum: `## 16 Current-State Package Map` added to `ai_stack_architecture.md`
- Retrospective logged in `docs/governance/lessons-learned.md`

**⚠ NOT done — real content gap, not just a path fix:**

The `dynamics.md` (I-1..I-19, E-1..E-7, L-1..L-13) and `review_log.md` files referenced below as
the primary/secondary lessons sources live under a `meta` domain that was **never committed to
the shared `llm-agent-domains` git repo** — they exist only on CENTAURI's local disk (uncommitted
or on an unmerged branch). This machine has no copy of them, so none of that substance made it
into `docs/governance/lessons-learned.md`. **Next time CENTAURI is used:** locate those files,
decide what's still relevant, and either commit them properly into `photon-datum/` or fold the
extracted lessons into `docs/governance/lessons-learned.md` directly. Until then, treat the
lessons index in this repo as incomplete for anything predating 2026-06-22.

---

## Original Plan (2026-06-22, for reference)

### Decision Needed Before Step 4 — RESOLVED

Enforcement rules from `README-agent.md` §§6–12 stayed in `README-agent.md` at the project root
(option 1 variant) rather than moving into `docs/governance/README.md` — they're directive rules
an agent needs before touching any file, not enrollment bookkeeping.

### Step 3 — `.llm-framework.yml` — DONE (photon-datum, not cts)

### Step 4 — `docs/governance/` (4 files) — DONE

### Step 5 — Populate `lessons-learned.md` — PARTIAL

Indexed everything available on this machine (`docs/library/framework_components/*/lessons_learned.md`,
`docs/wip/plan.md`, `docs/decisions.md`). Could not reach `llm-agent-domains/meta/local-lab-ai-stack/{dynamics,review_log}.md` — see gap above.

### Step 5b — Architecture Addendum — DONE

### Step 7 — Retrospective — DONE

See `docs/governance/lessons-learned.md` for the full 2026-07-29 retrospective entry.

---

## Reference

| What | Where |
|---|---|
| Domain session-start | `~/Documents/Entities/frameworks/llm-agent-domains/photon-datum/local-lab-ai-stack/README.md` |
| Retrofit workflow | `~/Documents/Entities/frameworks/llm-agent-framework/governance/workflows/retrofit-existing-project.md` |
| Enforcement rules | `README-agent.md` §§6–12 (project root) |
| Meta review log (CENTAURI-local, ungathered) | `llm-agent-domains/meta/local-lab-ai-stack/review_log.md` |
| Meta dynamics (CENTAURI-local, ungathered) | `llm-agent-domains/meta/local-lab-ai-stack/dynamics.md` |
| Framework templates | `~/Documents/Entities/frameworks/llm-agent-framework/templates/` |
