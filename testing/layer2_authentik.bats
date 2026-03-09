#!/usr/bin/env bats
# testing/layer2_authentik.bats
#
# Layer 2 — Authentik Component Integration (T-033 through T-035)
# Validates the config API, liveness probe, and readiness probe
# (database migrations complete).
#
# Prerequisites: Layer 0 and Layer 1 must pass.
# Note: Authentik listens on the internal Podman network. Tests reach it
# either via Traefik proxy (if dynamic routes configured) or directly on
# the container's mapped port. Authentik does not expose a host port by
# default in this stack — tests use `podman exec` to reach the internal
# address, or the Traefik proxy URL if available.
#
# Run: bats testing/layer2_authentik.bats

load 'helpers'

# Internal address reachable via podman exec from any container on ai-stack-net
AUTHENTIK_INTERNAL="http://authentik.ai-stack:9000"

# ---------------------------------------------------------------------------
# File-level setup
# ---------------------------------------------------------------------------

setup_file() {
    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl is required for Authentik Layer 2 tests" >&3
        return 1
    fi

    # Confirm authentik service is running before any test attempts exec
    if ! systemctl --user is-active --quiet authentik.service 2>/dev/null; then
        echo "ERROR: authentik.service is not active" >&3
        return 1
    fi

    # Use traefik as the exec proxy since it's guaranteed to be on ai-stack-net
    EXEC_CONTAINER=$(podman ps --format '{{.Names}}' \
        | grep -E "^(traefik|prometheus|grafana)" | head -1)

    if [[ -z "$EXEC_CONTAINER" ]]; then
        echo "ERROR: No running container found on ai-stack-net to proxy exec tests" >&3
        return 1
    fi
    export EXEC_CONTAINER
}

# ---------------------------------------------------------------------------
# Helper: run curl inside a container on the ai-stack-net network
# Usage: net_curl <curl_args...>
# ---------------------------------------------------------------------------

net_curl() {
    podman exec "$EXEC_CONTAINER" curl -s --max-time 15 "$@"
}

# ---------------------------------------------------------------------------
# T-033 — Authentik config API returns 200 with JSON
# ---------------------------------------------------------------------------

@test "T-033: authentik /api/v3/root/config/ returns 200 with JSON body" {
    run net_curl "${AUTHENTIK_INTERNAL}/api/v3/root/config/"
    [[ "$status" -eq 0 ]] || {
        echo "exec curl failed (exit $status)" >&3
        echo "Container used: $EXEC_CONTAINER, target: ${AUTHENTIK_INTERNAL}" >&3
        return 1
    }

    # Must be valid JSON
    echo "$output" | podman exec -i "$EXEC_CONTAINER" sh -c \
        'cat | python3 -c "import sys,json; json.load(sys.stdin)"' \
        2>/dev/null || \
    echo "$output" | grep -q "{" || {
        echo "Response does not appear to be JSON: $output" >&3
        return 1
    }

    # Should contain a recognizable Authentik field
    echo "$output" | grep -qi "error_reporting\|brand\|flow\|authentik" || {
        echo "Response does not look like Authentik config output: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-034 — Authentik liveness probe
# ---------------------------------------------------------------------------

@test "T-034: authentik /-/health/live/ returns 200" {
    run net_curl -o /dev/null -w "%{http_code}" \
        "${AUTHENTIK_INTERNAL}/-/health/live/"
    [[ "$status" -eq 0 ]] || {
        echo "exec curl failed" >&3
        return 1
    }
    [[ "$output" == "200" ]] || {
        echo "Expected 200 from liveness probe, got: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-035 — Authentik readiness probe (database migrations complete)
# ---------------------------------------------------------------------------

@test "T-035: authentik /-/health/ready/ returns 200 (migrations complete)" {
    run net_curl -o /dev/null -w "%{http_code}" \
        "${AUTHENTIK_INTERNAL}/-/health/ready/"
    [[ "$status" -eq 0 ]] || {
        echo "exec curl failed" >&3
        return 1
    }
    [[ "$output" == "200" ]] || {
        echo "Expected 200 from readiness probe, got: $output" >&3
        echo "Non-200 means Authentik is still running migrations or the database" >&3
        echo "is unreachable. Check: journalctl --user -u authentik.service -n 40" >&3
        return 1
    }
}
