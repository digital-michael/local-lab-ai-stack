# Shell Scripting — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards for writing safe bash scripts that handle sensitive data and system operations.

---

## Table of Contents

1. Injection Prevention
2. Secret Handling
3. File Operations
4. Privilege and Permissions
5. External Commands
6. Audit and Logging

## References

- OWASP Command Injection: https://owasp.org/www-community/attacks/Command_Injection
- CWE-78 OS Command Injection: https://cwe.mitre.org/data/definitions/78.html
- ShellCheck: https://www.shellcheck.net/

---

# 1 Injection Prevention

- Never pass unsanitized input to `eval`, `bash -c`, `source`, or backtick execution
- Always quote variables in command arguments: `"$var"` prevents word splitting and globbing
- Use `--` to terminate option parsing: `rm -- "$file"` prevents filenames starting with `-` from being interpreted as flags
- Validate inputs against expected patterns before use: `[[ "$input" =~ ^[a-zA-Z0-9_-]+$ ]]`
- Use arrays for command construction instead of string concatenation

# 2 Secret Handling

- Never echo secrets or passwords to stdout or logs
- Use `podman secret create` to provision secrets; reference them by name, not value
- Read secrets from files or stdin, not command-line arguments (which are visible in `/proc`)
- Clear sensitive variables after use: `unset secret_var`
- Set `umask 077` before creating files that contain sensitive data
- Never commit secrets to version control; use `.gitignore` for secret files

# 3 File Operations

- Use `mktemp` for temporary files: `tmpfile=$(mktemp)` with `trap 'rm -f "$tmpfile"' EXIT`
- Set restrictive permissions on created files: `install -m 0600 /dev/null "$secret_file"`
- Check file existence before operations: `[[ -f "$file" ]]`
- Use absolute or explicitly resolved paths for critical operations
- Avoid `rm -rf` with variables — a typo or unset variable could delete unintended paths
- Always validate paths are within expected directories before deletion

# 4 Privilege and Permissions

- Scripts in this project should never require root or sudo
- Fail explicitly if running as root: `[[ $EUID -eq 0 ]] && { echo "Do not run as root"; exit 1; }`
- Create files with least-privilege permissions (0600 for secrets, 0644 for configs, 0755 for scripts)
- Do not set SUID/SGID on any script

# 5 External Commands

- Verify external tools exist before use: `command -v jq >/dev/null 2>&1`
- Use full paths for security-critical commands if PATH manipulation is a concern
- Validate output from external commands before using in further operations
- Do not pipe untrusted data directly into `bash`, `sh`, `eval`, or `source`
- When calling `curl`, validate URLs and use `--fail` to detect HTTP errors

# 6 Audit and Logging

- Log script execution start and end with timestamps
- Log which operations were performed (but not secret values)
- Use stderr for log messages, stdout for data output
- Include the script name in log messages for traceability
- Check ShellCheck (SC codes) for all scripts before merging
