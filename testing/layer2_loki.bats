#!/usr/bin/env bats
# testing/layer2_loki.bats
#
# Layer 2 — Loki Component Integration (T-043 through T-045)
# Validates log push, query round-trip, and retention configuration.
#
# Prerequisites: Layer 0 and Layer 1 must pass.
# Run: bats testing/layer2_loki.bats

load 'helpers'

LOKI_URL="http://localhost:3100"

# Label set used for pushed test entries — unique enough to avoid colliding
# with real log streams.
TEST_JOB="bats_layer2_loki_test"
TEST_LABEL_SELECTOR="{job=\"${TEST_JOB}\"}"

setup_file() {
    local missing=()
    command -v curl &>/dev/null || missing+=(curl)
    command -v jq   &>/dev/null || missing+=(jq)
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 2 Loki tests require: ${missing[*]}" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-043 — Push a test log entry via /loki/api/v1/push → 204
# ---------------------------------------------------------------------------

@test "T-043: loki accepts a log push and returns 204" {
    # Loki expects nanosecond Unix timestamps as strings.
    local ts_ns
    ts_ns=$(date +%s)000000000

    local payload
    payload=$(printf '{"streams":[{"stream":{"job":"%s"},"values":[["%s","bats layer2 test entry"]]}]}' \
        "$TEST_JOB" "$ts_ns")

    run curl -s --max-time 15 \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${LOKI_URL}/loki/api/v1/push"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed (exit $status)" >&3
        return 1
    }
    [[ "$output" == "204" ]] || {
        echo "Expected 204 from Loki push, got: $output" >&3
        echo "Run T-014 first — Loki must be in ready state." >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-044 — Query round-trip: pushed entry appears in query_range
# ---------------------------------------------------------------------------
# Polls for up to 30 seconds to allow Loki's ingester to flush the entry.
# ---------------------------------------------------------------------------

@test "T-044: pushed log entry is retrievable via query_range" {
    # Push a fresh entry with a timestamp we can anchor on
    local ts_ns
    ts_ns=$(date +%s)000000000
    local test_message="bats_roundtrip_$$_$(date +%s)"

    local payload
    payload=$(printf '{"streams":[{"stream":{"job":"%s","test":"roundtrip"},"values":[["%s","%s"]]}]}' \
        "$TEST_JOB" "$ts_ns" "$test_message")

    curl -s --max-time 10 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "${LOKI_URL}/loki/api/v1/push" >/dev/null

    # Calculate query window: 60 seconds around the push timestamp
    local now_s
    now_s=$(date +%s)
    local start_ns=$(( (now_s - 60) ))000000000
    local end_ns=$(( now_s + 10 ))000000000

    # Poll for up to 30 seconds
    local found=false
    for attempt in 1 2 3 4 5 6; do
        local response
        response=$(curl -s --max-time 15 \
            -G "${LOKI_URL}/loki/api/v1/query_range" \
            --data-urlencode "query=${TEST_LABEL_SELECTOR}" \
            --data-urlencode "start=${start_ns}" \
            --data-urlencode "end=${end_ns}" \
            --data-urlencode "limit=20")

        if echo "$response" | grep -qF "$test_message"; then
            found=true
            break
        fi
        sleep 5
    done

    if ! $found; then
        echo "Log entry '$test_message' not found in Loki after 30s." >&3
        echo "Check Loki ingester configuration and retention settings." >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-045 — Retention configuration is readable from /config endpoint
# ---------------------------------------------------------------------------

@test "T-045: loki /config shows expected retention_period of 168h" {
    run curl -s --max-time 15 "${LOKI_URL}/config"
    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to Loki /config (exit $status)" >&3
        return 1
    }

    # /config returns YAML. Search for the retention_period value.
    echo "$output" | grep -q "retention_period" || {
        echo "retention_period key not found in /config output." >&3
        echo "First 30 lines of response:" >&3
        echo "$output" | head -30 >&3
        return 1
    }

    echo "$output" | grep "retention_period" | grep -q "168h" || {
        echo "Expected retention_period: 168h but found:" >&3
        echo "$output" | grep "retention_period" >&3
        return 1
    }
}
