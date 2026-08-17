---
template-version: 1.0.0
---

# Session Context

> Use this file to capture state when switching models, pausing work, or resuming in a new session.
> This is the source of truth for cross-session handoff.

---

## Project Summary

**Project:** local-lab-ai-stack — self-hosted AI infrastructure stack (Podman/systemd quadlets) also hosting photon-datum's public infrastructure (reverse proxy, Headscale mesh, git/mail services)
**Date captured:** 2026-07-29
**Current model tier in use:** <!-- Planning/Reasoning | Implementation | Minor task -->

Rootless-Podman-based local AI stack (OpenWebUI, Flowise, LiteLLM, vLLM, Qdrant, PostgreSQL,
Authentik, Prometheus/Grafana, Loki/Promtail, MinIO) with a machine-readable `configs/config.json`
as the single source of truth, driven by `scripts/{install,configure,deploy,validate-system}.sh`.

---

## Active Assignment

**Assignment file:** <!-- path to agent-assignment.md, once one is opened -->
**Assignment title:** Governance framework retrofit (this session)
**Current phase:** Implementation

---

## Last Known Status

**Last completed:** Enrolled the project in the LLM Agent Collaboration Framework under the
`photon-datum` domain; relocated `llm-agent-framework` and `llm-agent-domains` to the
cross-workstation canonical path `~/Documents/Entities/frameworks/`; scaffolded
`docs/governance/`; rewrote `.github/copilot-instructions.md` and `README-agent.md` to use
portable paths.

**Next step:** See `docs/governance/lessons-learned.md` retrospective entry for the full list.
Outstanding: reconcile the `docs/decisions.md` / `docs/meta_local/decisions.md` D-001 collision
(deliberately deferred — operator decision).

**Any open questions or blockers:** D-001 ADR collision (see Open Issues in
`docs/governance/README.md`). TC25 workstation not yet bootstrapped with the framework repos.

---

## Implementation Plan — Current Snapshot

| # | Unit of Work | Status |
|---|---|---|
| 1 | Relocate framework repos to `~/Documents/Entities/frameworks/` | Complete |
| 2 | Fix stale paths in `cts`/`photon-datum` domain files | Complete |
| 3 | Scaffold `docs/governance/` | Complete |
| 4 | Rewrite `.github/copilot-instructions.md`, restore `README-agent.md` | Complete |
| 5 | Package-map addendum to `ai_stack_architecture.md` | See below |
| 6 | Reconcile D-001 ADR collision | Deferred — operator decision |
| 7 | Bootstrap TC25 with framework repos at canonical path | Not started (no access from this session) |

---

## Governance Context

**System prompt location:** `~/Documents/Entities/frameworks/llm-agent-framework/governance/system-prompts/base-system-prompt.md`
**Active lessons-learned file:** `docs/governance/lessons-learned.md`
**Language overlay(s) in use:** Bash, Python — infrastructure + photon-datum domain overlays

---

## Model Context Notes

- Framework repos live at `~/Documents/Entities/frameworks/{llm-agent-framework,llm-agent-domains}` on every workstation — do not reference `~/Projects/active/llm-agent-framework` or `~/Projects/active/llm-agent-domains` anywhere; those paths no longer exist on this Mac and never existed at that location on CENTAURI.
- `docs/meta_local/agent-context.md` is superseded by this file — do not treat it as current state.

---

## Resumption Instructions

1. Read `docs/governance/README.md` for the enrollment summary and open issues.
2. Read the domain repo context file: `~/Documents/Entities/frameworks/llm-agent-domains/photon-datum/local-lab-ai-stack/README.md` for the full session-start load order.
3. Check `docs/wip/plan.md` for BL item status before starting new work.
