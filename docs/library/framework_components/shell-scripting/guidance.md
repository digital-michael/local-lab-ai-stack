# Shell Scripting — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific conventions and patterns for bash scripts in this AI stack.

---

## Table of Contents

1. Project Conventions
2. Script Patterns
3. configure.sh Conventions
4. Testing and Validation

---

# 1 Project Conventions

- All scripts live in `./scripts/` at the project root
- Scripts use `#!/usr/bin/env bash` and `set -euo pipefail`
- External dependencies: `jq` (required by configure.sh), `podman` (v5.7+), standard coreutils
- Scripts reference `$AI_STACK_DIR` (default: `$HOME/ai-stack`) as the deployment root
- Config file: `./configs/config.json` — the single source of truth for service definitions
- Generated artifacts (quadlets, secrets) are written to `$AI_STACK_DIR/`
- **Every script must support `--help` and `-h` flags.** When invoked with either flag, the script must print its purpose, available options/subcommands, and usage examples, then exit 0. This is a hard requirement — scripts without help output are incomplete.

# 2 Script Patterns

- `configure.sh`: CRUD on config.json, quadlet generation, secrets provisioning
- `deploy-stack.sh`: orchestrates the full deployment sequence (validate → generate → deploy)
- `install.sh`: one-time system prerequisites and directory setup
- `validate-system.sh`: pre-flight checks for Podman version, tools, permissions

Each script follows the `main()` function pattern:

```bash
#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Purpose:
  Brief description of what this script does.

Options:
  -h, --help    Show this help message and exit

Examples:
  $(basename "$0")
EOF
}

main() {
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac
    # script logic here
    :
}

main "$@"
```

# 3 configure.sh Conventions

- Subcommands: `init`, `get`, `set`, `list-services`, `validate`, `generate-quadlets`, `generate-secrets`
- All config reads/writes go through `jq` operating on `configs/config.json`
- Quadlet output directory: `$AI_STACK_DIR/quadlets/` (copied to `$HOME/.config/containers/systemd/` on deploy)
- Service names in config.json match quadlet file names: `ai-stack-<service>.container`
- Secrets are provisioned by reading from config and piping to `podman secret create`

# 4 Testing and Validation

- Run `shellcheck scripts/*.sh` before committing
- Test with `bash -n scripts/*.sh` for syntax validation
- Validate config.json with `scripts/configure.sh validate` before deployment
- Manual testing checklist:
  - Fresh install on clean system
  - Idempotent re-run (running twice produces the same result)
  - Missing dependencies (graceful error messages)
  - Invalid config values (validation catches them)
