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
# Port variables — loaded from config.json at suite startup
# ---------------------------------------------------------------------------
# A single Python call reads every service's host-port from config.json and
# exports named variables. A port remap in config.json automatically flows
# through to all tests — no manual grep-and-update required.
# Falls back to sensible defaults if config.json is absent (e.g. CI lint).
# ---------------------------------------------------------------------------
if [[ -f "$CONFIG_FILE" ]] && command -v python3 &>/dev/null; then
    _port_exports=$(python3 - "$CONFIG_FILE" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    c = json.load(f)
svcs = c.get("services", {})
# (var_name, service_key, port_index)
mappings = [
    ("TRAEFIK_HTTP_PORT",    "traefik",          0),
    ("TRAEFIK_HTTPS_PORT",   "traefik",          1),
    ("TRAEFIK_API_PORT",     "traefik",          2),
    ("POSTGRES_PORT",        "postgres",         0),
    ("QDRANT_PORT",          "qdrant",           0),
    ("KNOWLEDGE_INDEX_PORT", "knowledge-index",  0),
    ("LITELLM_PORT",         "litellm",          0),
    ("FLOWISE_PORT",         "flowise",          0),
    ("OPENWEBUI_PORT",       "openwebui",        0),
    ("PROMETHEUS_PORT",      "prometheus",       0),
    ("GRAFANA_PORT",         "grafana",          0),
    ("LOKI_PORT",            "loki",             0),
    ("MINIO_PORT",           "minio",            0),
    ("MINIO_CONSOLE_PORT",   "minio",            1),
]
for var, svc, idx in mappings:
    try:
        val = svcs[svc]["ports"][idx]["host"]
        print(f"export {var}={val}")
    except (KeyError, IndexError):
        pass
PYEOF
)
    eval "$_port_exports"
fi
# Defaults for environments where config.json is unavailable
export TRAEFIK_HTTP_PORT="${TRAEFIK_HTTP_PORT:-80}"
export TRAEFIK_HTTPS_PORT="${TRAEFIK_HTTPS_PORT:-443}"
export TRAEFIK_API_PORT="${TRAEFIK_API_PORT:-8080}"
export POSTGRES_PORT="${POSTGRES_PORT:-5432}"
export QDRANT_PORT="${QDRANT_PORT:-6333}"
export KNOWLEDGE_INDEX_PORT="${KNOWLEDGE_INDEX_PORT:-8100}"
export LITELLM_PORT="${LITELLM_PORT:-9000}"
export FLOWISE_PORT="${FLOWISE_PORT:-3001}"
export OPENWEBUI_PORT="${OPENWEBUI_PORT:-9090}"
export PROMETHEUS_PORT="${PROMETHEUS_PORT:-9091}"
export GRAFANA_PORT="${GRAFANA_PORT:-3000}"
export LOKI_PORT="${LOKI_PORT:-3100}"
export MINIO_PORT="${MINIO_PORT:-9100}"
export MINIO_CONSOLE_PORT="${MINIO_CONSOLE_PORT:-9101}"

# ---------------------------------------------------------------------------
# Service lists
# ---------------------------------------------------------------------------

# All 15 services defined in configs/config.json
SERVICES_ALL=(
    authentik flowise grafana knowledge-index litellm
    loki minio ollama openwebui postgres prometheus promtail qdrant traefik vllm
)
export SERVICES_ALL

# Controller-profile services expected to be active (non-GPU, non-worker-only)
SERVICES_DEPLOYED=(
    authentik flowise grafana knowledge-index litellm loki
    minio openwebui postgres prometheus promtail qdrant traefik
)
export SERVICES_DEPLOYED

# Services requiring GPU hardware or worker-node profile; checked separately
SERVICES_DEFERRED=(ollama vllm)
export SERVICES_DEFERRED

# ---------------------------------------------------------------------------
# Secret names
# ---------------------------------------------------------------------------

SECRETS=(
    authentik_secret_key flowise_password knowledge_index_api_key
    litellm_master_key minio_root_password minio_root_user
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
