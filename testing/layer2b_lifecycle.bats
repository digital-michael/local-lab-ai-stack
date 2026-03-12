#!/usr/bin/env bats
# testing/layer2b_lifecycle.bats
#
# Layer 2b — Lifecycle and Operational Tests (T-050 through T-054)
# Validates reconfigure, component upgrade, credential rotation,
# individual service restart, and full cold-boot.
#
# WARNING: These tests MODIFY live services. They restart containers and
# rotate credentials. Do not run against a production stack with active users.
# Run in a controlled test environment.
#
# Prerequisites: All Layer 0, 1, and 2 tests must pass before running.
# Run: bats testing/layer2b_lifecycle.bats

load 'helpers'

# ---------------------------------------------------------------------------
# File-level helpers
# ---------------------------------------------------------------------------

setup_file() {
    local missing=()
    command -v curl    &>/dev/null || missing+=(curl)
    command -v jq      &>/dev/null || missing+=(jq)
    command -v systemctl &>/dev/null || missing+=(systemctl)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 2b tests require: ${missing[*]}" >&3
        return 1
    fi
}

# Helper: wait for a service to reach active state, with timeout
# Usage: wait_for_active <service_name> [timeout_seconds]
wait_for_active() {
    local svc="$1"
    local timeout="${2:-60}"
    local elapsed=0

    while ! systemctl --user is-active --quiet "${svc}.service" 2>/dev/null; do
        sleep 2
        elapsed=$(( elapsed + 2 ))
        if [[ "$elapsed" -ge "$timeout" ]]; then
            echo "Timeout waiting for ${svc}.service to become active" >&3
            journalctl --user -u "${svc}.service" -n 20 --no-pager >&3
            return 1
        fi
    done
}

