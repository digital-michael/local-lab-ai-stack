# Work-in-Progress — Implementation Plan

**Tracking:** Backlog lives in `docs/meta_local/review_log.md` (Pending Tasks table).
**Sequence:** Items are worked in backlog listing order unless priority escalation is noted.
**Last Updated:** 2026-05-04

---

## Active

_Nothing in flight._

---

## Next (selected)

### BL-004 — RLM integration research
**Priority:** P2  
**Status:** not started  

Research MIT's RLM approach and design integration into the inference/knowledge layer.

---

## Queue (in order)

| ID | Priority | Title | Status |
|---|---|---|---|
| BL-001 | P2 | CENTAURI-playbook.md | ✅ done — updated 2026-04-08 (commit `918b5df`); extended 2026-05-04 with Headscale tailnet runbook (§2.6, §7.8) — output/ gitignored |
| BL-002 | P3 | node.sh list: stanza layout + headscale backend | ✅ done 2026-05-04 — stanza output, `--headscale-url/key` backend, `--namespace` filter (normalization: with/without `net-`), `--json` output; state persisted to `~/.config/ai-stack/headscale_{url,key}`. **Known gap:** headscale nodes not tagged in DB — `--namespace` filter functional but returns no matches until `headscale nodes tag` is run per-node. |
| BL-003 | P3 | --json output mode for scripts | ✅ done 2026-05-04 — merged into BL-002 (`node.sh list --json`); remaining scripts (status.sh, diagnose.sh) deferred to Phase 3 standardization pass |
| BL-004 | P2 | RLM integration research | not started |
| BL-005 | P2 | Internal operator dashboard | not started |
| BL-006 | P2 | Live throughput + profiling dashboard | not started |
| BL-007 | P2 | Configurable domain in setup | not started |
| BL-008 | P2 | Default credential policy | not started |
| BL-009 | P1 | Content Review Layer Phase 2 (guard LLM) | Phase 1 done (`9d33dce`); Phase 2 not started |
| BL-010 | P3 | Evaluate peer/node registration architecture | deferred — not part of current planned work |

---

## Notes

- **BL-009 Phase 2** is P1 (highest priority in backlog) but falls after BL-008 in listing order.
  Operator confirmed: work items in listing order. Escalate if a security event changes this.
- **BL-010** is explicitly deferred until multi-controller topology is on the roadmap.
