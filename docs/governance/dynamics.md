# Project Dynamics — local-lab-ai-stack
**Last Updated:** 2026-03-22 UTC
**Target Audience:** LLM Agents

> **Relocated (2026-07-29):** moved from `llm-agent-domains/meta/local-lab-ai-stack/dynamics.md`.
> Project-local lessons belong in the project repo per the framework's own placement rule
> (`llm-agent-domains/README.md` §"Do not write here") — this was the fix, not a rewrite of content.
> Indexed from `docs/governance/lessons-learned.md`.

---

## Purpose

This file records project-specific collaboration dynamics — improvements, eureka moments, and lateral ideas that emerged from work on this project. For portable collaboration patterns (strengths, weaknesses), see the domain `governance-overlay.md`.

---

## Improvements Made

| # | Improvement | Triggered By |
|---|---|---|
| I-1 | Created decision record framework (meta_decisions.md) | W-1 — decisions were invisible |
| I-2 | Codified the `README-agent.md` convention from implicit to explicit | S-2 — human spotted the meta-pattern |
| I-3 | Established auto-identification directive in meta.md Purpose | W-4 — agent should surface meta-observations proactively |
| I-4 | Split meta files by concern (meta.md, meta_decisions, meta_dynamics, meta_metrics) | S-6 — human applied separation of concerns to the meta system itself |
| I-5 | `podman cp` + exec pattern established over heredoc exec — avoids silent hangs when piping stdin to `podman exec python3 -` | W-5 — heredoc approach hung without output; copy-then-exec pattern is reliable and generalises to any language |
| I-6 | Two-level fresh-client pattern for test teardown — module-scoped httpx clients accumulate stale keep-alive connections by teardown time; cleanup fixtures should open a fresh client in a `with` block | W-6 — `cleanup_test_collection` teardown raised `RemoteProtocolError: Server disconnected` on every clean run |
| I-7 | `bash -c 'echo > /dev/tcp/localhost/PORT'` as universal container health check — three lessons: (1) never assume `curl`/`wget` in minimal or distroless images; verify inside the actual container first; (2) distroless images (e.g., Grafana Loki 3.x) have no shell at all — remove `HealthCmd` entirely and rely on systemd; (3) systemd unit file parser strips double-quote delimiters from field values — use single-quotes or avoid string literals in the command when possible | W-7 — 6 services reported unhealthy after deployment |
| I-8 | OpenWebUI's SQLite `webui.db` takes precedence over env vars — three cascading pitfalls: DB overrides env, Docker Compose image default baked in, openwebui_api_key must match litellm_master_key exactly | W-8 — OpenWebUI showed "failed to fetch models" |
| I-9 | Hardware-first: always run `nvidia-smi` before writing GPU config | W-9 — vLLM config written for imaginary hardware |
| I-10 | Always use fully-qualified image names in config.json — Podman short-name resolution requires interactive TTY | W-10 — vLLM service failed at first start |
| I-11 | vLLM entrypoint requires explicit CLI args — env vars ignored | W-11 — vLLM container started but served model as path |
| I-12 | GPU_MEMORY_UTILIZATION must account for desktop VRAM | W-12 — vLLM crashed in `_dummy_sampler_run` with OOM |
| I-13 | LiteLLM openai/ provider requires `/v1` suffix in api_base | W-13 — all three routing bugs discovered in sequence |
| I-14 | Verify application code against config.json before designing migrations | Phase 10 architecture planning |
| I-15 | `uname -s` not `podman info` determines deploy mode on macOS | TC25 bare-metal deploy — quadlets written on macOS |
| I-16 | Fix the detection AND clean up what the wrong code path already created | TC25 status showing `unknown` after deploy fix |
| I-17 | Use `/metrics` not `/ready` to probe promtail liveness | TC25 promtail showing `stopped` despite running |
| I-18 | Podman CDI spec dirs are empty by default — must be configured explicitly | vllm.service crash-looping with `exit-code 126` |
| I-19 | Confirm-then-record discipline prevents spec drift | D-027 Phase B — 5-round design loop |

