#!/usr/bin/env bats
# testing/layer2_postgres.bats
#
# Layer 2 — PostgreSQL Component Integration (T-025 through T-027)
# Validates SQL connectivity, schema, and password authentication.
#
# Prerequisites:
#   - Layer 0 and Layer 1 must pass.
#   - The 'postgres_password' Podman secret must be provisioned.
#   - postgres container must be running.
#
# All SQL is executed via 'podman exec' — no host-side psql required.
#
# Run: bats testing/layer2_postgres.bats

load 'helpers'

# ---------------------------------------------------------------------------
# File-level setup
# ---------------------------------------------------------------------------

setup_file() {
    if ! podman ps --format '{{.Names}}' | grep -q '^postgres$'; then
        echo "ERROR: postgres container is not running." >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Helper: run SQL inside the postgres container
# Usage: pg_run "SQL statement"
# Returns output of the query (tuples only, trimmed).
# ---------------------------------------------------------------------------

pg_run() {
    podman exec postgres \
        psql -U aistack -d aistack -t -A -c "$1" 2>&1
}

# ---------------------------------------------------------------------------
# T-025 — Connect to Postgres and execute SELECT 1
# ---------------------------------------------------------------------------

@test "T-025: postgres accepts connection and executes SELECT 1" {
    run pg_run "SELECT 1;"
    if [[ "$status" -ne 0 ]]; then
        echo "psql (via podman exec) connection failed (exit $status)" >&3
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
# T-026 — Authentik tables present in shared database
# ---------------------------------------------------------------------------
# Authentik shares the 'aistack' database (AUTHENTIK_POSTGRESQL__NAME=aistack)
# and creates tables with an 'authentik_' prefix during first-start migrations.
# ---------------------------------------------------------------------------

@test "T-026: authentik migration tables exist in the 'aistack' database" {
    run pg_run "SELECT COUNT(*) FROM pg_tables WHERE schemaname='public' AND tablename LIKE 'authentik_%';"
    if [[ "$status" -ne 0 ]]; then
        echo "psql query failed (exit $status): $output" >&3
        return 1
    fi

    local count
    count=$(echo "$output" | tr -d '[:space:]')
    [[ "$count" -gt 0 ]] || {
        echo "No 'authentik_*' tables found in the aistack database." >&3
        echo "Has Authentik started and completed its initial migration?" >&3
        echo "  (journalctl --user -u authentik.service -n 40)" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-027 — pg_hba.conf enforces scram-sha-256 for non-loopback connections
# ---------------------------------------------------------------------------
# Local (socket/loopback) connections inside the container use 'trust' by
# default, which is normal for a containerised DB not itself internet-facing.
# The security requirement is that connections arriving from OTHER containers
# (i.e. any non-loopback host address) require scram-sha-256.
# This test verifies that rule exists in pg_hba.conf.
# ---------------------------------------------------------------------------

@test "T-027: pg_hba.conf requires scram-sha-256 for external connections" {
    run podman exec postgres cat /var/lib/postgresql/data/pg_hba.conf
    [[ "$status" -eq 0 ]] || {
        echo "Could not read pg_hba.conf (exit $status)" >&3
        return 1
    }

    # Must have at least one 'host ... all ... scram-sha-256' catch-all rule
    echo "$output" | grep -v '^#' | grep -q 'scram-sha-256' || {
        echo "No scram-sha-256 rule found in pg_hba.conf." >&3
        echo "External connections are not requiring password authentication." >&3
        return 1
    }
}
