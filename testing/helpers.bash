# testing/helpers.bash
# Shared environment variables and helper functions for all BATS test suites.
# Loaded by test files via: load 'helpers'
#
# Requires: BATS v1.2+ (bats-core)

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

export AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"

# Project root is one level above this helpers.bash file (testing/../)
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PROJECT_ROOT
export CONFIG_FILE="$PROJECT_ROOT/configs/config.json"

# ---------------------------------------------------------------------------
# Service lists
# ---------------------------------------------------------------------------

# All 14 services defined in configs/config.json
SERVICES_ALL=(
    authentik flowise grafana knowledge-index litellm
    loki ollama openwebui postgres prometheus promtail qdrant traefik vllm
)
export SERVICES_ALL

# 12 services deployable without GPU or custom-built image
SERVICES_DEPLOYED=(
    authentik flowise grafana litellm loki
    ollama openwebui postgres prometheus promtail qdrant traefik
)
export SERVICES_DEPLOYED

# Services deferred pending GPU availability or custom image build
SERVICES_DEFERRED=(knowledge-index vllm)
export SERVICES_DEFERRED

# ---------------------------------------------------------------------------
# Secret names
# ---------------------------------------------------------------------------

SECRETS=(
    authentik_secret_key flowise_password litellm_master_key
    openwebui_api_key postgres_password qdrant_api_key
)
export SECRETS

# ---------------------------------------------------------------------------
# Helper: assert a file path exists
# ---------------------------------------------------------------------------
# Usage: assert_file_exists "/path/to/file"
assert_file_exists() {
    local path="$1"
    if [[ ! -f "$path" ]]; then
        echo "Expected file not found: $path" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Helper: assert HTTP status code
# ---------------------------------------------------------------------------
# Usage: assert_http_status <expected_code> <url> [extra_curl_args...]
# Example: assert_http_status "200" "http://localhost:9091/-/healthy"
# Example: assert_http_status "301" "http://localhost/"
assert_http_status() {
    local expected="$1"; shift
    local url="$1"; shift
    run curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$@" "$url"
    if [[ "$status" -ne 0 ]]; then
        echo "curl failed (exit $status) connecting to $url" >&2
        return 1
    fi
    if [[ "$output" != "$expected" ]]; then
        echo "Expected HTTP $expected, got HTTP $output for $url" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Helper: assert HTTP response body contains a substring
# ---------------------------------------------------------------------------
# Usage: assert_http_body_contains <url> <pattern> [extra_curl_args...]
# Example: assert_http_body_contains "http://localhost:3000/api/health" '"database":"ok"'
assert_http_body_contains() {
    local url="$1"
    local pattern="$2"
    shift 2
    run curl -s --max-time 10 "$@" "$url"
    if [[ "$status" -ne 0 ]]; then
        echo "curl failed (exit $status) connecting to $url" >&2
        return 1
    fi
    if [[ "$output" != *"$pattern"* ]]; then
        echo "Pattern '$pattern' not found in response from $url" >&2
        echo "Response body: $output" >&2
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Helper: return raw HTTP status code (does not use BATS run)
# ---------------------------------------------------------------------------
# Usage: code=$(http_status "http://localhost:3000/")
http_status() {
    curl -s --max-time 10 -o /dev/null -w "%{http_code}" "$@"
}

# ---------------------------------------------------------------------------
# Helper: read a Podman secret value
# ---------------------------------------------------------------------------
# Usage: value=$(read_secret "postgres_password")
#
# Checks for an environment variable override first (name uppercased, e.g.
# POSTGRES_PASSWORD for postgres_password), then falls back to mounting the
# secret into a temporary alpine container.
#
# Requires: alpine image available locally for the fallback path.
read_secret() {
    local name="$1"
    local env_var="${name^^}"          # bash 4+ case-modification
    local env_val="${!env_var:-}"
    if [[ -n "$env_val" ]]; then
        echo "$env_val"
        return 0
    fi
    podman run --rm --secret "$name" \
        docker.io/library/alpine:latest \
        sh -c "cat /run/secrets/$name" 2>/dev/null
}

# ---------------------------------------------------------------------------
# Helper: fail <message>
# ---------------------------------------------------------------------------
# Compatibility shim for bats-assert's fail() — not installed on the host.
# Prints message to fd 3 (captured by BATS) and returns 1 to fail the test.
# ---------------------------------------------------------------------------
fail() {
    echo "$*" >&3
    return 1
}

# ---------------------------------------------------------------------------
# Helper: probe_node <host> <port>
# ---------------------------------------------------------------------------
# Returns 0 if a TCP connection to <host>:<port> succeeds within 5 seconds,
# 1 otherwise. Used to gate remote-node tests.
#
# Usage:
#   probe_node "TC25.mynetworksettings.com" 11434 && echo "reachable"
#   if ! probe_node "$host" "$port"; then skip "node unreachable"; fi
probe_node() {
    local host="$1"
    local port="$2"
    # bash /dev/tcp is not available in all shells; use curl --connect-timeout
    curl -s --connect-timeout 5 --max-time 5 \
        -o /dev/null "http://${host}:${port}/" 2>/dev/null
    # treat 0 (200-level) or 22 (HTTP error — server responded) as reachable
    local rc=$?
    [[ "$rc" -eq 0 || "$rc" -eq 22 ]]
}
