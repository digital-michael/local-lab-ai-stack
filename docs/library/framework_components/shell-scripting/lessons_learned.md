# Shell Scripting — Lessons Learned
**Last Updated:** 2026-03-08 UTC

## Purpose
Empirical findings from writing and debugging the stack's Bash scripts. Records behaviour that diverged from documentation, assumptions, or prior expectations. See `guidance.md` for prescriptive decisions and `best_practices.md` for vendor recommendations.

---

## Table of Contents

1. [jq Dot-Notation Fails on Hyphenated Keys](#1-jq-dot-notation-fails-on-hyphenated-keys)

---

# 1 jq Dot-Notation Fails on Hyphenated Keys

**Version:** jq 1.6 / jq 1.7  
**Discovered:** 2026-03-08, Phase 7 first-boot

## What Happened
`configure.sh` iterated over service names from `config.json` using a `for svc in ...` loop, then queried each service's fields using jq:

```bash
image=$(jq -r ".services.${svc}.image" "$CONFIG_FILE")
```

For most services this worked. For the service named `knowledge-index` the command returned `null` even though the key existed in the JSON.

Debugging with `set -x` showed jq was receiving the literal string:

```
.services.knowledge-index.image
```

jq parsed the hyphen as a **subtraction operator**: `.services.knowledge` minus `index.image`. No such arithmetic is valid here, so jq returned `null` silently instead of raising an error.

## Root Cause
jq's identity filter uses dot-notation (`field.subfield`) and follows JSON key rules: bare identifiers are unquoted keys, but hyphens are not allowed in bare identifiers. A hyphen in a dot chain is interpreted as the arithmetic minus operator.

The script built the jq filter by interpolating a shell variable directly into a double-quoted string, which gives jq the raw unquoted key path. Any service name with a hyphen breaks this pattern.

Additionally, embedding `$svc` in a double-quoted jq filter string is unsafe: the shell expands the variable before jq sees it, which would allow an attacker-controlled service name to inject arbitrary jq expressions.

## Fix
Use jq's `--arg` flag to pass the service name as a typed string variable, and use the index operator `[]` in a single-quoted filter instead of dot-notation:

```bash
# Before (broken for hyphenated keys, also unsafe)
image=$(jq -r ".services.${svc}.image" "$CONFIG_FILE")

# After (correct and safe)
image=$(jq -r --arg s "$svc" '.services[$s].image' "$CONFIG_FILE")
```

Key points:
- `--arg s "$svc"` binds the shell variable to the jq variable `$s` as a string.
- `.services[$s]` uses the index operator, which correctly handles any key string, including those with hyphens, spaces, or special characters.
- The filter itself is single-quoted, so the shell performs no expansion inside it.

All jq calls in `configure.sh` that reference a service name were updated to this pattern.

## Rule
> **Never interpolate shell variables into jq filter strings.** Always use `--arg name "$value"` (for strings) or `--argjson name "$value"` (for numbers/booleans/objects), and reference them as `$name` inside a single-quoted filter. This is both correct and injection-safe.
