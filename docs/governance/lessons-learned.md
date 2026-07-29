---
template-version: 1.0.0
---

# Lessons Learned — local-lab-ai-stack

> Framework-format summary. Detailed, component-specific lessons are NOT duplicated here —
> this file indexes them and promotes recurring or framework-relevant items upward.

---

## Index of Existing Detailed Lesson Files

Do not move or duplicate these — they are the authoritative detail.

| File | Scope |
|---|---|
| `docs/library/framework_components/authentik/lessons_learned.md` | Authentik SSO |
| `docs/library/framework_components/litellm/lessons_learned.md` | LiteLLM gateway |
| `docs/library/framework_components/loki/lessons_learned.md` | Loki log aggregation |
| `docs/library/framework_components/podman/lessons_learned.md` | Rootless Podman / quadlets |
| `docs/library/framework_components/traefik/lessons_learned.md` | Traefik reverse proxy (superseded by Caddy — see `docs/decisions.md`) |
| `docs/library/framework_components/shell-scripting/lessons_learned.md` | Bash conventions for project scripts |
| `docs/library/framework_components/testing/lessons_learned.md` | Testing patterns |
| `docs/wip/plan.md` | BL item status tracker — blockers, deferrables, in-flight work |
| `docs/decisions.md` | Architecture Decision Records (D-001–D-039+) |
| `docs/governance/dynamics.md` | Collaboration dynamics: 19 improvements (I-1..I-19), 7 eureka moments (E-1..E-7), 13 lateral ideas (L-1..L-13) — relocated 2026-07-29 |
| `docs/governance/review_log.md` | Full session-by-session review log, 2026-03-08 through 2026-05-06 — relocated 2026-07-29 |

**Promotion candidates identified in `dynamics.md` (not yet promoted — flagged for review):**

| Item | Pattern | Candidate target |
|---|---|---|
| I-7 | Container health checks: never assume `curl`/`wget` in minimal/distroless images; verify inside the container first; distroless images may have no shell at all; systemd unit parser strips double-quote delimiters | `library/podman/` or `library/bash/` overlay (infra or domain) |
| I-10 | Podman short-name image resolution requires an interactive TTY — always use fully-qualified image names in config | `library/podman/` overlay |
| L-10 | Copy-pasted shell helpers (e.g. `_detect_deploy_mode()` duplicated across 3 scripts) are a multi-point maintenance liability — source a single lib or document the sync requirement explicitly | `photon-datum/library/bash/governance-overlay.md` |

**Other promotion candidates (recurs across components, framework/domain relevant):** none beyond the above identified yet. Re-evaluate once a second bash/Python-heavy repo joins the photon-datum domain — at that point, patterns recurring across both repos are candidates for `~/Documents/Entities/frameworks/llm-agent-domains/photon-datum/library/{bash,python}/governance-overlay.md`.

---

## Retrospective — 2026-07-29: Governance Framework Retrofit

### What Was Done

- Enrolled this project in the LLM Agent Collaboration Framework (Team mode), domain = `photon-datum`
- Physically relocated `llm-agent-framework` and `llm-agent-domains` on this workstation from `~/Projects/active/` to `~/Documents/Entities/frameworks/` — matching CENTAURI's existing layout exactly, so the same convention now works unmodified across workstations
- Fixed 6 files in the framework/domains repos (`cts` and `photon-datum` READMEs, `resource-tech-kit`, `fyne-components`, `space_sim`) that hardcoded the old `~/Projects/active/...` path — these would have silently broken for the `cts` domain's unrelated projects had they been left alone; this was a direct fallout of the physical move, not an original scope item
- Created `.llm-framework.yml`, `docs/governance/{README.md, lessons-learned.md, agent-assignment.md, session-context.md}`
- Added `photon-datum/library/{bash,python}/governance-overlay.md` (scaffolds — empty, ready to accumulate lessons) and `photon-datum/local-lab-ai-stack/README.md` (per-repo session context)
- Rewrote `.github/copilot-instructions.md` to use the portable `~/Documents/Entities/frameworks/...` path instead of the CENTAURI-machine-specific absolute path (`/home/3pdx7/...`), and corrected the domain reference from a non-existent `cts/local-lab-ai-stack/` to `photon-datum/local-lab-ai-stack/`
- Restored `README-agent.md` from the abandoned `tmp/README-agent.md` staging copy
- Marked `docs/meta_local/agent-context.md` superseded (not deleted) in favor of `docs/governance/session-context.md`

