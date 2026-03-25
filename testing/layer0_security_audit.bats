#!/usr/bin/env bats
# testing/layer0_security_audit.bats
#
# Layer 0 — Security Audit Tool Tests (T-113 through T-116)
# Validates the `configure.sh security-audit` subcommand.
#
# These tests do NOT require live services — they use --skip-network and
# a synthetic minimal config to exercise the audit logic offline.
#
# Run: bats testing/layer0_security_audit.bats
# All layers: bats testing/

load 'helpers'

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

CONFIGURE="${PROJECT_ROOT:-$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)}/scripts/configure.sh"
FIXTURES_DIR="${BATS_TMPDIR}/security_audit_fixtures"

# ---------------------------------------------------------------------------
# setup / teardown
# ---------------------------------------------------------------------------

setup_file() {
    local missing=()
    command -v jq   &>/dev/null || missing+=(jq)
    command -v bash &>/dev/null || missing+=(bash)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: layer0_security_audit requires: ${missing[*]}" >&3
        return 1
    fi

    mkdir -p "${FIXTURES_DIR}"

    # Minimal config.json — all services bound to 127.0.0.1 → should produce no CRITICAL
    cat > "${FIXTURES_DIR}/config_clean.json" <<'EOF'
{
  "services": {
    "traefik":          { "ports": [{"host": 80,   "container": 80,   "bind": "0.0.0.0"},
                                    {"host": 443,  "container": 443,  "bind": "0.0.0.0"},
                                    {"host": 8080, "container": 8080, "bind": "127.0.0.1"}] },
    "litellm":          { "ports": [{"host": 9000, "container": 9000, "bind": "127.0.0.1"}] },
    "qdrant":           { "ports": [{"host": 6333, "container": 6333, "bind": "127.0.0.1"}] },
    "knowledge-index":  { "ports": [{"host": 8100, "container": 8100, "bind": "127.0.0.1"}] },
    "flowise":          { "ports": [{"host": 3001, "container": 3001, "bind": "127.0.0.1"}] },
    "openwebui":        { "ports": [{"host": 9090, "container": 9090, "bind": "127.0.0.1"}] },
    "postgres":         { "ports": [{"host": 5432, "container": 5432, "bind": "127.0.0.1"}] }
  }
}
EOF

    # Config with ollama bound to 0.0.0.0 → should produce WARNING
    cat > "${FIXTURES_DIR}/config_ollama_exposed.json" <<'EOF'
{
  "services": {
    "ollama": { "ports": [{"host": 11434, "container": 11434, "bind": "0.0.0.0"}] }
  }
}
EOF

    # Config with a postgres port bound to 0.0.0.0 → should produce CRITICAL
    cat > "${FIXTURES_DIR}/config_postgres_exposed.json" <<'EOF'
{
  "services": {
    "postgres": { "ports": [{"host": 5432, "container": 5432, "bind": "0.0.0.0"}] }
  }
}
EOF

    # Config with a plaintext API key → should produce CRITICAL via secret hygiene
    cat > "${FIXTURES_DIR}/config_plaintext_secret.json" <<'EOF'
{
  "services": {},
  "admin_api_key": "supersecretvalue1234"
}
EOF
}

teardown_file() {
    rm -rf "${FIXTURES_DIR}"
}

# ---------------------------------------------------------------------------
# T-113: --help exits 0 and prints usage
# ---------------------------------------------------------------------------

@test "T-113: security-audit --help exits 0 and prints usage" {
    run bash "${CONFIGURE}" security-audit --help
    if [[ "$status" -ne 0 ]]; then
        echo "Expected exit 0, got $status" >&3
        return 1
    fi
    if [[ "$output" != *"configure.sh security-audit"* ]]; then
        echo "Usage text missing 'configure.sh security-audit'" >&3
        echo "Output: $output" >&3
        return 1
    fi
    if [[ "$output" != *"--json"* ]] || [[ "$output" != *"--skip-network"* ]]; then
        echo "Usage text missing --json or --skip-network flags" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-114: --json produces valid JSON
# ---------------------------------------------------------------------------

@test "T-114: security-audit --json emits valid JSON array" {
    # Use the clean fixture (no exposed ports, no secrets) with --skip-network
    # Override CONFIG_FILE to point at our fixture
    run env CONFIG_FILE="${FIXTURES_DIR}/config_clean.json" \
        bash "${CONFIGURE}" security-audit --json --skip-network
    # exit code may be 0 (all OK) or 1 (warnings) but MUST be valid JSON
    if ! echo "$output" | jq . >/dev/null 2>&1; then
        echo "Output is not valid JSON (exit $status)" >&3
        echo "Output: $output" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-115: plaintext secret in config.json emits CRITICAL and exits 2
# ---------------------------------------------------------------------------

@test "T-115: plaintext secret in config.json produces CRITICAL finding" {
    run env CONFIG_FILE="${FIXTURES_DIR}/config_plaintext_secret.json" \
        bash "${CONFIGURE}" security-audit --skip-network
    if [[ "$status" -ne 2 ]]; then
        echo "Expected exit 2 (CRITICAL), got $status" >&3
        echo "Output: $output" >&3
        return 1
    fi
    if [[ "$output" != *"CRITICAL"* ]]; then
        echo "Expected CRITICAL in output, not found" >&3
        echo "Output: $output" >&3
        return 1
    fi
    if [[ "$output" != *"api_key"* ]]; then
        echo "Expected 'api_key' referenced in output, not found" >&3
        echo "Output: $output" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-116: clean config with all ports on 127.0.0.1 has no CRITICAL findings
# ---------------------------------------------------------------------------

@test "T-116: clean config (all ports 127.0.0.1, no secrets) produces no CRITICAL" {
    run env CONFIG_FILE="${FIXTURES_DIR}/config_clean.json" \
        bash "${CONFIGURE}" security-audit --skip-network
    if [[ "$status" -eq 2 ]]; then
        echo "Expected no CRITICAL findings (exit 0 or 1), got exit 2" >&3
        echo "Output: $output" >&3
        return 1
    fi
    if [[ "$output" == *"CRITICAL"* ]]; then
        echo "Unexpected CRITICAL finding in clean config" >&3
        echo "Output: $output" >&3
        return 1
    fi
}
