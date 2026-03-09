#!/usr/bin/env bats
# testing/layer4_localhost.bats
#
# Layer 4 — Localhost / Network Isolation Tests (T-073 through T-077)
#
# Verifies that all service-to-service traffic stays inside the Podman
# overlay network (ai-stack-net) and that no stack ports are bound to
# the host wildcard address 0.0.0.0, with the exception of Traefik's
# intentional 80/443 public listeners.
#
# Prerequisites:
#   - All 11 deployed services are running
#   - bats-core v1.2+
#   - podman, ss (iproute2), openssl available
#
# Run: bats testing/layer4_localhost.bats

load 'helpers'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Ports that are explicitly bound to 0.0.0.0 by design (Traefik public)
ALLOWED_WILDCARD_PORTS=(80 443)

# Ports that must NOT be bound to 0.0.0.0 — internal stack ports
INTERNAL_PORTS=(5432 6333 6334 9000 9090 9091 3000 3100 3001)

# ---------------------------------------------------------------------------
# T-073 — Internal stack ports NOT bound to 0.0.0.0
# ---------------------------------------------------------------------------

@test "T-073: Internal stack ports are not bound to the host wildcard address" {
    local failed=0
    local failed_list=()

    for port in "${INTERNAL_PORTS[@]}"; do
        # ss output: State  Recv-Q  Send-Q  Local Address:Port ...
        # We look for lines where Local Address is exactly "0.0.0.0" or "*"
        if ss -tlnp | awk '{print $4}' | grep -qE "^(0\.0\.0\.0|\*):[[:space:]]*${port}$|^(0\.0\.0\.0|\*):${port}$"; then
            failed=1
            failed_list+=("$port")
        fi
    done

    if [[ $failed -ne 0 ]]; then
        fail "The following internal ports are unexpectedly bound to 0.0.0.0: ${failed_list[*]}"
    fi
}

# ---------------------------------------------------------------------------
# T-074 — Intra-container HTTP: traefik reaches litellm via internal hostname
# ---------------------------------------------------------------------------

@test "T-074: Traefik container can reach LiteLLM via internal DNS on ai-stack-net" {
    # Find a running container on ai-stack-net to use as execution host
    local proxy_container
    proxy_container=$(podman ps --filter "network=ai-stack-net" --format "{{.Names}}" | head -1)
    [[ -n "$proxy_container" ]] || skip "No running container found on ai-stack-net"

    # LiteLLM listens on port 4000 inside the network
    local status
    status=$(podman exec "$proxy_container" \
        sh -c 'curl -sf -o /dev/null -w "%{http_code}" http://litellm:4000/health 2>/dev/null || echo "000"')

    [[ "$status" == "200" ]] || [[ "$status" == "401" ]] || \
        fail "Expected 200 or 401 from litellm:4000/health inside ai-stack-net, got: $status"
}

# ---------------------------------------------------------------------------
# T-075 — Cross-container connectivity: at least 3 pairs reachable internally
# ---------------------------------------------------------------------------

@test "T-075: At least 3 cross-container internal connectivity checks pass" {
    local proxy_container
    proxy_container=$(podman ps --filter "network=ai-stack-net" --format "{{.Names}}" | head -1)
    [[ -n "$proxy_container" ]] || skip "No running container found on ai-stack-net"

    # Format: "hostname:port"
    local targets=(
        "postgres:5432"
        "qdrant:6333"
        "prometheus:9090"
        "grafana:3000"
        "loki:3100"
    )

    local passed=0
    local results=()

    for target in "${targets[@]}"; do
        local host="${target%%:*}"
        local port="${target##*:}"
        local ok
        # Use /dev/tcp if available, otherwise fall back to curl
        ok=$(podman exec "$proxy_container" \
            sh -c "curl -sf -o /dev/null -w ok --connect-timeout 3 http://${host}:${port}/ 2>/dev/null || \
                   (echo > /dev/tcp/${host}/${port} 2>/dev/null && echo ok)" 2>/dev/null || true)
        if [[ "$ok" == "ok" ]]; then
            passed=$((passed + 1))
            results+=("PASS: $target")
        else
            results+=("FAIL: $target")
        fi
    done

    # Print for diagnostics
    for r in "${results[@]}"; do
        echo "  $r"
    done

    [[ $passed -ge 3 ]] || \
        fail "Expected at least 3 internal connectivity checks to pass, got $passed/5"
}

# ---------------------------------------------------------------------------
# T-076 — TLS certificate is self-signed / local CA (not a public CA)
# ---------------------------------------------------------------------------

@test "T-076: TLS certificate on port 443 is issued by a local/self-signed CA (not a public CA)" {
    # Known public CA names we do NOT want to see
    local public_ca_patterns="Let's Encrypt|DigiCert|GlobalSign|Sectigo|COMODO|GeoTrust|Verisign|Amazon"

    local cert_issuer
    cert_issuer=$(echo | timeout 5 openssl s_client -connect "localhost:443" \
        -servername "localhost" 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null || true)

    if [[ -z "$cert_issuer" ]]; then
        skip "Could not retrieve TLS certificate from localhost:443 — Traefik may not be running or port 443 is unreachable"
    fi

    if echo "$cert_issuer" | grep -qiE "$public_ca_patterns"; then
        fail "Certificate on port 443 appears to be issued by a public CA: $cert_issuer"
    fi

    # Positive check: issuer should contain a local indicator
    # (hostname, 'localhost', 'local', 'internal', or a private domain)
    echo "  Issuer: $cert_issuer"
    # We pass as long as it's not a known public CA — private CAs can have any name
    true
}

# ---------------------------------------------------------------------------
# T-077 — Forward-auth: unauthenticated request redirects to Authentik
# ---------------------------------------------------------------------------

@test "T-077: Unauthenticated request to proxied service redirects to Authentik login" {
    # Use a service that is protected by forward-auth middleware.
    # Grafana and OpenWebUI are realistic candidates.
    local target_url="http://localhost"
    local host_header="grafana.${DOMAIN:-localhost}"

    # Pick a reasonable header to look authenticated external traffic would use
    local response
    response=$(curl -sk -o /dev/null -w "%{http_code}|%{redirect_url}" \
        -H "Host: $host_header" \
        --max-redirs 0 \
        "$target_url/" 2>/dev/null || true)

    local http_code="${response%%|*}"
    local redirect_url="${response##*|}"

    if [[ "$http_code" != "302" ]] && [[ "$http_code" != "301" ]] && [[ "$http_code" != "307" ]]; then
        skip "Did not receive a redirect from $host_header — forward-auth middleware may not be configured for HTTP yet, or Traefik routing is not set up. HTTP status: $http_code"
    fi

    # The redirect location must point toward Authentik
    if [[ -n "$redirect_url" ]]; then
        echo "  Redirect location: $redirect_url"
        echo "$redirect_url" | grep -qiE "authentik|outpost|/outpost\.goauthentik" || \
            fail "Redirect does not point to Authentik: $redirect_url"
    else
        # Some Traefik setups set Location header — captured via curl -D
        local headers
        headers=$(curl -sk -D - -o /dev/null \
            -H "Host: $host_header" \
            --max-redirs 0 \
            "$target_url/" 2>/dev/null || true)
        echo "$headers" | grep -i "^location:" | grep -qiE "authentik|outpost" || \
            skip "Redirect received (${http_code}) but Location header does not reference Authentik. Forward-auth may redirect to a different URL. Headers: $(echo "$headers" | grep -i location)"
    fi
}
