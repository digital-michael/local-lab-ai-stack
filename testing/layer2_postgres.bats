#!/usr/bin/env bats
# testing/layer2_postgres.bats
#
# Layer 2 — PostgreSQL Component Integration (T-025 through T-027)
# Validates SQL connectivity, schema, and password authentication.
#
# Prerequisites:
#   - Layer 0 and Layer 1 must pass.
#   - psql must be installed (sudo dnf install postgresql).
#   - The 'postgres_password' Podman secret must be provisioned.
#
# Run: bats testing/layer2_postgres.bats

load 'helpers'

# ---------------------------------------------------------------------------
# File-level setup
# ---------------------------------------------------------------------------

setup_file() {
    if ! command -v psql &>/dev/null; then
        echo "ERROR: psql is required for Postgres Layer 2 tests." >&3
        echo "Install: sudo dnf install postgresql" >&3
        return 1
    fi

    # Resolve password once for the whole file
    PG_PASS=$(read_secret "postgres_password")
    if [[ -z "$PG_PASS" ]]; then
        echo "ERROR: Could not read 'postgres_password' secret." >&3
        echo "Provision with: echo '<value>' | podman secret create postgres_password -" >&3
        return 1
    fi
    export PG_PASS
}

# ---------------------------------------------------------------------------
# Helper: run a psql command against localhost
# Usage: pg_run "SQL statement"
# Returns output of the query (tuples only, trimmed).
# ---------------------------------------------------------------------------

pg_run() {
    PGPASSWORD="$PG_PASS" PGCONNECT_TIMEOUT=10 \
        psql -h localhost -p 5432 -U postgres -t -A -c "$1" 2>&1
}

# ---------------------------------------------------------------------------
# T-025 — Connect to Postgres and execute SELECT 1
# ---------------------------------------------------------------------------

@test "T-025: postgres accepts connection and executes SELECT 1" {
    run pg_run "SELECT 1;"
    if [[ "$status" -ne 0 ]]; then
        echo "psql connection failed (exit $status)" >&3
        echo "Output: $output" >&3
        return 1
    fi

    # Output should be the integer "1"
    [[ "$output" == "1" ]] || [[ "$output" =~ ^[[:space:]]*1[[:space:]]*$ ]] || {
        echo "Expected '1' from SELECT 1, got: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-026 — authentik database exists
# ---------------------------------------------------------------------------
# Authentik creates its own database at first start (after running migrations).
# This test confirms the database was created and is visible to the superuser.
# ---------------------------------------------------------------------------

@test "T-026: 'authentik' database exists in Postgres" {
    run pg_run "SELECT datname FROM pg_database WHERE datname = 'authentik';"
    if [[ "$status" -ne 0 ]]; then
        echo "psql query failed (exit $status): $output" >&3
        return 1
    fi

    echo "$output" | grep -q "authentik" || {
        echo "'authentik' database not found." >&3
        echo "Has Authentik started and completed its initial migration?" >&3
        echo "Current databases:" >&3
        pg_run "SELECT datname FROM pg_database ORDER BY datname;" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-027 — Postgres rejects connection with wrong password
# ---------------------------------------------------------------------------

@test "T-027: postgres rejects authentication with incorrect password" {
    run bash -c "PGPASSWORD='invalid_bats_test_password_xyz_wrong' \
        PGCONNECT_TIMEOUT=5 \
        psql -h localhost -p 5432 -U postgres -c 'SELECT 1' 2>&1"

    # psql must exit non-zero on auth failure
    [[ "$status" -ne 0 ]] || {
        echo "Expected psql to fail with a wrong password but it succeeded." >&3
        echo "Check pg_hba.conf — password authentication may not be enforced." >&3
        return 1
    }

    # Output must contain an authentication error message
    echo "$output" | grep -qi \
        "password authentication failed\|authentication failed\|FATAL" || {
        echo "Unexpected error output from psql: $output" >&3
        return 1
    }
}
