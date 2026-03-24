#!/usr/bin/env bats
# testing/layer2_grafana.bats
#
# Layer 2 — Grafana Component Integration (T-036 through T-039)
# Validates login, provisioned datasources, and datasource health for
# both Prometheus and Loki.
#
# Prerequisites: Layer 0 and Layer 1 must pass.
# Run: bats testing/layer2_grafana.bats

load 'helpers'

GRAFANA_URL="http://localhost:${GRAFANA_PORT}"

# ---------------------------------------------------------------------------
# File-level setup: resolve auth token once for the whole file
# ---------------------------------------------------------------------------

setup_file() {
    local missing=()
    command -v curl &>/dev/null || missing+=(curl)
    command -v jq   &>/dev/null || missing+=(jq)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 2 Grafana tests require: ${missing[*]}" >&3
        return 1
    fi

    # Attempt login with admin/admin (default from grafana.ini).
    # If credentials have been rotated, set GRAFANA_USER / GRAFANA_PASS env vars.
    local grafana_user="${GRAFANA_USER:-admin}"
    local grafana_pass="${GRAFANA_PASS:-admin}"

    local login_response
    login_response=$(curl -s --max-time 10 \
        -H "Content-Type: application/json" \
        -d "{\"user\":\"${grafana_user}\",\"password\":\"${grafana_pass}\"}" \
        "${GRAFANA_URL}/api/login")

    GRAFANA_TOKEN=$(echo "$login_response" | jq -r '.token // empty' 2>/dev/null)

    # Some Grafana versions return a cookie session instead of a token;
    # fall back to basic auth for subsequent requests in that case.
    if [[ -z "$GRAFANA_TOKEN" ]]; then
        GRAFANA_AUTH_HEADER="Authorization: Basic $(
            printf '%s:%s' "$grafana_user" "$grafana_pass" | base64 -w0
        )"
    else
        GRAFANA_AUTH_HEADER="Authorization: Bearer $GRAFANA_TOKEN"
    fi

    export GRAFANA_TOKEN GRAFANA_AUTH_HEADER GRAFANA_USER=admin GRAFANA_PASS=admin
}

# ---------------------------------------------------------------------------
# Helper: authenticated Grafana request
# Usage: grafana_curl <curl_args...>
# ---------------------------------------------------------------------------

grafana_curl() {
    curl -s --max-time 15 -H "$GRAFANA_AUTH_HEADER" "$@"
}

# ---------------------------------------------------------------------------
# T-036 — Grafana login API returns a session or token
# ---------------------------------------------------------------------------

@test "T-036: grafana login API accepts admin credentials" {
    local grafana_user="${GRAFANA_USER:-admin}"
    local grafana_pass="${GRAFANA_PASS:-admin}"

    run curl -s --max-time 10 \
        -H "Content-Type: application/json" \
        -d "{\"user\":\"${grafana_user}\",\"password\":\"${grafana_pass}\"}" \
        "${GRAFANA_URL}/api/login"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to Grafana (exit $status)" >&3
        return 1
    }

    # A successful login returns JSON with at least one of: token, message:"Logged in"
    echo "$output" | jq . >/dev/null 2>&1 || {
        echo "Response is not valid JSON: $output" >&3
        return 1
    }

    echo "$output" | grep -qi '"token"\|"Logged in"\|"message"' || {
        echo "Unexpected login response: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-037 — Provisioned datasources include Prometheus and Loki
# ---------------------------------------------------------------------------

@test "T-037: grafana datasources include Prometheus and Loki" {
    run grafana_curl "${GRAFANA_URL}/api/datasources"
    [[ "$status" -eq 0 ]] || { echo "curl failed (exit $status)" >&3; return 1; }

    echo "$output" | jq . >/dev/null 2>&1 || {
        echo "Response is not valid JSON: $output" >&3
        return 1
    }

    echo "$output" | jq -e '[.[].type] | map(. == "prometheus") | any' \
        >/dev/null 2>&1 || {
        echo "Prometheus datasource not found in Grafana." >&3
        echo "Check: $AI_STACK_DIR/configs/grafana/provisioning/datasources/datasources.yaml" >&3
        return 1
    }

    echo "$output" | jq -e '[.[].type] | map(. == "loki") | any' \
        >/dev/null 2>&1 || {
        echo "Loki datasource not found in Grafana." >&3
        echo "Check: $AI_STACK_DIR/configs/grafana/provisioning/datasources/datasources.yaml" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-038 — Prometheus datasource health check
# ---------------------------------------------------------------------------

@test "T-038: grafana Prometheus datasource health check returns OK" {
    # Get the Prometheus datasource UID
    local ds_uid
    ds_uid=$(grafana_curl "${GRAFANA_URL}/api/datasources" \
        | jq -r '.[] | select(.type == "prometheus") | .uid' 2>/dev/null)

    if [[ -z "$ds_uid" ]] || [[ "$ds_uid" == "null" ]]; then
        skip "Prometheus datasource not provisioned — T-037 must pass first"
    fi

    run grafana_curl "${GRAFANA_URL}/api/datasources/uid/${ds_uid}/health"
    [[ "$status" -eq 0 ]] || { echo "curl failed (exit $status)" >&3; return 1; }

    echo "$output" | jq -e '.status == "OK"' >/dev/null 2>&1 || {
        echo "Prometheus datasource health check failed." >&3
        echo "Response: $output" >&3
        echo "Is Prometheus running and reachable at prometheus.ai-stack:9090?" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-039 — Loki datasource health check
# ---------------------------------------------------------------------------

@test "T-039: grafana Loki datasource health check returns OK" {
    local ds_uid
    ds_uid=$(grafana_curl "${GRAFANA_URL}/api/datasources" \
        | jq -r '.[] | select(.type == "loki") | .uid' 2>/dev/null)

    if [[ -z "$ds_uid" ]] || [[ "$ds_uid" == "null" ]]; then
        skip "Loki datasource not provisioned — T-037 must pass first"
    fi

    run grafana_curl "${GRAFANA_URL}/api/datasources/uid/${ds_uid}/health"
    [[ "$status" -eq 0 ]] || { echo "curl failed (exit $status)" >&3; return 1; }

    echo "$output" | jq -e '.status == "OK"' >/dev/null 2>&1 || {
        echo "Loki datasource health check failed." >&3
        echo "Response: $output" >&3
        echo "Is Loki running and reachable at loki.ai-stack:3100?" >&3
        return 1
    }
}
