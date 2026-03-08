# Shell Scripting — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for writing reliable, maintainable bash scripts for this project.

---

## Table of Contents

1. Script Structure
2. Error Handling
3. Variables and Quoting
4. Functions
5. Input Validation
6. Portability
7. Testing

## References

- Bash Manual: https://www.gnu.org/software/bash/manual/
- Google Shell Style Guide: https://google.github.io/styleguide/shellguide.html
- ShellCheck: https://www.shellcheck.net/

---

# 1 Script Structure

- Start with a shebang: `#!/usr/bin/env bash`
- Set strict mode early: `set -euo pipefail`
- Define constants and defaults near the top
- Use `main()` function pattern to organize script logic
- Call `main "$@"` at the bottom of the script
- Group related functions; place helper functions before the functions that call them

# 2 Error Handling

- `set -e` exits on any command failure; `set -u` treats unset variables as errors
- `set -o pipefail` catches failures in pipelines, not just the last command
- Use `trap` for cleanup: `trap cleanup EXIT`
- Log errors to stderr: `echo "ERROR: message" >&2`
- Return meaningful exit codes: 0 for success, 1 for general errors, 2 for usage errors
- Use `|| true` sparingly and only when failure is genuinely acceptable

# 3 Variables and Quoting

- Always quote variables: `"$var"` not `$var`
- Use `${var:-default}` for default values
- Use `readonly` for constants: `readonly AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"`
- Prefer lowercase for local variables, UPPERCASE for exported/environment variables
- Use arrays for lists: `files=("a.txt" "b.txt")` with `"${files[@]}"` expansion
- Never use `eval` — it opens injection vulnerabilities

# 4 Functions

- Declare with `function_name() { }` syntax (no `function` keyword for POSIX compatibility)
- Use `local` for function-scoped variables
- Return values via exit codes or stdout capture: `result=$(my_function)`
- Keep functions focused: one responsibility per function
- Document parameters in a comment above the function if not self-evident

# 5 Input Validation

- Validate all command-line arguments before processing
- Use `getopts` or manual argument parsing with clear usage messages
- Check for required external tools: `command -v jq >/dev/null 2>&1 || { echo "jq required"; exit 1; }`
- Sanitize file paths: resolve with `realpath` or `readlink -f`
- Never construct commands from unsanitized user input

# 6 Portability

- Target bash 4.4+ (common on modern Linux distributions)
- Avoid bashisms when POSIX shell compatibility is needed; use `#!/bin/sh` explicitly for POSIX scripts
- Use `[[ ]]` for conditionals in bash scripts (safer than `[ ]`)
- Prefer `$()` over backticks for command substitution
- Test on the target environment; avoid macOS-specific or BSD-specific tool flags

# 7 Testing

- Run ShellCheck on all scripts: `shellcheck scripts/*.sh`
- Test scripts in a clean environment (fresh VM or container)
- Use `bash -n script.sh` for syntax checking without execution
- Test edge cases: empty inputs, missing files, permission errors
- Use `set -x` for debugging; remove before committing