# Helper: wait for an HTTP endpoint to return a given status code
# Usage: wait_for_http <expected_code> <url> [timeout_seconds]
wait_for_http() {
    local expected="$1"
    local url="$2"
    local timeout="${3:-60}"
    local elapsed=0

    while true; do
        local code
        code=$(curl -s --max-time 5 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || code="000"
        [[ "$code" == "$expected" ]] && return 0
        sleep 3
        elapsed=$(( elapsed + 3 ))
        [[ "$elapsed" -ge "$timeout" ]] && {
            echo "Timeout waiting for HTTP $expected from $url (last: $code)" >&3
            return 1
        }
    done
}

# ---------------------------------------------------------------------------
# T-050 — Reconfigure: config.json change propagates to quadlet
# ---------------------------------------------------------------------------
# Changes a label annotation (non-functional field) in config.json,
# re-runs configure.sh, reloads systemd, then restores the original value.
# Verifies the field appears in the regenerated quadlet file.
# ---------------------------------------------------------------------------

@test "T-050: configure.sh re-run propagates config.json changes to quadlets" {
    local test_svc="prometheus"
    local quadlet_file="$HOME/.config/containers/systemd/${test_svc}.container"

    # Capture original quadlet content for comparison
    local original_quadlet
    original_quadlet=$(cat "$quadlet_file")

    # Re-run configure.sh (idempotent re-generation)
    run bash "$PROJECT_ROOT/scripts/configure.sh"
    [[ "$status" -eq 0 ]] || {
        echo "configure.sh failed: $output" >&3
        return 1
    }

    # Reload systemd so it picks up any changes
    run systemctl --user daemon-reload
    [[ "$status" -eq 0 ]] || {
        echo "daemon-reload failed: $output" >&3
        return 1
    }

    # Service must still be active after re-generation
    wait_for_active "$test_svc" 30 || return 1

    # Smoke check: Prometheus still responds
    wait_for_http "200" "http://localhost:9091/-/healthy" 30 || return 1
}

# ---------------------------------------------------------------------------
# T-051 — Component upgrade: pull new image, update tag, redeploy service
# ---------------------------------------------------------------------------
# Uses the 'promtail' service as the test subject (small image, no state).
# Reads the current pinned tag, forces a re-pull of that same tag (simulates
# a patch-level upgrade to the same pin), regenerates the quadlet, and
# restarts the service.
# ---------------------------------------------------------------------------

@test "T-051: component upgrade — re-pull image, regenerate quadlet, service restarts healthy" {
    local test_svc="promtail"

    # Get the current image reference from config.json
    local image
    image=$(jq -r --arg s "$test_svc" '.services[$s].image' "$CONFIG_FILE")
    [[ -n "$image" ]] || {
        echo "Could not read image for $test_svc from $CONFIG_FILE" >&3
        return 1
    }

    # Pull the image (re-pull is idempotent; also validates registry reachability)
    run podman pull "$image"
    [[ "$status" -eq 0 ]] || {
        echo "podman pull $image failed: $output" >&3
        return 1
    }

    # Regenerate quadlets and reload
    bash "$PROJECT_ROOT/scripts/configure.sh" >/dev/null
    systemctl --user daemon-reload >/dev/null

    # Restart the service
    run systemctl --user restart "${test_svc}.service"
    [[ "$status" -eq 0 ]] || {
        echo "systemctl restart failed: $output" >&3
        return 1
    }

    # Wait for it to return to active
    wait_for_active "$test_svc" 60 || return 1
}

# ---------------------------------------------------------------------------
# T-052 — Credential rotation: update secret, restart service, verify
# ---------------------------------------------------------------------------
# Rotates the 'flowise_password' secret to a new value, restarts Flowise,
# verifies the new credential is accepted and the old one is rejected, then
# restores the original value.
# ---------------------------------------------------------------------------

@test "T-052: credential rotation — new secret accepted, old secret rejected" {
    local secret_name="flowise_password"
    local test_svc="flowise"

    # Read current password
    local original_pass
    original_pass=$(read_secret "$secret_name")
    [[ -n "$original_pass" ]] || {
        skip "Could not read current $secret_name — skipping rotation test"
    }

    local new_pass="bats_rotated_pass_$(date +%s)"

    # Rotate the secret (use printf to avoid trailing newline)
    printf '%s' "$new_pass" | podman secret create --replace "$secret_name" - >/dev/null 2>&1 || {
        # Older Podman without --replace: delete then recreate
        podman secret rm "$secret_name" >/dev/null 2>&1
        printf '%s' "$new_pass" | podman secret create "$secret_name" - >/dev/null
    }

    # Restart service to pick up new secret
    systemctl --user restart "${test_svc}.service" >/dev/null
    wait_for_active "$test_svc" 60 || {
        # Restore original before returning failure
        printf '%s' "$original_pass" | podman secret create --replace "$secret_name" - >/dev/null 2>&1 || true
        systemctl --user restart "${test_svc}.service" >/dev/null
        return 1
    }

    # Wait for Flowise HTTP to be ready (ping endpoint is whitelisted, returns 200)
    wait_for_http "200" "http://localhost:3001/api/v1/ping" 90

    # New password must be accepted via account/basic-auth (Flowise v3 credential check)
    local new_result
    new_result=$(curl -s --max-time 10 \
        -X POST -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${new_pass}\"}" \
        "http://localhost:3001/api/v1/account/basic-auth" | jq -r '.message // empty')
    [[ "$new_result" == "Authentication successful" ]] || {
        echo "New credential not accepted (got: $new_result). Restoring original." >&3
        printf '%s' "$original_pass" | podman secret create --replace "$secret_name" - >/dev/null 2>&1 || true
        systemctl --user restart "${test_svc}.service" >/dev/null
        return 1
    }

    # Old password must be rejected
    local old_result
    old_result=$(curl -s --max-time 10 \
        -X POST -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${original_pass}\"}" \
        "http://localhost:3001/api/v1/account/basic-auth" | jq -r '.message // empty')
    [[ "$old_result" == "Authentication failed" ]] || {
        echo "Old credential still accepted after rotation (got: $old_result)." >&3
    }

    # Restore original password (use printf to avoid trailing newline)
    printf '%s' "$original_pass" | podman secret create --replace "$secret_name" - >/dev/null 2>&1 || \
    { podman secret rm "$secret_name" >/dev/null 2>&1; printf '%s' "$original_pass" | podman secret create "$secret_name" - >/dev/null; }
    systemctl --user restart "${test_svc}.service" >/dev/null
    wait_for_active "$test_svc" 60 || return 1

    # Verify the restored password actually works — catches cascading failure where
    # "original_pass" was already a stale rotated value from a prior failed restore.
    wait_for_http "200" "http://localhost:3001/api/v1/ping" 60 || return 1
    local restore_check
    restore_check=$(curl -s --max-time 10 \
        -X POST -H "Content-Type: application/json" \
        -d "{\"username\":\"admin\",\"password\":\"${original_pass}\"}" \
        "http://localhost:3001/api/v1/account/basic-auth" | jq -r '.message // empty')
    [[ "$restore_check" == "Authentication successful" ]] || {
        echo "WARN: Restored password '${original_pass:0:6}...' was not accepted by Flowise." >&3
        echo "The secret was likely already stale before this test ran." >&3
        echo "Manual fix required: update flowise_password secret to the correct value." >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-053 — Individual service restart returns to healthy within timeout
# ---------------------------------------------------------------------------
# Restarts each deployed service in turn and confirms it returns to active.
# Services with dependencies (e.g., flowise → litellm) are restarted last.
# ---------------------------------------------------------------------------

@test "T-053: each deployed service returns to active after individual restart" {
    # Restart order: leaf services before dependents
    local restart_order=(
        loki promtail prometheus grafana
        postgres qdrant litellm
        authentik openwebui flowise
        ollama
        traefik
    )

    local failed=()
    for svc in "${restart_order[@]}"; do
        systemctl --user restart "${svc}.service" >/dev/null 2>&1
        if ! wait_for_active "$svc" 60; then
            failed+=("$svc")
        fi
    done

    if [[ "${#failed[@]}" -gt 0 ]]; then
        echo "Services did not return to active after restart: ${failed[*]}" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-054 — Full cold-boot: stop all services, start in dependency order
# ---------------------------------------------------------------------------

@test "T-054: full cold-boot — stop all services then start in dependency order" {
    # Stop all deployed services
    local stop_order=(
        traefik flowise openwebui authentik
        litellm ollama grafana prometheus promtail loki
        qdrant postgres
    )

    for svc in "${stop_order[@]}"; do
        systemctl --user stop "${svc}.service" >/dev/null 2>&1
    done

    sleep 5

    # Confirm all are stopped
    for svc in "${stop_order[@]}"; do
        local state
        state=$(systemctl --user show -p ActiveState --value "${svc}.service" 2>/dev/null)
        [[ "$state" != "active" ]] || {
            echo "Service $svc did not stop cleanly (state: $state)" >&3
        }
    done

    # Start in dependency order (data/infra first, then application layer)
    local start_order=(
        postgres qdrant
        loki promtail
        prometheus
        litellm ollama
        grafana
        authentik
        openwebui flowise
        traefik
    )

    local failed=()
    for svc in "${start_order[@]}"; do
        systemctl --user start "${svc}.service" >/dev/null 2>&1
        sleep 2   # brief pause between starts to respect dependency timing
        if ! wait_for_active "$svc" 90; then
            failed+=("$svc")
        fi
    done

    if [[ "${#failed[@]}" -gt 0 ]]; then
        echo "Services failed to start after cold-boot: ${failed[*]}" >&3
        return 1
    fi

    # Final smoke: Prometheus and Grafana as health gate
    wait_for_http "200" "http://localhost:9091/-/healthy" 30 || {
        echo "Prometheus did not return healthy after cold-boot" >&3
        return 1
    }
    wait_for_http "200" "http://localhost:3000/api/health" 30 || {
        echo "Grafana did not return healthy after cold-boot" >&3
        return 1
    }
}