---

## Eureka Moments

| # | Moment | What Happened |
|---|---|---|
| E-1 | Three-doc split (D-001) | The agent was fixing errors in a monolithic doc and kept running into cross-concern conflicts. The human's single-source-of-truth principle, combined with the agent's structural pain, produced the split. |
| E-2 | README-agent.md as an inheritance pattern (D-004) | Started as "let's add agent instructions." The human asked "should we formalize this?" The agent mapped it to `.gitignore`-style directory scoping. |
| E-3 | Meta-documentation as a feedback loop (D-008) | The human asked for a decision record. Through the clarifying questions, the scope expanded to include collaboration dynamics, lateral thinking, and process improvement. |
| E-4 | Separation of concerns as a named, reusable principle (D-009) | The agent noted meta.md's length as a pressure point. The human proposed splitting by concern and named the principle: "applied separation of concerns." |
| E-5 | Level 4 and meta framework extraction (D-010) | The human invoked "Level 4" — a level that didn't exist — to co-design the meta framework's decoupling from the project. A level was defined by exercising it. |
| E-6 | Front-loaded spec as an execution enabler | Phase 4 produced §12 Quadlet Translation Specification before any quadlet file existed. This enabled the entire execution phase to run on Sonnet without Opus. |
| E-7 | Lifecycle state machine as a design primitive for network topology | Naming explicit states before implementation produced a clean agreed design in 5 turns. The state names became shared vocabulary. |

---

## Lateral Ideas

| # | Source Task | Lateral Observation | Status |
|---|---|---|---|
| L-1 | D-004 (README-agent.md convention) | The directory-scoped inheritance pattern could generalize beyond agent directives. | Noted |
| L-2 | D-008 (meta.md) | If the agent auto-identifies meta-worthy content, it's effectively doing continuous retrospectives — an agile practice applied to human-agent pairing without ceremony cost. | Noted |
| L-3 | D-002 (JSON config SSOT) | The `config.json` → `configure.sh` → quadlet generation pipeline is a simple form of Infrastructure as Code. | Noted |
| L-4 | Component library (D-003) | The three-file pattern (best_practices / security / guidance) could be templated and applied to non-component domains. | Noted |
| L-5 | D-009 (meta file split) | "Applied separation of concerns" recurs as the dominant design principle. The agent should learn to recognize the symptoms that trigger it. | Noted |
| L-6 | D-010 (meta extraction) | The framework/instance separation pattern could apply beyond meta — any system of shared conventions. | Noted |
| L-7 | Authentik bootstrap (T-086) | Service bootstrapping is often invisible in documentation: a "healthy" container healthcheck ≠ a "ready to serve traffic" service. | Noted |
| L-8 | Flowise 3.x API auth gap | Flowise 3.x added a full user/org system. FLOWISE_USERNAME/PASSWORD env vars no longer bootstrap a usable API account. | Noted |
| L-9 | Library-as-asset: the custody pattern generalizes | The `.ai-library` custody model (D-025) is not specific to knowledge libraries. Any content system where contributors want proof of creation could use this pattern. | Noted |
| L-10 | Copy-pasted shell helpers are a multi-point maintenance liability | `_detect_deploy_mode()` was copy-pasted into three scripts independently. For logic that must be consistent, either source a single `scripts/lib.sh`, or document the copy-sync requirement explicitly. | Noted |
| L-11 | Liveness ≠ readiness: treat them as distinct probe targets | Before writing a health probe, explicitly ask: "is this testing liveness or readiness?" | Noted |
| L-12 | "Evaluate, not implement" as a reusable request frame | Explicitly framing a discussion as critical evaluation produces more honest and useful input from the agent. | Noted |
| L-13 | Calibration file has a hidden third scope: person | `meta_calibration.md` mixes framework mechanics (universal) and Human Profile (person-specific). When a second collaborator needs calibration, extract profiles into `profiles/<name>.md`. | Noted — TODO |
