#!/usr/bin/env bats
# testing/layer2_litellm.bats
#
# Layer 2 — LiteLLM Component Integration (T-031 through T-032)
# Validates the model list endpoint and master key enforcement.
#
# Prerequisites:
#   - Layer 0 and Layer 1 must pass.
#   - The 'litellm_master_key' Podman secret must be provisioned.
#
# Run: bats testing/layer2_litellm.bats

load 'helpers'

# ---------------------------------------------------------------------------
# File-level setup
# ---------------------------------------------------------------------------

setup_file() {
    local missing=()
    command -v curl &>/dev/null || missing+=(curl)
    command -v jq   &>/dev/null || missing+=(jq)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 2 LiteLLM tests require: ${missing[*]}" >&3
        return 1
    fi

    # Resolve master key once for the whole file.
    LITELLM_KEY=$(read_secret "litellm_master_key")
    if [[ -z "$LITELLM_KEY" ]]; then
        echo "ERROR: Could not read 'litellm_master_key' secret." >&3
        echo "Provision with: echo '<value>' | podman secret create litellm_master_key -" >&3
        return 1
    fi
    export LITELLM_KEY
}

# ---------------------------------------------------------------------------
# T-031 — GET /models returns valid JSON with the master key
# ---------------------------------------------------------------------------
#
# With no models loaded (no vLLM or llama.cpp backends active), the response
# will have an empty 'data' array — that is still a valid, correct response.
# Content validation of loaded models is covered in Layer 3a (T-057).
# ---------------------------------------------------------------------------

@test "T-031: litellm GET /models returns valid JSON when authenticated" {
    run curl -s --max-time 15 \
        -H "Authorization: Bearer $LITELLM_KEY" \
        "http://localhost:${LITELLM_PORT}/models"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to LiteLLM (exit $status)" >&3
        return 1
    }

    # Response must be valid JSON
    echo "$output" | jq . >/dev/null 2>&1 || {
        echo "Response is not valid JSON: $output" >&3
        return 1
    }

    # Response must have the OpenAI-compatible 'object' and 'data' fields
    echo "$output" | jq -e '.object and (.data | type == "array")' \
        >/dev/null 2>&1 || {
        echo "Response does not match expected OpenAI /models schema." >&3
        echo "Response: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-032 — Unauthenticated request returns 401
# ---------------------------------------------------------------------------
#
# All LiteLLM API routes must require the Authorization header.
# This test sends a well-formed request with NO auth header and asserts
# that LiteLLM returns 401 (not 500 or 200).
# ---------------------------------------------------------------------------

@test "T-032: litellm rejects requests without Authorization header with 401" {
    run curl -s --max-time 15 \
        -o /dev/null \
        -w "%{http_code}" \
        -X POST \
        -H "Content-Type: application/json" \
        -d '{"model":"test-model","messages":[{"role":"user","content":"test"}]}' \
        "http://localhost:${LITELLM_PORT}/chat/completions"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to LiteLLM (exit $status)" >&3
        return 1
    }

    [[ "$output" == "401" ]] || {
        echo "Expected HTTP 401 for unauthenticated request, got: $output" >&3
        echo "LiteLLM master key enforcement may not be configured." >&3
        return 1
    }
}
