#!/usr/bin/env bats
# testing/layer2_remote_nodes.bats
#
# Layer 2 — Remote Inference Node Integration (T-090 through T-094)
# Validates that inference-worker nodes are reachable from the controller
# and that LiteLLM routes completions to their hosted models correctly.
#
# Node addresses are read from configs/config.json so tests stay in sync
# with the live configuration.
#
# Prerequisites:
#   - Layer 0 and Layer 1 must pass.
#   - LiteLLM must be running on the controller (localhost:${LITELLM_PORT}).
#   - The 'litellm_master_key' Podman secret must be provisioned.
#   - Remote nodes must be running ollama on port 11434 (or tests skip).
#
# Run: bats testing/layer2_remote_nodes.bats

load 'helpers'

# ---------------------------------------------------------------------------
# File-level setup — resolve addresses and auth key once
# ---------------------------------------------------------------------------

setup_file() {
    local missing=()
    command -v curl   &>/dev/null || missing+=(curl)
    command -v python3 &>/dev/null || missing+=(python3)

    if [[ "${#missing[@]}" -gt 0 ]]; then
        echo "ERROR: Remote node tests require: ${missing[*]}" >&3
        return 1
    fi

    # Resolve node addresses from config.json
    M1_HOST=$(python3 -c "
import json
nodes = json.load(open('$CONFIG_FILE'))['nodes']
n = next((n for n in nodes if n['name'] == 'macbook-m1'), None)
print(n['address'] if n else '')
" 2>/dev/null)

    M1_FALLBACK=$(python3 -c "
import json
nodes = json.load(open('$CONFIG_FILE'))['nodes']
n = next((n for n in nodes if n['name'] == 'macbook-m1'), None)
print(n.get('address_fallback','') or '' if n else '')
" 2>/dev/null)

    SOL_HOST=$(python3 -c "
import json
nodes = json.load(open('$CONFIG_FILE'))['nodes']
n = next((n for n in nodes if n['name'] == 'alienware'), None)
print(n['address'] if n else '')
" 2>/dev/null)

    SOL_FALLBACK=$(python3 -c "
import json
nodes = json.load(open('$CONFIG_FILE'))['nodes']
n = next((n for n in nodes if n['name'] == 'alienware'), None)
print(n.get('address_fallback','') or '' if n else '')
" 2>/dev/null)

    M1_MODEL=$(python3 -c "
import json
cfg = json.load(open('$CONFIG_FILE'))
nodes = cfg['nodes']
n = next((n for n in nodes if n['name'] == 'macbook-m1'), None)
print(n['models'][0] if n and n.get('models') else '')
" 2>/dev/null)

    SOL_MODEL=$(python3 -c "
import json
cfg = json.load(open('$CONFIG_FILE'))
nodes = cfg['nodes']
n = next((n for n in nodes if n['name'] == 'alienware'), None)
print(n['models'][0] if n and n.get('models') else '')
" 2>/dev/null)

    export M1_HOST M1_FALLBACK SOL_HOST SOL_FALLBACK M1_MODEL SOL_MODEL

    # Auth key
    LITELLM_KEY=$(read_secret "litellm_master_key")
    if [[ -z "$LITELLM_KEY" ]]; then
        echo "ERROR: Could not read 'litellm_master_key' secret." >&3
        return 1
    fi
    export LITELLM_KEY
}

# ---------------------------------------------------------------------------
# T-090 — TCP reachability: M1 Ollama port 11434
# ---------------------------------------------------------------------------
#
# Skips if no address is configured for macbook-m1 in config.json.
# Tries the primary address first, then the fallback IP.
# ---------------------------------------------------------------------------

@test "T-090: M1 Ollama port 11434 is reachable from controller" {
    if [[ -z "$M1_HOST" && -z "$M1_FALLBACK" ]]; then
        skip "macbook-m1 address not configured in config.json"
    fi

    local host="${M1_HOST:-$M1_FALLBACK}"
    if ! probe_node "$host" 11434; then
        # Try fallback before failing
        if [[ -n "$M1_FALLBACK" ]] && ! probe_node "$M1_FALLBACK" 11434; then
            skip "macbook-m1 ($host / $M1_FALLBACK) not reachable on port 11434"
        fi
    fi
}

# ---------------------------------------------------------------------------
# T-091 — LiteLLM /v1/models lists M1-hosted model
# ---------------------------------------------------------------------------

@test "T-091: LiteLLM /v1/models lists the M1-hosted model" {
    if [[ -z "$M1_MODEL" ]]; then
        skip "No model configured for macbook-m1 in config.json"
    fi

    local host="${M1_HOST:-$M1_FALLBACK}"
    if [[ -n "$host" ]] && ! probe_node "$host" 11434; then
        if [[ -z "$M1_FALLBACK" ]] || ! probe_node "$M1_FALLBACK" 11434; then
            skip "macbook-m1 not reachable — skipping model list check"
        fi
    fi

    run curl -s --max-time 15 \
        -H "Authorization: Bearer $LITELLM_KEY" \
        "http://localhost:${LITELLM_PORT}/v1/models"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed connecting to LiteLLM (exit $status)" >&3
        return 1
    }

    echo "$output" | python3 -c "
import json,sys
data = json.load(sys.stdin)
models = [m['id'] for m in data.get('data',[])]
target = '$(echo "$M1_MODEL")'
assert target in models, f'{target!r} not found in /v1/models: {models}'
" || {
        echo "M1 model '$M1_MODEL' not listed in LiteLLM /v1/models" >&3
        echo "Response: $output" >&3
        return 1
    }
}

# ---------------------------------------------------------------------------
# T-092 — Completion routed to M1-hosted model returns content
# ---------------------------------------------------------------------------

@test "T-092: completion request to M1-hosted model returns content" {
    if [[ -z "$M1_MODEL" ]]; then
        skip "No model configured for macbook-m1 in config.json"
    fi

    local host="${M1_HOST:-$M1_FALLBACK}"
    if [[ -n "$host" ]] && ! probe_node "$host" 11434; then
        if [[ -z "$M1_FALLBACK" ]] || ! probe_node "$M1_FALLBACK" 11434; then
            skip "macbook-m1 not reachable — skipping completion test"
        fi
    fi

    run curl -s --max-time 60 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $LITELLM_KEY" \
        -d "{\"model\":\"$M1_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with only: TC25 OK\"}],\"max_tokens\":20}" \
        "http://localhost:${LITELLM_PORT}/v1/chat/completions"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed (exit $status)" >&3
        return 1
    }

    local content
    content=$(echo "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
" 2>/dev/null)

    [[ -n "$content" ]] || {
        echo "Empty or invalid completion response from M1 model '$M1_MODEL'" >&3
        echo "Response: $output" >&3
        return 1
    }
    echo "M1 response: $content" >&3
}

# ---------------------------------------------------------------------------
# T-093 — TCP reachability: Alienware Ollama port 11434
# ---------------------------------------------------------------------------

@test "T-093: Alienware Ollama port 11434 is reachable from controller" {
    if [[ -z "$SOL_HOST" && -z "$SOL_FALLBACK" ]]; then
        skip "alienware address not configured in config.json"
    fi

    local host="${SOL_HOST:-$SOL_FALLBACK}"
    if ! probe_node "$host" 11434; then
        if [[ -n "$SOL_FALLBACK" ]] && ! probe_node "$SOL_FALLBACK" 11434; then
            skip "alienware ($host / $SOL_FALLBACK) not reachable on port 11434"
        fi
    fi
}

# ---------------------------------------------------------------------------
# T-094 — Completion routed to Alienware model returns content
# ---------------------------------------------------------------------------

@test "T-094: completion request to Alienware-hosted model returns content" {
    if [[ -z "$SOL_MODEL" ]]; then
        skip "No model configured for alienware in config.json"
    fi

    local host="${SOL_HOST:-$SOL_FALLBACK}"
    if [[ -n "$host" ]] && ! probe_node "$host" 11434; then
        if [[ -z "$SOL_FALLBACK" ]] || ! probe_node "$SOL_FALLBACK" 11434; then
            skip "alienware not reachable — skipping completion test"
        fi
    fi

    run curl -s --max-time 60 \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $LITELLM_KEY" \
        -d "{\"model\":\"$SOL_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"reply with only: SOL OK\"}],\"max_tokens\":20}" \
        "http://localhost:${LITELLM_PORT}/v1/chat/completions"

    [[ "$status" -eq 0 ]] || {
        echo "curl failed (exit $status)" >&3
        return 1
    }

    local content
    content=$(echo "$output" | python3 -c "
import json,sys
d = json.load(sys.stdin)
print(d['choices'][0]['message']['content'])
" 2>/dev/null)

    [[ -n "$content" ]] || {
        echo "Empty or invalid completion response from Alienware model '$SOL_MODEL'" >&3
        echo "Response: $output" >&3
        return 1
    }
    echo "SOL response: $content" >&3
}
