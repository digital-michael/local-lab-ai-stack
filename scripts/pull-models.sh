#!/usr/bin/env bash
# scripts/pull-models.sh
#
# Register model routes from configs/models.json into LiteLLM.
#
# Each entry in default_models is registered via POST /model/new.
# Existing entries with the same model_name are deleted first so
# that re-runs with changed api_base or other params take effect
# (LiteLLM's /model/new adds a new entry rather than updating).
#
# The model route persists in the LiteLLM database so that it
# survives restarts and appears in GET /models.
#
# This script is idempotent: running it multiple times produces
# exactly one entry per model in the LiteLLM DB.
#
# Usage:
#   bash scripts/pull-models.sh
#
# Environment:
#   LITELLM_URL         — LiteLLM base URL (default: http://localhost:9000)
#   LITELLM_MASTER_KEY  — bearer token (auto-read from Podman secret if unset)
#
# Exit codes:
#   0 — all models registered (or already present)
#   1 — a required tool is missing or models.json is malformed
#   2 — at least one model registration failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MODELS_FILE="$PROJECT_ROOT/configs/models.json"
LITELLM_URL="${LITELLM_URL:-http://localhost:9000}"

# ---------------------------------------------------------------------------
# Resolve master key
# ---------------------------------------------------------------------------
_resolve_key() {
    if [[ -n "${LITELLM_MASTER_KEY:-}" ]]; then
        echo "$LITELLM_MASTER_KEY"
        return
    fi
    # Try Podman secret
    podman run --rm \
        --secret litellm_master_key \
        docker.io/library/alpine:latest \
        sh -c "cat /run/secrets/litellm_master_key" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# Prerequisite checks
# ---------------------------------------------------------------------------
for cmd in curl jq podman; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: Required command not found: $cmd" >&2
        exit 1
    fi
done

if [[ ! -f "$MODELS_FILE" ]]; then
    echo "ERROR: $MODELS_FILE not found" >&2
    exit 1
fi

MASTER_KEY="$(_resolve_key)"
if [[ -z "$MASTER_KEY" ]]; then
    echo "ERROR: Could not resolve LiteLLM master key." >&2
    echo "       Set LITELLM_MASTER_KEY env var or provision the litellm_master_key Podman secret." >&2
    exit 1
fi

model_count="$(jq '.default_models | length' "$MODELS_FILE")"
if [[ "$model_count" -eq 0 ]]; then
    echo "No models defined in $MODELS_FILE — nothing to register."
    exit 0
fi

echo "Registering $model_count model(s) from $MODELS_FILE into LiteLLM at $LITELLM_URL ..."

# ---------------------------------------------------------------------------
# Register each model (delete existing entry first to ensure idempotency)
# ---------------------------------------------------------------------------
failures=0
for i in $(seq 0 $((model_count - 1))); do
    model_id="$(jq -r ".default_models[$i].id" "$MODELS_FILE")"
    litellm_params="$(jq -c ".default_models[$i].litellm_params" "$MODELS_FILE")"
    model_info="$(jq -c ".default_models[$i].model_info // {}" "$MODELS_FILE")"

    # Delete any existing entries with this model_name (enables idempotent re-run).
    # LiteLLM may normalize ':' to '-' in stored model names, so match both forms.
    model_id_normalized="${model_id//:/-}"
    existing_ids="$(curl -s -H "Authorization: Bearer $MASTER_KEY" \
        "$LITELLM_URL/model/info" 2>/dev/null \
        | jq -r --arg name "$model_id" --arg norm "$model_id_normalized" \
            '.data[]? | select(.model_name == $name or .model_name == $norm) | .model_info.id' \
            2>/dev/null || true)"
    for existing_id in $existing_ids; do
        curl -s -X POST \
            -H "Authorization: Bearer $MASTER_KEY" \
            -H "Content-Type: application/json" \
            -d "{\"id\": \"$existing_id\"}" \
            "$LITELLM_URL/model/delete" >/dev/null 2>&1 || true
    done

    payload="$(jq -nc \
        --arg name "$model_id" \
        --argjson lp "$litellm_params" \
        --argjson mi "$model_info" \
        '{"model_name": $name, "litellm_params": $lp, "model_info": $mi}')"

    echo -n "  Registering '$model_id' ... "

    http_code="$(curl -s -o /tmp/pull-models-resp.json -w "%{http_code}" \
        -X POST \
        -H "Authorization: Bearer $MASTER_KEY" \
        -H "Content-Type: application/json" \
        -d "$payload" \
        "$LITELLM_URL/model/new")"

    if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
        echo "OK (HTTP $http_code)"
    else
        echo "FAILED (HTTP $http_code)"
        cat /tmp/pull-models-resp.json >&2
        echo >&2
        failures=$((failures + 1))
    fi
done

rm -f /tmp/pull-models-resp.json

if [[ "$failures" -gt 0 ]]; then
    echo "ERROR: $failures model(s) failed to register." >&2
    exit 2
fi

echo "All models registered successfully."

# ---------------------------------------------------------------------------
# Per-node alias routes from configs/nodes/*.json
# Registers ollama/<model>@<alias> routes with api_base pointing to each
# active inference worker's Ollama endpoint. The alias route is what the
# Layer 5 distributed tests use to target a specific node directly.
# ---------------------------------------------------------------------------
NODES_DIR="$PROJECT_ROOT/configs/nodes"
node_alias_failures=0

for node_file in "$NODES_DIR"/*.json; do
    [[ -f "$node_file" ]] || continue

    node_alias=$(jq -r '.alias // empty' "$node_file")
    node_profile=$(jq -r '.profile // empty' "$node_file")
    node_status=$(jq -r '.status // empty' "$node_file")
    node_address=$(jq -r '.address // .address_fallback // empty' "$node_file")

    # Only active, non-controller nodes with an address
    [[ "$node_profile" == "controller" ]] && continue
    [[ "$node_status" != "active" ]] && continue
    [[ -z "$node_address" ]] && continue

    model_count_node=$(jq '.models | length' "$node_file")
    [[ "$model_count_node" -eq 0 ]] && continue

    echo "Registering per-node alias routes for ${node_alias} (${node_address}) ..."

    for i in $(seq 0 $((model_count_node - 1))); do
        model_name=$(jq -r ".models[$i]" "$node_file")
        alias_id="ollama/${model_name}@${node_alias}"

        # Delete any existing entry with this alias_id (idempotent)
        alias_id_normalized="${alias_id//:/-}"
        existing_ids="$(curl -s -H "Authorization: Bearer $MASTER_KEY" \
            "$LITELLM_URL/model/info" 2>/dev/null \
            | jq -r --arg name "$alias_id" --arg norm "$alias_id_normalized" \
                '.data[]? | select(.model_name == $name or .model_name == $norm) | .model_info.id' \
                2>/dev/null || true)"
        for existing_id in $existing_ids; do
            curl -s -X POST \
                -H "Authorization: Bearer $MASTER_KEY" \
                -H "Content-Type: application/json" \
                -d "{\"id\": \"$existing_id\"}" \
                "$LITELLM_URL/model/delete" >/dev/null 2>&1 || true
        done

        payload="$(jq -nc \
            --arg name "$alias_id" \
            --arg model "ollama_chat/${model_name}" \
            --arg api_base "http://${node_address}:11434" \
            '{
                "model_name": $name,
                "litellm_params": {
                    "model": $model,
                    "api_base": $api_base,
                    "api_key": "none",
                    "max_tokens": 4096
                },
                "model_info": {
                    "mode": "chat",
                    "input_cost_per_token": 0,
                    "output_cost_per_token": 0
                }
            }')"

        echo -n "  Registering '${alias_id}' ... "

        http_code="$(curl -s -o /tmp/pull-models-resp.json -w "%{http_code}" \
            -X POST \
            -H "Authorization: Bearer $MASTER_KEY" \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$LITELLM_URL/model/new")"

        if [[ "$http_code" == "200" ]] || [[ "$http_code" == "201" ]]; then
            echo "OK (HTTP $http_code)"
        else
            echo "FAILED (HTTP $http_code)"
            cat /tmp/pull-models-resp.json >&2
            echo >&2
            node_alias_failures=$((node_alias_failures + 1))
        fi
    done
done

rm -f /tmp/pull-models-resp.json

if [[ "$node_alias_failures" -gt 0 ]]; then
    echo "ERROR: $node_alias_failures per-node alias route(s) failed to register." >&2
    exit 2
fi

echo "All per-node alias routes registered."

