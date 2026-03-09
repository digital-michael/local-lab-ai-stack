#!/usr/bin/env bats
# testing/layer2_promtail.bats
#
# Layer 2 — Promtail Component Integration (T-046 through T-047)
# Validates the metrics endpoint and end-to-end log shipping to Loki.
#
# Prerequisites:
#   - Layer 0 and Layer 1 must pass.
#   - Loki T-043/T-044 should pass first (Loki must be receiving logs).
#
# Note: Promtail does not expose a host port in this stack. Tests reach it
# via `podman exec` on the ai-stack-net network.
#
# Run: bats testing/layer2_promtail.bats

load 'helpers'

PROMTAIL_INTERNAL="http://promtail.ai-stack:9080"
LOKI_URL="http://localhost:3100"
TEST_LOG_FILE="${AI_STACK_DIR}/logs/promtail_bats_test.log"

setup_file() {
    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl is required for Promtail Layer 2 tests" >&3
        return 1
    fi

    if ! systemctl --user is-active --quiet promtail.service 2>/dev/null; then
        echo "ERROR: promtail.service is not active" >&3
        return 1
    fi

    # Ensure the test log directory exists
    mkdir -p "${AI_STACK_DIR}/logs"

    # Find a running container with curl available to use as exec proxy
    EXEC_CONTAINER=""
    for _ctr in grafana loki openwebui flowise; do
        if podman exec "$_ctr" sh -c 'command -v curl' &>/dev/null 2>&1; then
            EXEC_CONTAINER="$_ctr"
            break
        fi
    done

    if [[ -z "$EXEC_CONTAINER" ]]; then
        echo "ERROR: No container available on ai-stack-net for exec proxy" >&3
        return 1
    fi
    export EXEC_CONTAINER
}

teardown_file() {
    # Remove the test log file written by T-047
    rm -f "$TEST_LOG_FILE"
}

# ---------------------------------------------------------------------------
# T-046 — Promtail /metrics endpoint returns Prometheus metrics
# ---------------------------------------------------------------------------

@test "T-046: promtail /metrics returns Prometheus-formatted metrics" {
    run podman exec "$EXEC_CONTAINER" \
        curl -s --max-time 15 "${PROMTAIL_INTERNAL}/metrics"

    [[ "$status" -eq 0 ]] || {
        echo "exec curl to ${PROMTAIL_INTERNAL}/metrics failed (exit $status)" >&3
        echo "Is Promtail exposing port 9080 inside the container?" >&3
        return 1
    }

    # Prometheus metrics format begins with HELP/TYPE comment lines
    echo "$output" | grep -q "^# HELP\|^# TYPE" || {
        echo "Response does not look like Prometheus metrics format:" >&3
        echo "$output" | head -10 >&3
        return 1
    }

    # Should include the promtail_build_info metric as a basic sanity check
    echo "$output" | grep -q "promtail_build_info\|promtail_" || {
        echo "No promtail_ metrics found in /metrics output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-047 — Log entry written to watched path appears in Loki
# ---------------------------------------------------------------------------
# Writes a uniquely tagged line to a log file that Promtail is configured to
# watch, then polls Loki's query_range API for the entry. Validates the full
# Promtail → Loki shipping pipeline.
#
# Note: this test depends on Promtail's scrape_configs including a job that
# watches files under $AI_STACK_DIR/logs/. If your Promtail config uses a
# different path, update TEST_LOG_FILE above.
# ---------------------------------------------------------------------------

@test "T-047: log entry written to watched path appears in Loki within 60s" {
    # Ensure the log directory exists (it should from install.sh)
    if [[ ! -d "$(dirname "$TEST_LOG_FILE")" ]]; then
        skip "Log directory $(dirname "$TEST_LOG_FILE") does not exist — check install.sh"
    fi

    # Write a uniquely identifiable log line
    local marker="bats_promtail_e2e_$$_$(date +%s)"
    echo "$marker" >> "$TEST_LOG_FILE"

    # Calculate Loki query window (generous: 120s back to now+30s)
    local now_s
    now_s=$(date +%s)
    local start_ns=$(( (now_s - 120) ))000000000
    local end_ns=$(( now_s + 30 ))000000000

    # Poll Loki for up to 60 seconds
    local found=false
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12; do
        local response
        response=$(curl -s --max-time 15 \
            -G "${LOKI_URL}/loki/api/v1/query_range" \
            --data-urlencode 'query={filename=~".*promtail_bats_test.*"}' \
            --data-urlencode "start=${start_ns}" \
            --data-urlencode "end=${end_ns}" \
            --data-urlencode "limit=50")

        if echo "$response" | grep -qF "$marker"; then
            found=true
            break
        fi
        sleep 5
    done

    if ! $found; then
        echo "Log marker '$marker' not found in Loki after 60s." >&3
        echo "Check Promtail scrape_configs — is it watching $TEST_LOG_FILE?" >&3
        echo "Promtail config: $AI_STACK_DIR/configs/promtail/config.yml" >&3
        return 1
    fi
}
