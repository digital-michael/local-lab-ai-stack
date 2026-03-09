#!/usr/bin/env bats
# testing/layer0_preflight.bats
#
# Layer 0 — Pre-flight Checks (T-001 through T-008)
# Verifies host environment, quadlet files, service states, secrets, network,
# and TLS certificate validity before any functional tests run.
#
# Run: bats testing/layer0_preflight.bats
# All layers: bats testing/

load 'helpers'

# ---------------------------------------------------------------------------
# File-level setup: verify required tools are present
# ---------------------------------------------------------------------------

setup_file() {
    local missing=()
    command -v podman    &>/dev/null || missing+=(podman)
    command -v systemctl &>/dev/null || missing+=(systemctl)
    command -v openssl   &>/dev/null || missing+=(openssl)
    command -v jq        &>/dev/null || missing+=(jq)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 0 requires: ${missing[*]}" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-001 — Quadlet .container files exist for all configured services
# ---------------------------------------------------------------------------

@test "T-001: quadlet .container files exist for all 14 services" {
    local quadlet_dir="$HOME/.config/containers/systemd"
    local missing=()

    for svc in "${SERVICES_ALL[@]}"; do
        [[ -f "$quadlet_dir/${svc}.container" ]] || missing+=("$svc")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "Missing quadlet files for: ${missing[*]}" >&3
        echo "Run scripts/deploy-stack.sh to generate quadlets." >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-002 — All deployed services are active (running)
# ---------------------------------------------------------------------------

@test "T-002: all deployed services are active" {
    local not_active=()

    for svc in "${SERVICES_DEPLOYED[@]}"; do
        if ! systemctl --user is-active --quiet "${svc}.service" 2>/dev/null; then
            not_active+=("$svc")
        fi
    done

    if [[ "${#not_active[@]}" -gt 0 ]]; then
        echo "Services not active: ${not_active[*]}" >&3
        for svc in "${not_active[@]}"; do
            echo "  ${svc}: $(systemctl --user show -p ActiveState --value "${svc}.service")" >&3
        done
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-003 — No deployed service is in failed state
# ---------------------------------------------------------------------------

@test "T-003: no deployed service is in failed state" {
    local failed=()

    for svc in "${SERVICES_DEPLOYED[@]}"; do
        local state
        state=$(systemctl --user show -p ActiveState --value "${svc}.service" 2>/dev/null)
        [[ "$state" == "failed" ]] && failed+=("$svc")
    done

    if [[ "${#failed[@]}" -gt 0 ]]; then
        echo "Services in failed state: ${failed[*]}" >&3
        for svc in "${failed[@]}"; do
            echo "--- ${svc} journal (last 20 lines) ---" >&3
            journalctl --user -u "${svc}.service" -n 20 --no-pager 2>/dev/null >&3
        done
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-004 — All required Podman secrets exist and are readable
# ---------------------------------------------------------------------------

@test "T-004: all required Podman secrets exist" {
    local missing=()

    for secret in "${SECRETS[@]}"; do
        if ! podman secret inspect "$secret" &>/dev/null; then
            missing+=("$secret")
        fi
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "Missing secrets: ${missing[*]}" >&3
        echo "Provision with: echo '<value>' | podman secret create <name> -" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-005 — ai-stack Podman network exists
# ---------------------------------------------------------------------------

@test "T-005: ai-stack Podman network exists" {
    run podman network inspect ai-stack-net
    if [[ "$status" -ne 0 ]]; then
        echo "Network 'ai-stack-net' not found." >&3
        echo "Run: podman network create ai-stack-net" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-006 — TLS certificate files are present at expected paths
# ---------------------------------------------------------------------------

@test "T-006: TLS certificate and key files exist" {
    local cert="$AI_STACK_DIR/configs/tls/cert.pem"
    local key="$AI_STACK_DIR/configs/tls/key.pem"

    assert_file_exists "$cert"
    assert_file_exists "$key"
}

# ---------------------------------------------------------------------------
# T-007 — TLS certificate is not expired
# ---------------------------------------------------------------------------

@test "T-007: TLS certificate is not expired" {
    local cert="$AI_STACK_DIR/configs/tls/cert.pem"

    if [[ ! -f "$cert" ]]; then
        skip "cert.pem not found — T-006 must pass first"
    fi

    run openssl x509 -noout -checkend 0 -in "$cert"
    if [[ "$status" -ne 0 ]]; then
        local expiry
        expiry=$(openssl x509 -noout -enddate -in "$cert" 2>/dev/null | cut -d= -f2)
        echo "TLS certificate has expired. Expiry: $expiry" >&3
        echo "Regenerate: openssl req -x509 -newkey rsa:4096 -keyout key.pem -out cert.pem -days 365 -nodes" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-008 — configure.sh is idempotent (re-run produces same quadlet count)
# ---------------------------------------------------------------------------

@test "T-008: configure.sh re-run produces quadlets without error" {
    local quadlet_dir="$HOME/.config/containers/systemd"
    local before after

    before=$(find "$quadlet_dir" -name "*.container" | wc -l)

    run bash "$PROJECT_ROOT/scripts/configure.sh"
    if [[ "$status" -ne 0 ]]; then
        echo "configure.sh exited with status $status" >&3
        echo "$output" >&3
        return 1
    fi

    after=$(find "$quadlet_dir" -name "*.container" | wc -l)

    if [[ "$before" -ne "$after" ]]; then
        echo "Quadlet count changed after re-run: before=$before after=$after" >&3
        return 1
    fi
}
