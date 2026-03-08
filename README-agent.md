# AI Stack — Agent Directives
**Target Audience:** LLM Agents operating on this repository

---

## 1 Purpose

This file is the top-level governance document for any LLM agent making changes to this repository. Read this file first. It defines how the repo is organized, where authoritative information lives, and what rules apply.

---

## 2 Core Principle: Single Source of Truth

Every fact has exactly one canonical location. Do not duplicate information across files — cross-reference instead. When two documents disagree, the more specific source wins:

| Scope | Canonical Source |
|---|---|
| System design, component roles, data flows | [docs/ai_stack_blueprint/ai_stack_architecture.md](docs/ai_stack_blueprint/ai_stack_architecture.md) |
| Deployment procedures, quadlets, operational runbooks | [docs/ai_stack_blueprint/ai_stack_implementation.md](docs/ai_stack_blueprint/ai_stack_implementation.md) |
| Tunable values: images, ports, env vars, limits | [docs/ai_stack_blueprint/ai_stack_configuration.md](docs/ai_stack_blueprint/ai_stack_configuration.md) |
| Machine-readable service definitions | [configs/config.json](configs/config.json) |
| Task status: blockers, deferrables, future work | [docs/ai_stack_blueprint/ai_stack_checklist.md](docs/ai_stack_blueprint/ai_stack_checklist.md) |
| Per-component practices, security, and project guidance | [docs/library/framework_components/](docs/library/framework_components/) |
| Collaboration process, decision record, lateral thinking | [docs/meta.md](docs/meta.md) |

When adding or changing a value, put it in the canonical source and reference it from elsewhere. Never introduce a second copy.

---

## 3 The `README-agent.md` Convention

Any file named `README-agent.md` is a **directive document for LLM agents**, scoped to the directory where it resides and all descendant directories. By default, an agent operating on files within a directory must discover and adhere to the nearest `README-agent.md` at or above its working scope.

**Rules:**

1. **Directory-scoped authority.** A `README-agent.md` governs the directory it lives in and every subdirectory beneath it, unless a more specific `README-agent.md` exists deeper in the tree.
2. **Most-specific wins.** When multiple `README-agent.md` files exist in the ancestor chain, the closest one to the working directory takes precedence. Parent directives still apply where the child does not override them.
3. **Read before acting.** Before modifying files in any directory, check for a `README-agent.md` in that directory or its nearest ancestor and follow its instructions.
4. **Distinct from `README.md`.** `README-agent.md` targets LLM agents. `README.md` targets humans. Do not mix audiences or merge these files.

This convention allows governance to be layered: broad rules live at the repo root, while component- or domain-specific rules live closer to the code they govern.

---

## 4 Mandatory Reading Before Changes

Before modifying any file in this repo, read the relevant documents in this order:

1. **This file** — you are here.
2. **Component guidance** — if your change touches a specific component (e.g., PostgreSQL, Podman, vLLM), read all three files in its `docs/library/framework_components/<component>/` directory:
   - `best_practices.md` — industry-standard practices
   - `security.md` — hardening and access control
   - `guidance.md` — project-specific decisions
3. **Architecture doc** — if your change affects system design or component interactions: [ai_stack_architecture.md](docs/ai_stack_blueprint/ai_stack_architecture.md)
4. **Implementation doc** — if your change involves deployment procedures: [ai_stack_implementation.md](docs/ai_stack_blueprint/ai_stack_implementation.md)
5. **Configuration doc** — if your change involves tunable values: [ai_stack_configuration.md](docs/ai_stack_blueprint/ai_stack_configuration.md)

The component guidance in `docs/library/framework_components/` is **normative**. See the [framework_components/README-agent.md](docs/library/framework_components/README-agent.md) for the full compliance policy.

6. **Meta doc** — if your work involves a decision, process observation, or lateral insight worth recording: [meta.md](docs/meta.md)

---

## 5 Repository Layout

```
.
├── README.md                            # Human-facing repo overview
├── README-agent.md                      # This file (agent directives)
├── configs/
│   └── config.json                      # Machine-readable service definitions
├── scripts/
│   ├── configure.sh                     # Config CRUD, quadlet/secret generation
│   ├── deploy-stack.sh                  # Full deployment orchestration
│   ├── install.sh                       # One-time system setup
│   └── validate-system.sh              # Pre-flight environment checks
└── docs/
    ├── ai_stack_blueprint/              # Architecture, implementation, config, checklist
    └── library/
        └── framework_components/        # Per-component reference (14 components)
```

---

## 6 Rules for Scripts

All scripts in `./scripts/` must follow the conventions in [docs/library/framework_components/shell-scripting/guidance.md](docs/library/framework_components/shell-scripting/guidance.md). Key requirements:

- `#!/usr/bin/env bash` with `set -euo pipefail`
- Every script must support `--help` and `-h` (purpose, options, usage examples, exit 0)
- Follow the `main()` function pattern with `usage()` helper
- External tool dependencies checked before use
- Secrets never echoed or passed as CLI arguments
- All config reads/writes go through `configs/config.json` via `jq`

See also: [shell-scripting/best_practices.md](docs/library/framework_components/shell-scripting/best_practices.md) and [shell-scripting/security.md](docs/library/framework_components/shell-scripting/security.md).

---

## 7 Rules for Configuration

- **`configs/config.json`** is the machine-readable single source of truth for all service definitions (images, ports, volumes, env vars, secrets, health checks, resources, dependencies).
- **`docs/ai_stack_blueprint/ai_stack_configuration.md`** documents the schema and rationale. It does not contain the values themselves.
- To change a service's configuration, update `config.json` and regenerate quadlets with `scripts/configure.sh generate-quadlets`.
- Validate changes with `scripts/configure.sh validate`.

---

## 8 Rules for Documentation

- Do not duplicate content. Cross-reference the canonical source.
- When adding a new component, create a subdirectory under `docs/library/framework_components/` with `best_practices.md`, `security.md`, and `guidance.md`.
- Update the component table in [framework_components/README-agent.md](docs/library/framework_components/README-agent.md) when adding or removing components.
- Update the [checklist](docs/ai_stack_blueprint/ai_stack_checklist.md) when completing or adding tasks.
- `README-agent.md` files target LLM agents. `README.md` files target humans. Do not mix audiences.

---

## 9 Deviation Policy

If a change must deviate from the guidance in `docs/library/framework_components/`, you must:

1. Note the deviation explicitly in the commit message or PR description.
2. State the rationale.
3. Update the relevant guidance file if the deviation becomes the new standard.

---

## 10 File Naming Conventions

| Pattern | Audience | Purpose |
|---|---|---|
| `README.md` | Humans | Overview, getting started, navigation |
| `README-agent.md` | LLM Agents | Directives, compliance rules, cross-references |
| `best_practices.md` | Both | Industry-standard component practices |
| `security.md` | Both | Hardening and access control |
| `guidance.md` | Both | Project-specific opinionated decisions |
