#!/usr/bin/env bats
# testing/layer2_prometheus.bats
#
# Layer 2 — Prometheus Component Integration (T-040 through T-042)
# Validates scrape target list, target health, and the query API.
#
# Prerequisites: Layer 0 and Layer 1 must pass.
# Run: bats testing/layer2_prometheus.bats

load 'helpers'

PROM_URL="http://localhost:9091"

setup_file() {
    local missing=()
    command -v curl &>/dev/null || missing+=(curl)
    command -v jq   &>/dev/null || missing+=(jq)
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 2 Prometheus tests require: ${missing[*]}" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-040 — /api/v1/targets lists all configured scrape targets
# ---------------------------------------------------------------------------

@test "T-040: prometheus /api/v1/targets lists all configured scrape targets" {
    run curl -s --max-time 15 "${PROM_URL}/api/v1/targets"
    [[ "$status" -eq 0 ]] || {
        echo "curl failed (exit $status)" >&3
        return 1
    }

    echo "$output" | jq . >/dev/null 2>&1 || {
        echo "Response is not valid JSON: $output" >&3
        return 1
    }

    local target_count
    target_count=$(echo "$output" | jq '.data.activeTargets | length' 2>/dev/null)
    [[ "$target_count" -ge 1 ]] || {
        echo "No active scrape targets found in Prometheus." >&3
        echo "Check: $AI_STACK_DIR/configs/prometheus/prometheus.yml" >&3
        return 1
    }

    # Confirm expected jobs are present: prometheus self, traefik, litellm, loki
    local expected_jobs=(prometheus traefik litellm loki)
    local missing_jobs=()
    for job in "${expected_jobs[@]}"; do
        echo "$output" | jq -e \
            ".data.activeTargets[] | select(.labels.job == \"$job\")" \
            >/dev/null 2>&1 || missing_jobs+=("$job")
    done

    if [[ "${#missing_jobs[@]}" -gt 0 ]]; then
        echo "Expected scrape jobs not found: ${missing_jobs[*]}" >&3
        echo "Jobs present: $(echo "$output" | jq -r '[.data.activeTargets[].labels.job] | unique | .[]')" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-041 — All scrape targets are healthy
# ---------------------------------------------------------------------------
# Any unhealthy targets are reported with their last error. If a target is
# known to be temporarily unavailable (e.g., vLLM with no GPU), add it to
# KNOWN_DOWN below so the test flags it as an expected warning rather than
# a hard failure.
# ---------------------------------------------------------------------------

KNOWN_DOWN=(vllm llamacpp knowledge-index)

@test "T-041: all prometheus scrape targets are health=up (known-down flagged)" {
    run curl -s --max-time 15 "${PROM_URL}/api/v1/targets"
    [[ "$status" -eq 0 ]] || { echo "curl failed (exit $status)" >&3; return 1; }

    local unhealthy=()
    local unexpected_down=()

    while IFS= read -r target; do
        local job health last_err
        job=$(echo "$target"    | jq -r '.labels.job // "unknown"')
        health=$(echo "$target" | jq -r '.health')
        last_err=$(echo "$target" | jq -r '.lastError // ""')

        if [[ "$health" != "up" ]]; then
            unhealthy+=("$job")
            # Check if this job is in the known-down list
            local known=false
            for kd in "${KNOWN_DOWN[@]}"; do
                [[ "$job" == *"$kd"* ]] && known=true && break
            done
            if ! $known; then
                unexpected_down+=("${job}: ${last_err}")
            else
                echo "# WARN: expected-down target: $job ($last_err)" >&3
            fi
        fi
    done < <(echo "$output" | jq -c '.data.activeTargets[]')

    if [[ "${#unexpected_down[@]}" -gt 0 ]]; then
        echo "Unexpected unhealthy scrape targets:" >&3
        for t in "${unexpected_down[@]}"; do echo "  $t" >&3; done
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-042 — Query API returns a result vector for the 'up' metric
# ---------------------------------------------------------------------------

@test "T-042: prometheus query API returns result vector for 'up' metric" {
    run curl -s --max-time 15 \
        "${PROM_URL}/api/v1/query?query=up"
    [[ "$status" -eq 0 ]] || { echo "curl failed (exit $status)" >&3; return 1; }

    echo "$output" | jq -e '.status == "success"' >/dev/null 2>&1 || {
        echo "Query API did not return status=success: $output" >&3
        return 1
    }

    local result_count
    result_count=$(echo "$output" | jq '.data.result | length' 2>/dev/null)
    [[ "$result_count" -ge 1 ]] || {
        echo "Query for 'up' metric returned empty result set." >&3
        echo "Response: $output" >&3
        return 1
    }
}
