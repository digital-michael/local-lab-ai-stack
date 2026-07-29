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

**Promotion candidates (recurs across components, framework/domain relevant):** none identified yet as of this retrofit. Re-evaluate once a second bash/Python-heavy repo joins the photon-datum domain — at that point, patterns recurring across both repos are candidates for `~/Documents/Entities/frameworks/llm-agent-domains/photon-datum/library/{bash,python}/governance-overlay.md`.

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
