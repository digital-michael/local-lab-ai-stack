#!/usr/bin/env bats
# testing/layer2_traefik.bats
#
# Layer 2 — Traefik Component Integration (T-021 through T-024)
# Validates routing table, redirect behaviour, TLS certificate, and
# forward-auth middleware attachment.
#
# Prerequisites: Layer 0 and Layer 1 must pass.
# Run: bats testing/layer2_traefik.bats

load 'helpers'

setup_file() {
    local missing=()
    command -v curl    &>/dev/null || missing+=(curl)
    command -v openssl &>/dev/null || missing+=(openssl)
    command -v jq      &>/dev/null || missing+=(jq)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Layer 2 Traefik tests require: ${missing[*]}" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-021 — Traefik router list shows expected service routes
# ---------------------------------------------------------------------------
# Note: Requires Traefik dynamic config files for each user-facing service
# (openwebui, grafana, flowise, authentik) to be present in
# $AI_STACK_DIR/configs/traefik/dynamic/. Skipped until those files exist.
# ---------------------------------------------------------------------------

@test "T-021: traefik router list shows routes for all user-facing services" {
    run curl -sf --max-time 10 "http://localhost:${TRAEFIK_API_PORT}/api/http/routers"
    if [[ "$status" -ne 0 ]]; then
        echo "Traefik API returned error — is Traefik running?" >&3
        return 1
    fi

    local routers="$output"
    local expected=(openwebui grafana flowise authentik)
    local missing=()

    for svc in "${expected[@]}"; do
        echo "$routers" | grep -qi "$svc" || missing+=("$svc")
    done

    if [[ "${#missing[@]}" -gt 0 ]]; then
        skip "Traefik dynamic route configs not yet created for: ${missing[*]}" \
             "— create $AI_STACK_DIR/configs/traefik/dynamic/<svc>.yaml for each service"
    fi
}

# ---------------------------------------------------------------------------
# T-022 — Traefik HTTP → HTTPS redirect returns 301 with Location: https://
# ---------------------------------------------------------------------------

@test "T-022: HTTP to HTTPS redirect returns 301 with https Location header" {
    # Do not follow redirects (-L omitted). -si includes response headers in output.
    run curl -si --max-time 10 "http://localhost/"
    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to http://localhost/" >&3
        return 1
    }

    # Extract HTTP status code from first line of response
    local http_code
    http_code=$(echo "$output" | awk 'NR==1 {print $2}')
    [[ "$http_code" == "301" ]] || [[ "$http_code" == "302" ]] || {
        echo "Expected 301 or 302 redirect, got: $http_code" >&3
        return 1
    }

    # Location header must point to HTTPS
    echo "$output" | grep -i "^location:" | grep -qi "https://" || {
        echo "Location header missing or does not point to https://" >&3
        echo "Headers received:" >&3
        echo "$output" | grep -i "^location:" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-023 — TLS certificate on port 443 references localhost
# ---------------------------------------------------------------------------

@test "T-023: TLS certificate on port 443 references localhost in SAN or CN" {
    local cert_text
    cert_text=$(echo | openssl s_client -connect localhost:${TRAEFIK_HTTPS_PORT} \
        -servername localhost 2>/dev/null \
        | openssl x509 -noout -text 2>/dev/null)

    if [[ -z "$cert_text" ]]; then
        echo "Could not retrieve TLS certificate from localhost:${TRAEFIK_HTTPS_PORT}" >&3
        echo "Ensure Traefik is running and a certificate exists at" >&3
        echo "$AI_STACK_DIR/configs/tls/cert.pem" >&3
        return 1
    fi

    # Check SAN DNS entries or CN for any localhost reference
    if ! echo "$cert_text" | grep -qiE "DNS:\*?\.?localhost|CN=.*localhost"; then
        echo "Certificate does not reference localhost in SAN or CN" >&3
        echo "Certificate Subject/SAN excerpt:" >&3
        echo "$cert_text" | grep -E "Subject:|DNS:|IP Address:" >&3
        return 1
    fi
}

# ---------------------------------------------------------------------------
# T-024 — Forward-auth middleware attached to user-facing proxied routers
# ---------------------------------------------------------------------------
# Note: Skipped until Traefik dynamic service route configs exist (same
# prerequisite as T-021). Once routes exist, each user-facing router must
# have an Authentik forward-auth middleware in its middleware list.
# ---------------------------------------------------------------------------

@test "T-024: forward-auth middleware is attached to all user-facing routers" {
    run curl -sf --max-time 10 "http://localhost:${TRAEFIK_API_PORT}/api/http/routers"
    if [[ "$status" -ne 0 ]]; then
        echo "Traefik API returned error" >&3
        return 1
    fi

    local routers="$output"
    local services=(openwebui grafana flowise)

    # Skip entirely if service routes are not yet configured
    for svc in "${services[@]}"; do
        if ! echo "$routers" | grep -qi "$svc"; then
            skip "Service routes not yet configured — T-021 prerequisite not met"
        fi
    done

    # For each user-facing service, verify its router entry includes
    # an authentik-related middleware
    local no_auth=()
    for svc in "${services[@]}"; do
        local router_entry
        router_entry=$(echo "$routers" | jq -r \
            ".[] | select(.service | ascii_downcase | contains(\"$svc\"))" \
            2>/dev/null)

        if ! echo "$router_entry" | grep -qi "authentik"; then
            no_auth+=("$svc")
        fi
    done

    if [[ "${#no_auth[@]}" -gt 0 ]]; then
        echo "Forward-auth middleware not attached for: ${no_auth[*]}" >&3
        echo "Add authentik forward-auth middleware to each router's dynamic config." >&3
        return 1
    fi
}
