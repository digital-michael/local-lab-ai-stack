#!/usr/bin/env bats
# testing/layer1_smoke.bats
#
# Layer 1 — Smoke Tests (T-009 through T-020, T-021a)
# Port-level HTTP/TCP reachability for all services with host-exposed ports.
# These tests verify that each service is up and responding before any
# functional testing begins. No authentication is required.
#
# Run: bats testing/layer1_smoke.bats
# All layers: bats testing/

load 'helpers'

# ---------------------------------------------------------------------------
# File-level setup: verify curl is installed
# ---------------------------------------------------------------------------

setup_file() {
    if ! command -v curl &>/dev/null; then
        echo "ERROR: curl is required for Layer 1 smoke tests" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-009 — Traefik: HTTP port 80 redirects to HTTPS
# ---------------------------------------------------------------------------

@test "T-009: traefik HTTP port 80 redirects to HTTPS (301)" {
    assert_http_status "301" "http://localhost/"
}

# ---------------------------------------------------------------------------
# T-010 — Traefik: API /api/version
# ---------------------------------------------------------------------------

@test "T-010: traefik API /api/version returns 200" {
    assert_http_body_contains "http://localhost:${TRAEFIK_API_PORT}/api/version" "Version"
}

# ---------------------------------------------------------------------------
# T-011 — Traefik: /ping health check
# ---------------------------------------------------------------------------

@test "T-011: traefik /ping returns 200 OK" {
    assert_http_body_contains "http://localhost:${TRAEFIK_API_PORT}/ping" "OK"
}

# ---------------------------------------------------------------------------
# T-012 — Prometheus: /-/healthy
# ---------------------------------------------------------------------------

@test "T-012: prometheus /-/healthy returns 200" {
    assert_http_status "200" "http://localhost:${PROMETHEUS_PORT}/-/healthy"
}

# ---------------------------------------------------------------------------
# T-013 — Grafana: /api/health
# ---------------------------------------------------------------------------

@test "T-013: grafana /api/health returns 200 with database ok" {
    assert_http_body_contains "http://localhost:${GRAFANA_PORT}/api/health" '"database": "ok"'
}

# ---------------------------------------------------------------------------
# T-014 — Loki: /ready
# ---------------------------------------------------------------------------

@test "T-014: loki /ready returns 200 with 'ready'" {
    assert_http_body_contains "http://localhost:${LOKI_PORT}/ready" "ready"
}

# ---------------------------------------------------------------------------
# T-015 — Qdrant: REST API root
# ---------------------------------------------------------------------------

@test "T-015: qdrant REST / returns 200 with version info" {
    assert_http_body_contains "http://localhost:${QDRANT_PORT}/" "version"
}

# ---------------------------------------------------------------------------
# T-016 — LiteLLM: /health
# ---------------------------------------------------------------------------

@test "T-016: litellm /health returns 200" {
    assert_http_status "200" "http://localhost:${LITELLM_PORT}/health/liveliness"
}

# ---------------------------------------------------------------------------
# T-017 — OpenWebUI: root page
# ---------------------------------------------------------------------------

@test "T-017: openwebui / returns 200" {
    assert_http_status "200" "http://localhost:${OPENWEBUI_PORT}/"
}

# ---------------------------------------------------------------------------
# T-018 — Flowise: root page
# ---------------------------------------------------------------------------

@test "T-018: flowise / returns 200" {
    assert_http_status "200" "http://localhost:${FLOWISE_PORT}/"
}

# ---------------------------------------------------------------------------
# T-019 — Authentik: reachable via Traefik proxy
# Conditionally skipped if Traefik dynamic routing for Authentik is not yet
# configured. Full coverage deferred to T-033–T-035 (Layer 2 component tests).
# ---------------------------------------------------------------------------

@test "T-019: authentik is reachable via traefik proxy" {
    # Check whether Traefik has an authentik router registered
    run curl -sf --max-time 10 "http://localhost:${TRAEFIK_API_PORT}/api/http/routers"
    if [[ "$status" -ne 0 ]] || ! echo "$output" | grep -qi "authentik"; then
        skip "Traefik route for Authentik not yet configured — covered in Layer 2 (T-033)"
    fi

    # Route exists — expect 200 or 302 (redirect to login)
    run curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
        --resolve "auth.localhost:${TRAEFIK_HTTPS_PORT}:127.0.0.1" \
        "https://auth.localhost/"
    [[ "$status" -eq 0 ]]
    [[ "$output" =~ ^(200|302)$ ]] || {
        echo "Expected 200 or 302 from Authentik via Traefik, got: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-020 — Postgres: accepting TCP connections on port 5432
# Uses pg_isready if available; falls back to /dev/tcp.
# ---------------------------------------------------------------------------

@test "T-020: postgres is accepting connections on port ${POSTGRES_PORT}" {
    if command -v pg_isready &>/dev/null; then
        run pg_isready -h localhost -p "${POSTGRES_PORT}" -q
        if [[ "$status" -ne 0 ]]; then
            echo "pg_isready reported postgres is not accepting connections" >&3
            return 1
        fi
    else
        # Fallback: test TCP reachability via bash built-in
        run bash -c "echo > /dev/tcp/localhost/${POSTGRES_PORT}" 2>/dev/null
        if [[ "$status" -ne 0 ]]; then
            echo "Port ${POSTGRES_PORT} is not reachable (pg_isready not installed for detailed check)" >&3
            return 1
        fi
    fi
}

# ---------------------------------------------------------------------------
# T-021 — MinIO: S3 API health check
# ---------------------------------------------------------------------------

@test "T-021a: minio S3 API /minio/health/live returns 200" {
    assert_http_status "200" "http://localhost:${MINIO_PORT}/minio/health/live"
}
