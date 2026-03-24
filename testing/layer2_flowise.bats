#!/usr/bin/env bats
# testing/layer2_flowise.bats
#
# Layer 2 — Flowise Component Integration (T-048 through T-049)
# Validates the chatflows API and authentication enforcement.
#
# Prerequisites: Layer 0 and Layer 1 must pass.
# Run: bats testing/layer2_flowise.bats

load 'helpers'

FLOWISE_URL="http://localhost:${FLOWISE_PORT}"

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

    # Flowise v3 uses JWT/API-key auth for API calls; FLOWISE_USERNAME/PASSWORD
    # are only used for the web UI login.  The /api/v1/account/basic-auth
    # endpoint (whitelisted) accepts a JSON body and verifies against the env vars.
    FLOWISE_USER="${FLOWISE_USER:-admin}"
    export FLOWISE_PASS FLOWISE_USER
}

# ---------------------------------------------------------------------------
# T-048 — GET /api/v1/chatflows returns a JSON array
# ---------------------------------------------------------------------------
# T-048 — POST /api/v1/account/basic-auth verifies correct credentials
# ---------------------------------------------------------------------------
# Flowise v3 uses JWT / API-key auth for REST API calls; FLOWISE_USERNAME and
# FLOWISE_PASSWORD are only used for the web-UI login.  The whitelisted
# /api/v1/account/basic-auth endpoint accepts a JSON body and compares
# against those env vars.  This confirms the correct secret is deployed.
# ---------------------------------------------------------------------------

@test "T-048: flowise /api/v1/account/basic-auth accepts configured credentials" {
    run curl -s --max-time 15 \
        -X POST \
        -H "Content-Type: application/json" \
        -d "{\"username\":\"${FLOWISE_USER}\",\"password\":\"${FLOWISE_PASS}\"}" \
        "${FLOWISE_URL}/api/v1/account/basic-auth"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to Flowise (exit $status)" >&3
        return 1
    }

    echo "$output" | jq . >/dev/null 2>&1 || {
        echo "Response is not valid JSON: $output" >&3
        return 1
    }

    local msg
    msg=$(echo "$output" | jq -r '.message // empty')
    [[ "$msg" == "Authentication successful" ]] || {
        echo "Expected 'Authentication successful', got: $msg" >&3
        echo "Full response: $output" >&3
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
