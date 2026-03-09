#!/usr/bin/env bats
# testing/layer2_flowise.bats
#
# Layer 2 — Flowise Component Integration (T-048 through T-049)
# Validates the chatflows API and authentication enforcement.
#
# Prerequisites: Layer 0 and Layer 1 must pass.
# Run: bats testing/layer2_flowise.bats

load 'helpers'

FLOWISE_URL="http://localhost:3001"

setup_file() {
    local missing=()
    command -v curl &>/dev/null || missing+=(curl)
    command -v jq   &>/dev/null || missing+=(jq)
    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 2 Flowise tests require: ${missing[*]}" >&3
        return 1
    fi

    # Resolve Flowise password for authenticated requests.
    FLOWISE_PASS=$(read_secret "flowise_password")
    if [[ -z "$FLOWISE_PASS" ]]; then
        echo "ERROR: Could not read 'flowise_password' secret." >&3
        return 1
    fi

    # Build basic-auth header: Flowise uses username "user" by default.
    FLOWISE_USER="${FLOWISE_USER:-user}"
    FLOWISE_AUTH_HEADER="Authorization: Basic $(
        printf '%s:%s' "$FLOWISE_USER" "$FLOWISE_PASS" | base64 -w0
    )"
    export FLOWISE_PASS FLOWISE_USER FLOWISE_AUTH_HEADER
}

# ---------------------------------------------------------------------------
# T-048 — GET /api/v1/chatflows returns a JSON array
# ---------------------------------------------------------------------------
# An empty array is a valid response when no chatflows have been created yet.
# The key assertion is that the endpoint responds and returns parseable JSON.
# ---------------------------------------------------------------------------

@test "T-048: flowise GET /api/v1/chatflows returns 200 JSON array" {
    run curl -s --max-time 15 \
        -H "$FLOWISE_AUTH_HEADER" \
        "${FLOWISE_URL}/api/v1/chatflows"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to Flowise (exit $status)" >&3
        return 1
    }

    echo "$output" | jq . >/dev/null 2>&1 || {
        echo "Response is not valid JSON: $output" >&3
        return 1
    }

    echo "$output" | jq -e 'type == "array"' >/dev/null 2>&1 || {
        echo "Expected a JSON array, got: $(echo "$output" | jq 'type')" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-049 — Unauthenticated request is rejected with 401
# ---------------------------------------------------------------------------

@test "T-049: flowise rejects unauthenticated request with 401" {
    run curl -s --max-time 15 \
        -o /dev/null \
        -w "%{http_code}" \
        "${FLOWISE_URL}/api/v1/chatflows"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed (exit $status)" >&3
        return 1
    }

    [[ "$output" == "401" ]] || {
        echo "Expected 401 for unauthenticated Flowise request, got: $output" >&3
        echo "Flowise password auth may not be enabled." >&3
        echo "Set FLOWISE_PASSWORD env var in the flowise container." >&3
        return 1
    }
}
