# Project Governance — local-lab-ai-stack

> Index of what to read and where, for any LLM agent operating on this repository.
> This file does not contain behavior rules itself — those live in the framework, the
> photon-datum domain profile, and this repo's per-repo context file. This is the map.

---

## Enrollment

This project is enrolled in the LLM Agent Collaboration Framework, Team mode.

- **Infrastructure:** `~/Documents/Entities/frameworks/llm-agent-framework` (read-only)
- **Domain:** `~/Documents/Entities/frameworks/llm-agent-domains/photon-datum`
- **Config:** `.llm-framework.yml` at project root

## Multi-Workstation Convention

This project is worked on from more than one workstation (CENTAURI, TC25, and others as added).
All framework-family repos must be cloned/placed at the **same path relative to `$HOME` on every
workstation**, regardless of OS or username:

```
~/Documents/Entities/frameworks/llm-agent-framework
~/Documents/Entities/frameworks/llm-agent-domains
~/Documents/Entities/frameworks/llm-agent-articles          (optional — reference material only)
~/Documents/Entities/frameworks/llm-agent-framework-tools   (optional — not required to operate this repo)
```

Only the first two are read as part of this project's session-start load order. The other two
are grouped here for workstation-setup consistency, not because this repo depends on them.

**Before opening this project on a new workstation:** clone both repos to that exact location
first. Every governance path in this project (and in the domain profile) is written as a
tilde-relative path against that convention — nothing needs editing per-machine once the repos
are in place. CENTAURI already used this layout natively; only this Mac needed a physical move
to conform (2026-07-29).

---

## This Repo's Own Location

`local-lab-ai-stack` (and the unrelated `cortex` project) are not framework repos — they are
photon-datum project repos, and their real location is:

```
~/Documents/Entities/Photon Datum/local-lab-ai-stack
~/Documents/Entities/Photon Datum/cortex
```

`~/Projects/active/local-lab-ai-stack` is a **symlink** to the real path above — matching
CENTAURI's existing setup, where this repo has always lived behind a symlink of the same shape.
Anything that references `~/Projects/active/local-lab-ai-stack` (systemd units, scripts using
`$HOME`/`%h`) keeps working unmodified through the symlink; no other file needed to change when
this moved (2026-07-29).

---

## Session Start Load Order

The authoritative, fully-specified load order (including the per-repo package map and doc
placement rules) lives in the domain profile:

`~/Documents/Entities/frameworks/llm-agent-domains/photon-datum/local-lab-ai-stack/README.md`

Read that file — it supersedes any summary here.

---

## Existing Project Documentation

| File | Status |
|---|---|
| `README-agent.md` (project root) | Restored — see git history; was a "moved for review" stub, now the active top-level agent directive doc |
| `llm-agent-system-proto.md` | ⚠ Superseded — pre-framework planning artifact, retained for historical reference only, not active governance |
| `docs/meta_local/agent-context.md` | ⚠ Superseded — see `docs/governance/session-context.md` instead |
| `docs/meta_local/decisions.md` | ⚠ **Known conflict** — see "Open Issues" below. Do not treat as authoritative without reconciling against `docs/decisions.md` |
| `docs/library/framework_components/` | Active, normative — per-component practices/security/guidance. Not duplicated in the domain profile (only this repo currently uses these components) |

---

## Open Issues

- **D-001 ADR collision:** `docs/decisions.md` and `docs/meta_local/decisions.md` are independently-numbered decision logs that diverged — both have a "D-001" with different content. Needs manual reconciliation by the operator; not resolved as part of the 2026-07-29 governance retrofit (see retrospective entry in `lessons-learned.md`).
- ~~Ungathered CENTAURI lesson content~~ — **Resolved 2026-07-29.** CENTAURI pushed `meta/local-lab-ai-stack/{dynamics,review_log}.md` to `llm-agent-domains`; relocated into `docs/governance/{dynamics,review_log}.md` in this repo, where project-local lessons belong. See the second 2026-07-29 retrospective entry in `lessons-learned.md`.
- **`cts` relationship to this repo** — deliberately deferred. `photon-datum` is confirmed as the enrolled domain (this project publishes to photondatum.space). CENTAURI had independently created a duplicate `cts/local-lab-ai-stack/` enrollment; that duplicate was removed, but whether this repo has *any* legitimate relationship to the `cts` domain/team was not evaluated and remains open.

---

## Files in This Directory

| File | Purpose |
|---|---|
| `lessons-learned.md` | Framework-format lessons summary; indexes existing detailed lesson files |
| `agent-assignment.md` | Assignment template — copy is filled in per active unit of work |
| `session-context.md` | Cross-session handoff — update before pausing or closing a long session |
| `dynamics.md` | Collaboration dynamics history (I/E/L items) — relocated from `llm-agent-domains/meta/` 2026-07-29 |
| `review_log.md` | Full session-by-session review log — relocated from `llm-agent-domains/meta/` 2026-07-29 |
