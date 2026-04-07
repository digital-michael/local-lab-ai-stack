#!/usr/bin/env bash
# capture-credentials.sh — Capture all AI Stack credentials to a local file
# Output: configs/credentials.local (git-ignored)
#
# Usage:
#   ./scripts/capture-credentials.sh          # write to configs/credentials.local
#   ./scripts/capture-credentials.sh --stdout  # print to stdout instead

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_FILE="${REPO_ROOT}/configs/credentials.local"
TO_STDOUT=false

if [[ "${1:-}" == "--stdout" ]]; then
    TO_STDOUT=true
fi

# ── helpers ──────────────────────────────────────────────────────────────────

_read_secret() {
    local name="$1"
    # podman secret inspect --showsecret outputs JSON with SecretData field
    local val
    val=$(podman secret inspect --showsecret "$name" 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin)[0]['SecretData'])" 2>/dev/null) || true
    echo "${val:-<not found>}"
}

_header() {
    echo ""
    echo "# ── $1 ──"
}

# ── main ─────────────────────────────────────────────────────────────────────

capture() {
    echo "# AI Stack Credentials"
    echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "# Host: $(hostname)"
    echo "#"
    echo "# WARNING: This file contains secrets. Do not commit to version control."

    _header "PostgreSQL"
    echo "POSTGRES_USER=aistack"
    echo "POSTGRES_PASSWORD=$(_read_secret postgres_password)"

    _header "Authentik"
    echo "AUTHENTIK_SECRET_KEY=$(_read_secret authentik_secret_key)"
    # akadmin credentials are set via ak shell, not podman secrets
    echo "# akadmin password must be set manually (created via ak shell)"
    echo "# AKADMIN_PASSWORD="
    echo "# AKADMIN_API_TOKEN="

    _header "LiteLLM"
    echo "LITELLM_MASTER_KEY=$(_read_secret litellm_master_key)"

    _header "Qdrant"
    echo "QDRANT_API_KEY=$(_read_secret qdrant_api_key)"

    _header "Knowledge Index"
    echo "KNOWLEDGE_INDEX_API_KEY=$(_read_secret knowledge_index_api_key)"

    _header "Flowise"
    echo "FLOWISE_PASSWORD=$(_read_secret flowise_password)"
    echo "FLOWISE_SECRET_KEY=$(_read_secret flowise_secret_key)"

    _header "OpenWebUI"
    echo "OPENWEBUI_API_KEY=$(_read_secret openwebui_api_key)"

    _header "MinIO"
    echo "MINIO_ROOT_USER=$(_read_secret minio_root_user)"
    echo "MINIO_ROOT_PASSWORD=$(_read_secret minio_root_password)"
    echo "MINIO_KI_ACCESS_KEY=$(_read_secret minio_ki_access_key)"
    echo "MINIO_KI_SECRET_KEY=$(_read_secret minio_ki_secret_key)"

    _header "Grafana"
    echo "# Default credentials — rotate before non-localhost exposure"
    echo "GRAFANA_USER=admin"
    echo "GRAFANA_PASSWORD=admin"

    _header "External API Keys"
    echo "OPENAI_API_KEY=$(_read_secret openai_api_key)"
    echo "GROQ_API_KEY=$(_read_secret groq_api_key)"
    echo "ANTHROPIC_API_KEY=$(_read_secret anthropic_api_key)"
    echo "MISTRAL_API_KEY=$(_read_secret mistral_api_key)"
}

if $TO_STDOUT; then
    capture
else
    capture > "$OUTPUT_FILE"
    chmod 600 "$OUTPUT_FILE"
    echo "Credentials written to: $OUTPUT_FILE"
    echo "Permissions: $(stat -c '%a' "$OUTPUT_FILE") (owner read/write only)"
fi