### What Was Found But Deliberately Not Fixed

- **`docs/decisions.md` vs. `docs/meta_local/decisions.md` — D-001 collision.** These are two separately-numbered ADR logs that diverged; the claim in the old `agent-context.md` that one was "moved" into the other is false. Reconciling 39+ historical decision records is a judgment call for the operator, not something to resolve as a side effect of a governance retrofit. Flagged in `docs/governance/README.md` and the domain repo context file.
- Untracked scratch files (`docs/multi-level orchastration.md`, `t.sh`, `watch_20260415-122431`) — unrelated to governance, left as-is.

### LLM Agent

- The prior retrofit attempt (commit `315e60c`, on a different machine) stubbed governance files with a hardcoded absolute path from that machine's home directory and pointed at a domain (`cts`) and per-repo directory (`cts/local-lab-ai-stack/`) that were never actually created. A partial retrofit that hardcodes an absolute, machine-specific path is worse than no retrofit — it looks authoritative but silently fails on every other workstation. Future retrofits across a multi-workstation setup should always use `~`-relative paths, never `/home/<user>/...` or `/Users/<user>/...` literals, in any file that is expected to be read on more than one machine.

### Tech Stack

- No hardcoded per-user/per-OS absolute paths belong in any file synced across workstations (git-tracked docs, `.llm-framework.yml`, domain profile READMEs). `~` expansion is portable across macOS and Linux and does not encode a username in the literal text, which absolute paths do.

---

## Retrospective — 2026-07-29 (later same day): Domain Duplication Reconciliation

A `git push` surfaced that CENTAURI had independently pushed `feat: add local-lab-ai-stack domain entry and meta files` to `llm-agent-domains` — enrolling this project under `cts` (`cts/local-lab-ai-stack/README.md`) at roughly the same time this session enrolled it under `photon-datum`. Both landed via a clean, non-conflicting `git merge` (different files, auto-mergeable), but the result was two contradictory domain enrollments for the same project.

**Resolved:** `photon-datum` confirmed as the correct domain (this project publishes to photondatum.space; matches the reasoning already recorded in this file's first retrospective). The `cts/local-lab-ai-stack/` duplicate was removed from `llm-agent-domains`, along with its row in `cts/README.md`'s repo table. Broader questions about any legitimate `cts` relationship to this project are explicitly deferred — not evaluated here.

The same CENTAURI commit also carried `meta/local-lab-ai-stack/{agent-context,dynamics,review_log}.md` — this is the "ungathered CENTAURI lesson content" flagged as an open issue in this file's first retrospective and in `docs/governance/README.md`. That gap is now closed: `dynamics.md` and `review_log.md` were relocated into this file's index (above); `agent-context.md` was a duplicate of this project's own already-superseded `docs/meta_local/agent-context.md` and was discarded rather than relocated.

**Why this belonged in the project repo, not the domain repo:** `llm-agent-domains/README.md` states explicitly — "Do not write here: Active assignments, session context, or project-local lessons — those belong in `docs/governance/` inside the project repo." The domain repo is for domain-wide rules and per-repo *pointers*, not a second copy of project history.

### LLM Agent

- Two independent sessions enrolling the same project under different domains, discovered only at push time, is a real failure mode of multi-workstation framework use — `git push` rejection is the actual detection mechanism, not anything in the governance files themselves. There is no pre-push check today that would have caught this earlier.
