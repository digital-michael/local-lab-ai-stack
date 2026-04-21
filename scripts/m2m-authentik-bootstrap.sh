#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
readonly CONFIG_FILE="${CONFIG_FILE:-$PROJECT_DIR/configs/config.json}"

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Purpose:
  Prepare M2M gateway Authentik wiring for issuer/JWKS verification and perform
  optional token smoke validation against the local gateway introspection endpoint.

Options:
  --issuer <url>       OIDC issuer URL (example: https://auth.stack.localhost/application/o/<slug>/)
  --jwks-url <url>     JWKS URL for token verification
  --audience <value>   Gateway audience claim value (default: local-m2m-gateway)
    --service-id <id>    Service identity to include in generated Authentik client template
    --workflow-id <id>   Workflow claim to include in generated Authentik client template
    --token-ttl-seconds <n>
                                            Access token TTL for generated client template (default: 600)
    --emit-client-template
                                            Emit Authentik M2M client template JSON for repeatable provisioning
    --template-output <path>
                                            Write emitted client template JSON to file instead of stdout
  --gateway-url <url>  Local M2M gateway URL (default: http://127.0.0.1:8787)
  --apply-config       Write issuer/JWKS/audience into configs/config.json
  -h, --help           Show this help message and exit

Environment:
  M2M_TEST_TOKEN       Optional bearer token. If set, script calls /m2m/v1/token/introspect
                       on the gateway and prints the result.

Examples:
  $(basename "$0") --issuer https://auth.stack.localhost/application/o/m2m-gateway/ \
    --jwks-url https://auth.stack.localhost/application/o/m2m-gateway/jwks/ --apply-config

  M2M_TEST_TOKEN='<jwt>' $(basename "$0") --issuer https://auth.stack.localhost/application/o/m2m-gateway/ \
    --jwks-url https://auth.stack.localhost/application/o/m2m-gateway/jwks/

    $(basename "$0") --issuer https://auth.stack.localhost/application/o/m2m-gateway/ \
        --jwks-url https://auth.stack.localhost/application/o/m2m-gateway/jwks/ \
        --service-id svc-ingest --workflow-id wf_ingest_docs --emit-client-template \
        --template-output /tmp/m2m-client-svc-ingest.json
EOF
}

require_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
}

_issuer=""
_jwks_url=""
_audience="local-m2m-gateway"
_service_id=""
_workflow_id=""
_token_ttl_seconds="600"
_emit_client_template="false"
_template_output=""
_gateway_url="http://127.0.0.1:8787"
_apply_config="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --issuer)
            _issuer="${2:-}"
            shift 2
            ;;
        --jwks-url)
            _jwks_url="${2:-}"
            shift 2
            ;;
        --audience)
            _audience="${2:-}"
            shift 2
            ;;
        --service-id)
            _service_id="${2:-}"
            shift 2
            ;;
        --workflow-id)
            _workflow_id="${2:-}"
            shift 2
            ;;
        --token-ttl-seconds)
            _token_ttl_seconds="${2:-}"
            shift 2
            ;;
        --emit-client-template)
            _emit_client_template="true"
            shift
            ;;
        --template-output)
            _template_output="${2:-}"
            shift 2
            ;;
        --gateway-url)
            _gateway_url="${2:-}"
            shift 2
            ;;
        --apply-config)
            _apply_config="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$_issuer" || -z "$_jwks_url" ]]; then
    echo "ERROR: --issuer and --jwks-url are required." >&2
    usage
    exit 1
fi

require_cmd curl
require_cmd jq

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file not found: $CONFIG_FILE" >&2
    exit 1
fi

if [[ ! "$_token_ttl_seconds" =~ ^[0-9]+$ ]] || [[ "$_token_ttl_seconds" -lt 60 ]]; then
    echo "ERROR: --token-ttl-seconds must be an integer >= 60." >&2
    exit 1
fi

if [[ "$_emit_client_template" == "true" ]] && [[ -z "$_service_id" ]]; then
    echo "ERROR: --emit-client-template requires --service-id." >&2
    exit 1
fi

echo "[1/4] Verifying issuer well-known metadata..."
issuer_well_known="${_issuer%/}/.well-known/openid-configuration"
curl -fsS "$issuer_well_known" >/dev/null

echo "[2/4] Verifying JWKS endpoint..."
curl -fsS "$_jwks_url" | jq -e '.keys | type == "array"' >/dev/null

echo "Issuer/JWKS checks passed."

if [[ "$_apply_config" == "true" ]]; then
    echo "[3/4] Applying issuer/JWKS/audience to $CONFIG_FILE"
    tmp_file="$(mktemp)"
    jq \
      --arg issuer "$_issuer" \
      --arg jwks "$_jwks_url" \
      --arg aud "$_audience" \
      '.services["m2m-gateway"].environment.M2M_JWT_ISSUER = $issuer
       | .services["m2m-gateway"].environment.M2M_JWKS_URL = $jwks
       | .services["m2m-gateway"].environment.M2M_JWT_AUDIENCE = $aud' \
      "$CONFIG_FILE" > "$tmp_file"
    mv "$tmp_file" "$CONFIG_FILE"
    echo "Config updated. Run: bash scripts/configure.sh validate"
else
    echo "[3/4] Config apply skipped (use --apply-config to write changes)."
fi

if [[ "$_emit_client_template" == "true" ]]; then
        echo "[3b/4] Emitting Authentik client template JSON..."
        workflow_json="null"
        if [[ -n "$_workflow_id" ]]; then
                workflow_json="\"$_workflow_id\""
        fi

        template_json=$(jq -n \
            --arg service_id "$_service_id" \
            --arg audience "$_audience" \
            --argjson token_ttl_seconds "$_token_ttl_seconds" \
            --argjson workflow_id "$workflow_json" \
            '{
                intent: "authentik_m2m_client_template",
                service_id: $service_id,
                suggested_client_name: ("m2m-" + $service_id),
                required_settings: {
                    grant_type: "client_credentials_only",
                    audience: $audience,
                    access_token_ttl_seconds: $token_ttl_seconds,
                    required_claims: {
                        sub: $service_id,
                        wf: $workflow_id
                    }
                },
                notes: [
                    "Use one confidential client per service identity.",
                    "Do not store client secret in tracked files; use Podman secrets.",
                    "Keep scope set minimal and workflow-specific."
                ]
            }')

        if [[ -n "$_template_output" ]]; then
                tmp_file="$(mktemp)"
                printf '%s\n' "$template_json" > "$tmp_file"
                mv "$tmp_file" "$_template_output"
                echo "Template written: $_template_output"
        else
                echo "$template_json" | jq .
        fi
fi

if [[ -n "${M2M_TEST_TOKEN:-}" ]]; then
    echo "[4/4] Token smoke check against gateway introspection..."
    curl -fsS -X POST \
      -H "Authorization: Bearer ${M2M_TEST_TOKEN}" \
      -H "Content-Type: application/json" \
      "${_gateway_url%/}/m2m/v1/token/introspect" | jq .
    echo "Token introspection succeeded."
else
    echo "[4/4] Token smoke check skipped (set M2M_TEST_TOKEN to enable)."
fi

echo
cat <<EOF
Next required operator steps (not automated here):
1. In Authentik, create one M2M client per service identity with client-credentials grant only.
2. Set audience to '$_audience' and short token TTL (10 minutes default).
3. If needed, use --emit-client-template to produce per-service provisioning templates.
4. Store each client secret in Podman secret store, never in tracked files.
5. Restart m2m gateway after deploying updated runtime env.
EOF
