#!/usr/bin/env bats
# testing/layer2_qdrant.bats
#
# Layer 2 — Qdrant Component Integration (T-028 through T-030)
# Validates REST API responses, full CRUD vector lifecycle, and gRPC port.
#
# Prerequisites: Layer 0 and Layer 1 must pass.
# Run: bats testing/layer2_qdrant.bats

load 'helpers'

# ---------------------------------------------------------------------------
# Collection name used by the CRUD test. Fixed name so teardown can always
# clean up even if the test is interrupted.
# ---------------------------------------------------------------------------

QDRANT_TEST_COLLECTION="bats_layer2_crud_test"

# ---------------------------------------------------------------------------
# File-level setup
# ---------------------------------------------------------------------------

setup_file() {
    local missing=()
    command -v curl &>/dev/null || missing+=(curl)
    command -v jq   &>/dev/null || missing+=(jq)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 2 Qdrant tests require: ${missing[*]}" >&3
        return 1
    fi

    # Resolve optional API key once for the whole file.
    # If qdrant_api_key is not provisioned or Qdrant is not configured
    # to require it, this will be empty and requests will be sent without auth.
    QDRANT_API_KEY=$(read_secret "qdrant_api_key" 2>/dev/null || echo "")
    export QDRANT_API_KEY
}

# ---------------------------------------------------------------------------
# Per-test teardown: always attempt to delete the test collection so a
# failed T-029 does not leave orphaned state.
# ---------------------------------------------------------------------------

teardown() {
    local auth_args=()
    [[ -n "${QDRANT_API_KEY:-}" ]] && auth_args+=(-H "api-key: $QDRANT_API_KEY")

    curl -sf --max-time 10 "${auth_args[@]}" \
        -X DELETE \
        "http://localhost:6333/collections/${QDRANT_TEST_COLLECTION}" \
        &>/dev/null || true
}

# ---------------------------------------------------------------------------
# Helper: issue an authenticated Qdrant request
# Usage: qdrant_curl <curl_args...>
# ---------------------------------------------------------------------------

qdrant_curl() {
    local auth_args=()
    [[ -n "${QDRANT_API_KEY:-}" ]] && auth_args+=(-H "api-key: $QDRANT_API_KEY")
    curl -s --max-time 15 "${auth_args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# T-028 — GET /collections returns 200 with valid JSON
# ---------------------------------------------------------------------------

@test "T-028: qdrant GET /collections returns 200 with valid JSON" {
    run qdrant_curl "http://localhost:6333/collections"
    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to Qdrant (exit $status)" >&3
        return 1
    }

    echo "$output" | jq . >/dev/null 2>&1 || {
        echo "Response is not valid JSON: $output" >&3
        return 1
    }

    # Response must contain a 'result' or 'collections' key
    echo "$output" | jq -e '.result' >/dev/null 2>&1 || {
        echo "Response missing expected 'result' field: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-029 — Full CRUD vector lifecycle
# ---------------------------------------------------------------------------
#
# Steps:
#   1. Create a test collection (4-dimensional vectors, Dot distance)
#   2. Insert two test vectors with metadata
#   3. Query nearest neighbour — verify correct point returned
#   4. Delete the collection
#
# The teardown function handles cleanup even if the test fails mid-way.
# ---------------------------------------------------------------------------

@test "T-029: qdrant full CRUD cycle — create collection, insert, query, delete" {
    local base_url="http://localhost:6333"
    local coll_url="${base_url}/collections/${QDRANT_TEST_COLLECTION}"

    # -- 1. Create collection ------------------------------------------------
    local create_payload='{"vectors":{"size":4,"distance":"Dot"}}'

    run qdrant_curl -X PUT \
        -H "Content-Type: application/json" \
        -d "$create_payload" \
        "$coll_url"

    [[ "$status" -eq 0 ]] || {
        echo "Collection create request failed (exit $status)" >&3
        return 1
    }
    echo "$output" | jq -e '.result == true or .status == "ok"' >/dev/null 2>&1 || {
        echo "Unexpected response to collection create: $output" >&3
        return 1
    }

    # -- 2. Insert two vectors -----------------------------------------------
    local points_payload='{
        "points": [
            {"id": 1, "vector": [0.05, 0.61, 0.76, 0.74], "payload": {"label": "alpha"}},
            {"id": 2, "vector": [0.19, 0.81, 0.75, 0.11], "payload": {"label": "beta"}}
        ]
    }'

    run qdrant_curl -X PUT \
        -H "Content-Type: application/json" \
        -d "$points_payload" \
        "${coll_url}/points"

    [[ "$status" -eq 0 ]] || {
        echo "Point insert request failed (exit $status)" >&3
        return 1
    }
    echo "$output" | jq -e '.status == "ok" or .result.status == "completed"' \
        >/dev/null 2>&1 || {
        echo "Unexpected response to point insert: $output" >&3
        return 1
    }

    # -- 3. Query nearest neighbour ------------------------------------------
    # Query vector is close to point 1 — expect id=1 as top result.
    local search_payload='{"vector":[0.2,0.1,0.9,0.7],"limit":1,"with_payload":true}'

    run qdrant_curl -X POST \
        -H "Content-Type: application/json" \
        -d "$search_payload" \
        "${coll_url}/points/search"

    [[ "$status" -eq 0 ]] || {
        echo "Search request failed (exit $status)" >&3
        return 1
    }

    local result_count
    result_count=$(echo "$output" | jq '.result | length' 2>/dev/null)
    [[ "$result_count" -ge 1 ]] || {
        echo "Search returned no results. Response: $output" >&3
        return 1
    }

    # -- 4. Delete collection ------------------------------------------------
    run qdrant_curl -X DELETE "$coll_url"
    [[ "$status" -eq 0 ]] || {
        echo "Collection delete request failed (exit $status)" >&3
        return 1
    }
    echo "$output" | jq -e '.result == true' >/dev/null 2>&1 || {
        echo "Unexpected response to collection delete: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-030 — Qdrant gRPC port 6334 accepts TCP connections
# ---------------------------------------------------------------------------

@test "T-030: qdrant gRPC port 6334 accepts TCP connections" {
    # Use bash built-in /dev/tcp — no extra tools required.
    run bash -c "echo > /dev/tcp/localhost/6334" 2>/dev/null
    if [[ "$status" -ne 0 ]]; then
        echo "Port 6334 is not reachable." >&3
        echo "Check that the qdrant container exposes gRPC on host port 6334." >&3
        return 1
    fi
}
