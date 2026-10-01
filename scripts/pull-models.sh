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
# Also tags each route with a merged tags list in model_info.tags — the
# "strong-1"-style node classification (from configs/nodes/*.json) plus
# Ollama's live supported-modes capabilities (completion/tools/thinking/
# vision/etc., via /api/show; skipped for vLLM/cloud backends, which have no
# equivalent source) — and syncs the same tags into OpenWebUI's own
# model.meta.tags so they're actually visible to regular users, not just
# admin-side in LiteLLM. Re-running this script is how you refresh a model's
# tags (e.g. after re-pulling it with different capabilities): tags are
# recomputed fresh from live sources on every run, never just carried over
# from a prior run. See output/CENTAURI-playbook.md §13 L-31/L-32/L-34/L-35.
#
# Usage:
#   bash scripts/pull-models.sh
#
# Environment:
#   LITELLM_URL         — LiteLLM base URL (default: http://localhost:9000)
#   LITELLM_MASTER_KEY  — bearer token (auto-read from Podman secret if unset)
#   CONFIG_FILE         — path to config.json, for the Ollama port used when
#                         probing the controller's own models for their
#                         supported modes (default: $AI_STACK_DIR/configs/config.json)
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
AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
CONFIG_FILE="${CONFIG_FILE:-$AI_STACK_DIR/configs/config.json}"
OLLAMA_PORT=11434
[[ -f "$CONFIG_FILE" ]] && OLLAMA_PORT="$(jq -r '.services.ollama.ports[0].host // 11434' "$CONFIG_FILE" 2>/dev/null || echo 11434)"

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
# Tagging: node classification ("strong-1" etc.) + supported modes
# (Ollama's "capabilities" — completion/tools/thinking/vision/etc.), merged
# into one model_info.tags list (output/CENTAURI-playbook.md §13 L-31/L-32/
# L-34/L-35).
#
# This script deletes and recreates every route on each run (see header
# comment) — any tag applied afterward via a separate PATCH /model/{id}/update
# call gets silently wiped on the very next run. L-32 found this the hard
# way. Fixing it here, as part of registration itself, means there's no
# separate step left to forget: node_tier/node_rank live on each node's own
# configs/nodes/*.json (the natural home for a node-level property — the
# controller's own DNS aliases map to the controller's node file since
# "ollama.ai-stack"/"vllm.ai-stack" never appear as a literal node address),
# and modes come fresh from a live /api/show call on whichever host actually
# serves the model — both looked up on every run, not persisted-then-hoped.
# Models with no matching host (cloud providers — no api_base at all) get no
# tier tag; non-Ollama backends (vLLM's plain OpenAI-compatible API) get no
# mode tags, since neither exposes an equivalent capabilities source. Nothing
# here is guessed when the real source isn't reachable.
# ---------------------------------------------------------------------------
declare -A HOST_TIER_RANK=()
for node_file in "$PROJECT_ROOT/configs/nodes"/*.json; do
    [[ -f "$node_file" ]] || continue
    n_tier="$(jq -r '.node_tier // empty' "$node_file")"
    n_rank="$(jq -r '.node_rank // empty' "$node_file")"
    [[ -z "$n_tier" || -z "$n_rank" ]] && continue
    while IFS= read -r addr; do
        [[ -n "$addr" ]] && HOST_TIER_RANK["$addr"]="$n_tier $n_rank"
    done < <(jq -r '[.address, .address_fallback] | map(select(. != null)) | .[]' "$node_file")
    if [[ "$(jq -r '.profile // empty' "$node_file")" == "controller" ]]; then
        for alias_host in ollama.ai-stack vllm.ai-stack localhost 127.0.0.1; do
            HOST_TIER_RANK["$alias_host"]="$n_tier $n_rank"
        done
    fi
done

_host_of() {
    local api_base="$1"
    [[ -z "$api_base" ]] && return
    local rest="${api_base#*://}"
    rest="${rest%%/*}"
    echo "${rest%%:*}"
}

# Live /api/show "capabilities" for one model on one host:port — empty JSON
# array on any failure (unreachable host, unknown model, bad response), never
# a guess.
_modes_for_model() {
    local host="$1" port="$2" model="$3"
    curl -s --max-time 5 "http://${host}:${port}/api/show" \
        -d "$(jq -nc --arg m "$model" '{model: $m}')" 2>/dev/null \
        | jq -c '.capabilities // []' 2>/dev/null || echo '[]'
}

# This script runs on the bare host, not inside the ai-stack podman network —
# "ollama.ai-stack" (used in litellm_params.api_base, resolvable only from
# other containers on that network) doesn't resolve here at all. Translate
# the controller's own aliases to localhost:$OLLAMA_PORT for the live probe;
# remote nodes are reached directly, same as the per-node-alias loop below.
_modes_host_port() {
    case "$1" in
        ollama.ai-stack|localhost|127.0.0.1) echo "localhost $OLLAMA_PORT" ;;
        *) echo "$1 11434" ;;
    esac
}

# model_id -> compact JSON tags array, collected during registration below so
# the OpenWebUI sync step afterward can push the exact same tags users see
# admin-side in LiteLLM (L-35: tags are useless to regular users if they only
# ever live in LiteLLM's own model_info — OpenWebUI has its own separate
# meta.tags field for the clickable chips in its model picker).
declare -A TAGS_BY_MODEL=()

# ---------------------------------------------------------------------------
# Register each model (delete existing entry first to ensure idempotency)
# ---------------------------------------------------------------------------
failures=0
for i in $(seq 0 $((model_count - 1))); do
    model_id="$(jq -r ".default_models[$i].id" "$MODELS_FILE")"
    litellm_params="$(jq -c ".default_models[$i].litellm_params" "$MODELS_FILE")"
    model_info="$(jq -c ".default_models[$i].model_info // {}" "$MODELS_FILE")"
    optional_params="$(jq -c ".default_models[$i].optional_params // {}" "$MODELS_FILE")"

    model_host="$(_host_of "$(echo "$litellm_params" | jq -r '.api_base // empty')")"
    model_backend_string="$(echo "$litellm_params" | jq -r '.model // empty')"

    tier_label=""
    if [[ -n "$model_host" && -n "${HOST_TIER_RANK[$model_host]:-}" ]]; then
        read -r model_tier model_rank <<< "${HOST_TIER_RANK[$model_host]}"
        tier_label="${model_tier}-${model_rank}"
    fi

    modes_json="[]"
    if [[ "$model_backend_string" == ollama_chat/* && -n "$model_host" ]]; then
        read -r probe_host probe_port <<< "$(_modes_host_port "$model_host")"
        modes_json="$(_modes_for_model "$probe_host" "$probe_port" "$model_id")"
    fi

    # Modes are sorted alphabetically so the merged tags list (and OpenWebUI's
    # synced copy of it) is in a consistent order every run, regardless of
    # whatever order Ollama's own /api/show happens to report capabilities in.
    tags_json="$(jq -nc --arg tier "$tier_label" --argjson modes "$modes_json" \
        '([$tier] | map(select(. != ""))) + ($modes | sort)')"

    if [[ "$(echo "$tags_json" | jq 'length')" -gt 0 ]]; then
        model_info="$(echo "$model_info" | jq --argjson tags "$tags_json" '. + {tags: $tags}')"
        TAGS_BY_MODEL["$model_id"]="$tags_json"
    fi

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
        --argjson op "$optional_params" \
        '{"model_name": $name, "litellm_params": $lp, "model_info": $mi} + (if $op != {} then {"optional_params": $op} else {} end)')"

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
# Sync the same tags into OpenWebUI's model.meta.tags (L-35 — see the big
# comment above TAGS_BY_MODEL). Only models that actually got a tag above are
# touched; a model with zero tags (e.g. a cloud provider) is left alone
# entirely, which is also how L-29's deliberate cloud-model exclusion from
# OpenWebUI's public picker stays intact here with no special-casing needed.
# Skipped gracefully (not a failure) if the openwebui container isn't up.
# ---------------------------------------------------------------------------
if [[ "${#TAGS_BY_MODEL[@]}" -gt 0 ]] && podman ps --format '{{.Names}}' 2>/dev/null | grep -qx openwebui; then
    tags_by_model_json="$(
        for k in "${!TAGS_BY_MODEL[@]}"; do
            jq -nc --arg k "$k" --argjson v "${TAGS_BY_MODEL[$k]}" '{($k): $v}'
        done | jq -sc 'add'
    )"
    echo "Syncing tags into OpenWebUI for ${#TAGS_BY_MODEL[@]} model(s) ..."
    TAGS_JSON="$tags_by_model_json" podman exec -e TAGS_JSON openwebui python3 -c "
import json, os, sqlite3, time, uuid

pairs = json.loads(os.environ['TAGS_JSON'])
conn = sqlite3.connect('/app/backend/data/webui.db')
c = conn.cursor()
c.execute(\"SELECT id FROM user WHERE role='admin' ORDER BY created_at ASC LIMIT 1\")
row = c.fetchone()
owner = row[0] if row else None

now = int(time.time())
synced, skipped = 0, 0
for model_id, tags in pairs.items():
    meta = json.dumps({'tags': [{'name': t} for t in tags]})
    c.execute('SELECT id FROM model WHERE id=?', (model_id,))
    if c.fetchone():
        c.execute('UPDATE model SET meta=?, updated_at=?, is_active=1 WHERE id=?', (meta, now, model_id))
        synced += 1
    elif owner:
        c.execute(
            'INSERT INTO model (id, user_id, base_model_id, name, meta, params, created_at, updated_at, is_active) '
            'VALUES (?, ?, NULL, ?, ?, ?, ?, ?, 1)',
            (model_id, owner, model_id, meta, '{}', now, now)
        )
        synced += 1
    else:
        skipped += 1
        continue
    c.execute(\"SELECT id FROM access_grant WHERE resource_type='model' AND resource_id=?\", (model_id,))
    if not c.fetchone():
        c.execute(
            \"INSERT INTO access_grant (id, resource_type, resource_id, principal_type, principal_id, permission, created_at) \"
            \"VALUES (?, 'model', ?, 'user', '*', 'read', ?)\",
            (str(uuid.uuid4()), model_id, now)
        )
conn.commit()
print(f'  OpenWebUI: synced {synced} model(s)' + (f', skipped {skipped} (no admin user found)' if skipped else ''))
"
else
    echo "Skipping OpenWebUI tag sync (no tagged models, or openwebui container not running)."
fi

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

