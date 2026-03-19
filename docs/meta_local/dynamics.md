# Project Dynamics — llm-agent-local-2
**Last Updated:** 2026-03-19 UTC
**Target Audience:** LLM Agents

---

## Purpose

This file records project-specific collaboration dynamics — improvements, eureka moments, and lateral ideas that emerged from work on this project. For portable collaboration patterns (strengths, weaknesses), see [../meta/meta_dynamics.md](../meta/meta_dynamics.md).

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
| I-7 | `bash -c 'echo > /dev/tcp/localhost/PORT'` as universal container health check — three lessons: (1) never assume `curl`/`wget` in minimal or distroless images; verify inside the actual container first; (2) distroless images (e.g., Grafana Loki 3.x) have no shell at all — remove `HealthCmd` entirely and rely on systemd; (3) systemd unit file parser strips double-quote delimiters from field values, so `HealthCmd=cmd "arg"` reaches Podman without quotes, causing `sh: Unterminated quoted string` — use single-quotes or avoid string literals in the command when possible | W-7 — 6 services reported unhealthy after deployment; all root-caused to missing tools or systemd quote-stripping |
| I-8 | **OpenWebUI's SQLite `webui.db` takes precedence over env vars — three cascading pitfalls:** (1) **DB overrides env**: OpenWebUI persists all connection config (Ollama URL, API keys) to `webui.db` (table `config`, JSON column `data`) at first boot before any env var is applied at the application layer; subsequent env var changes have no effect until the DB is patched; (2) **Docker Compose image default baked in**: the OCI image ships with `OLLAMA_BASE_URL=/ollama` (an nginx reverse-proxy path for Docker Compose deployments); at first boot this propagates as `host.docker.internal:11434` into the DB — both values are wrong for Podman; set `OLLAMA_BASE_URL=http://<svc>.ai-stack:11434` in the quadlet env **before first boot**, or patch the DB after (`UPDATE config SET data=json_patch(data, ...) WHERE id=1`); (3) **openwebui_api_key must match litellm_master_key exactly**: `OPENAI_API_KEY` (sourced from the `openwebui_api_key` secret) is forwarded as `Bearer <key>` to LiteLLM; if it differs from `LITELLM_MASTER_KEY` every model call returns 401; secrets must be kept in sync — `diagnose.sh --profile full --fix` detects and corrects all three via `_check_integrations()` | W-8 — OpenWebUI showed "failed to fetch models" and "Ollama: network problem" with an empty Bearer key; root-caused to three stacked misconfigurations rather than a single fault |

---

## Eureka Moments

| # | Moment | What Happened |
|---|---|---|
| E-1 | **Three-doc split (D-001)** | The agent was fixing errors in a monolithic doc and kept running into cross-concern conflicts. The human's single-source-of-truth principle, combined with the agent's structural pain, produced the split. Neither the principle alone nor the editing pain alone would have generated the same result. |
| E-2 | **README-agent.md as an inheritance pattern (D-004)** | Started as "let's add agent instructions." The human asked "should we formalize this?" The agent mapped it to `.gitignore`-style directory scoping. The result — a general-purpose governance inheritance pattern — was more powerful than either the initial request or the agent's first implementation. |
| E-3 | **Meta-documentation as a feedback loop (D-008)** | The human asked for a decision record. Through the clarifying questions, the scope expanded to include collaboration dynamics, lateral thinking, and process improvement. The document became self-referential: it records the process *and* improves it by existing. |
| E-4 | **Separation of concerns as a named, reusable principle (D-009)** | The agent noted meta.md's length as a pressure point. The human proposed splitting by concern and named the principle: "applied separation of concerns." By naming it, the pattern became transferable — the agent can now recognize and propose this pattern in future contexts rather than waiting for the human to invoke it. |
| E-5 | **Level 4 and meta framework extraction (D-010)** | The human invoked "Level 4" — a level that didn't exist — to co-design the meta framework's decoupling from the project. The agent interpreted the intent (co-create at the system level, extend the framework itself) and operated accordingly: proposed the framework vs. journal tension, argued against the "repo-" prefix, and designed the framework + distillation model. The discussion produced D-010 (meta extraction) and formalized Level 4 as a permanent interaction level. A level was defined by exercising it. |
| E-6 | **Front-loaded spec as an execution enabler** | Phase 4 produced §12 Quadlet Translation Specification — a detailed field mapping table, unit file template, six special cases, and a complete 14-row After=/Requires= dependency chain — written before any quadlet file existed. Phase 5 then generated all 15 unit files with no architectural reasoning required; the spec reduced generation to mechanical lookup. This enabled the entire execution phase to run on Sonnet without Opus. Generalized: when a translation task has complex, irregular rules, encoding them in an explicit spec before execution is more reliable than reasoning them out during it. Front-loading spec work shifts cognitive load from execution to planning, where it is easier to verify and correct. |

---

## Lateral Ideas

| # | Source Task | Lateral Observation | Status |
|---|---|---|---|
| L-1 | D-004 (README-agent.md convention) | The directory-scoped inheritance pattern could generalize beyond agent directives. Other file conventions (e.g., `OWNERS`, `CONVENTIONS.md`) could follow the same most-specific-wins rule, creating a unified "directory metadata" system. | Noted |
| L-2 | D-008 (meta.md) | If the agent auto-identifies meta-worthy content, it's effectively doing continuous retrospectives. This is an agile practice (sprint retros) applied to human-agent pairing — but without the ceremony cost. Could be a model for how other teams use LLM agents. | Noted |
| L-3 | D-002 (JSON config SSOT) | The `config.json` → `configure.sh` → quadlet generation pipeline is a simple form of Infrastructure as Code. If the repo grows to multi-node, this pattern could evolve into a declarative config layer (like Nix or Terraform) without starting from scratch. | Noted |
| L-4 | Component library (D-003) | The three-file pattern (best_practices / security / guidance) could be templated and applied to non-component domains — e.g., `docs/library/processes/deployment/`, `docs/library/processes/backup/`. The pattern isn't component-specific; it's concern-specific. | Noted |
| L-5 | D-009 (meta file split) | "Applied separation of concerns" recurs as the dominant design principle in this project (D-001, D-003, D-005, D-009). The human applies it instinctively; the agent should learn to recognize the symptoms that trigger it: a file serving multiple access patterns, a document mixing stable and volatile content, an artifact with multiple reasons to change. These are the signals to proactively propose a split. | Noted |
| L-6 | D-010 (meta extraction) | The framework/instance separation pattern — a portable protocol with local instantiation and upward promotion — could apply beyond meta. Any system of shared conventions (coding standards, deployment patterns, security baselines) could be structured the same way: a framework repo defining the protocol, project repos instantiating it locally, and validated insights promoted back to the framework. | Noted |
| L-7 | Authentik bootstrap (T-086) | Service bootstrapping is often invisible in documentation: Authentik's embedded outpost runs and looks healthy but returns 404 for all requests until at least one provider is assigned. A "healthy" container healthcheck ≠ a "ready to serve traffic" service. This pattern recurs across services — consider adding a post-deploy smoke test layer that validates functional readiness, not just process liveness. | Noted |
| L-8 | Flowise 3.x API auth gap | Flowise 3.x added a full user/org system. FLOWISE_USERNAME/PASSWORD env vars no longer bootstrap a usable API account — the user table stays empty until registration completes via the UI. Any automation that calls the Flowise API must account for this: either seed the DB directly or use the UI to complete registration and generate an API key first. | Noted |
