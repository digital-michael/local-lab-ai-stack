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

---

## Retrospective — 2026-07-29 (third pass): Personal Profile Activated

Recognized that "meta" always had two aspects (see the second retrospective, above, for the domain-duplication half of this story): a **framework** aspect (portable collaboration mechanics — traced via provenance headers to `meta-framework` → `llm-agent-framework/governance/collaboration-directives.md` and `agent-context-protocol.md`, already migrated long before this session) and a **collaboration metrics/lessons** aspect (this project's own `dynamics.md`/`review_log.md`, relocated in the second retrospective).

The framework's `personal` layer (Full mode: infrastructure + team + personal, resolution order `personal > team > infrastructure`) existed in `llm-agent-framework/templates/personal/` but was never activated for this project. Activated it now:

**Promoted to `~/Documents/Entities/frameworks/llm-agent-personal`** (new private repo, not committed to any shared repo) — distilled, not copied verbatim, from this file's `dynamics.md`/`review_log.md`:
- P-1..P-4 in `collaboration-patterns.md`: separation-of-concerns as default decomposition heuristic (E-4, L-5); front-loaded specs enabling cheaper-model execution (E-6); naming vocabulary before design (E-7); confirm-then-record discipline (I-19)
- `collaboration-preferences.md`: proactive meta-observation surfacing (I-3, L-2) and "evaluate vs. implement" request framing (L-12) as explicit agent behaviors wanted; default autonomy level and model-tier preferences proposed from `review_log.md`'s interaction-level pattern and this project's own `.github/copilot-instructions.md` profile-upgrade rule
- `roles-guide.md`: `lateral-thinking: aggressive`, strongly evidenced by `dynamics.md` dedicating a full 13-entry section to lateral ideas as their own category

**Deliberately left un-promoted / left empty:** "Where I Tend to Fail" and "What I Don't Want" in `collaboration-preferences.md`, and the "Personal Weaknesses" table in `collaboration-patterns.md` — the source material documents agent/tech-stack weaknesses that were fixed, not this person's own collaboration failure modes. Populating those sections would have required inventing content; left explicitly empty with a note instead.

`.llm-framework.yml` gained `personal:` and `personal_identity: digital-michael` — the identity key is deliberately independent of any OS login name (`3pdx7` on CENTAURI, `michaelbiggerstaff` here) **and** independent of any single git platform's username (GitHub/Forgejo/GitLab/Bitbucket usernames may all differ) — actual per-platform username mapping lives in `llm-agent-personal/README.md`'s own table, not duplicated into every project's dotfile.

### LLM Agent

- When a template exists but was never activated (the `personal` layer sat in `llm-agent-framework/templates/` unused this whole session), check for it before proposing something that duplicates its purpose. The user's initial proposal (`llm-agent-domains/profiles/<user>/collaboration/`) was a reasonable design reaching for a real gap, but re-derived a mechanism the framework already had — worth surfacing the existing template rather than building a parallel one.
- Confidence-labeling is worth doing explicitly when distilling inferred content into a profile: this file's promoted entries carry source citations and, in `roles-guide.md`, an explicit confidence note distinguishing strongly-evidenced settings (`lateral-thinking`) from weakly-inferred ones (`default-mode`). This directly addresses the stated risk of a personal profile being "not enough to be actionable" without overclaiming certainty it doesn't have.
