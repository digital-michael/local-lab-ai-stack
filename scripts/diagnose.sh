#!/usr/bin/env bash
# scripts/diagnose.sh — Per-service diagnostic walkthrough for the AI stack
#
# Profiles:
#   quick (default) — systemd state, container health, network existence,
#                     dependency reachability, model availability
#   full            — quick + integration probes, config validation, secrets,
#                     volume paths, resource pressure, API readiness probes
#
# Exit codes:
#   0  All checked services pass or are intentionally skipped
#   1  One or more services have warnings or failures
#   2  Stack not deployed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"
NODE_PROFILE_FILE="${NODE_PROFILE_FILE:-$PROJECT_ROOT/configs/node_profile}"

_get_node_profile() {
    if [[ -f "$NODE_PROFILE_FILE" ]]; then
        local p; p=$(tr -d '[:space:]' < "$NODE_PROFILE_FILE")
        [[ -n "$p" ]] && { echo "$p"; return; }
    fi
    jq -r '.node_profile // "controller"' "$CONFIG_FILE" 2>/dev/null || echo "controller"
}
QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"

FIX=false
LOG_LINES=15
PROFILE=quick
TARGETS=()

usage() {
    cat <<'EOF'
Usage: diagnose.sh [options] [service...]

Purpose:
  Walk AI stack services in dependency order, diagnose each service, and
  surface evidence for failures. Optionally restart broken services.

  If one or more service names are given, only those services are checked
  (evaluated in dependency order regardless).

Profiles:
  quick (default)
    - Systemd service state
    - Container health check status
    - Stack network existence
    - Dependency reachability (inter-container TCP to declared depends_on)
    - Model availability (ollama)

  full
    - Everything in quick, plus:
    - Integration probes (cross-service auth & config correctness)
    - Config validation (configure.sh validate)
    - Secrets presence (all referenced podman secrets exist)
    - Volume / data path existence
    - Container resource pressure (memory near limit, threshold 85%)
    - Per-service API readiness probes (HTTP/app-layer, not just TCP)

Options:
  --profile quick|full   Diagnostic profile (default: quick)
  --fix                  Restart services in 'failed' or 'unhealthy' state
  --log-lines N          Container log lines shown on failure (default: 15)
  -h, --help             Show this message

Exit codes:
  0   All checked services pass or are intentionally skipped
  1   One or more services have warnings or failures
  2   Stack not deployed

Environment:
  CONFIG_FILE   Path to config.json  (default: ./configs/config.json)
  QUADLET_DIR   Quadlet directory    (default: ~/.config/containers/systemd)

Examples:
  diagnose.sh                        # quick check, all services
  diagnose.sh --fix                  # quick check + restart broken services
  diagnose.sh litellm ollama         # quick check, specific services only
  diagnose.sh --profile full         # full check (all categories)
  diagnose.sh --fix --log-lines 30   # verbose fix run
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fix)              FIX=true ;;
        --log-lines)        shift; LOG_LINES="${1:?--log-lines requires a number}" ;;
        --profile)          shift; PROFILE="${1:?--profile requires quick|full}" ;;
        -h|--help)          usage; exit 0 ;;
        -*)                 echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
        *)                  TARGETS+=("$1") ;;
    esac
    shift
done

if [[ "$PROFILE" != "quick" && "$PROFILE" != "full" ]]; then
    echo "ERROR: Unknown profile '$PROFILE'. Valid: quick, full" >&2
    exit 1
fi

# ── Prerequisites ─────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2; exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2; exit 1
fi

# ── Deployment check ──────────────────────────────────────────────────────────

deploy_check=0
"$SCRIPT_DIR/status.sh" --check --quiet 2>/dev/null || deploy_check=$?
if [[ $deploy_check -eq 2 ]]; then
    echo "Stack is NOT DEPLOYED. Run: ./scripts/deploy.sh && ./scripts/start.sh"
    exit 2
fi

# ── Build service list in topological (dependency-first) order ────────────────

declare -A _visited=()
ordered=()

_topo_visit() {
    local svc="$1"
    [[ -v _visited[$svc] ]] && return
    _visited[$svc]=1
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        _topo_visit "$dep"
    done < <(jq -r --arg s "$svc" '.services[$s].depends_on[]?' "$CONFIG_FILE" 2>/dev/null || true)
    ordered+=("$svc")
}

while IFS= read -r svc; do
    _topo_visit "$svc"
done < <(jq -r '.services | keys[]' "$CONFIG_FILE")

# Filter to requested targets if specified, preserving dependency order
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    filtered=()
    for svc in "${ordered[@]}"; do
        for t in "${TARGETS[@]}"; do
            [[ "$svc" == "$t" ]] && { filtered+=("$svc"); break; }
        done
    done
    if [[ ${#filtered[@]} -eq 0 ]]; then
        echo "ERROR: No matching services for: ${TARGETS[*]}" >&2
        echo "Known services: $(jq -r '.services | keys | join(", ")' "$CONFIG_FILE")" >&2
        exit 1
    fi
    ordered=("${filtered[@]}")
fi

# ── State tracking ────────────────────────────────────────────────────────────

declare -A svc_result=()   # svc -> PASS|WARN|FAIL|SKIP|FIXD
_RESULT=""                 # set by _diagnose, read by main loop

# ── Helper: is service GPU-gated (expected stopped on CPU-only nodes) ──────────

_is_gpu_gated() {
    local gpu
    gpu=$(jq -r --arg s "$1" '.services[$s].resources.gpu // empty' "$CONFIG_FILE" 2>/dev/null || true)
    [[ -n "$gpu" ]]
}

# ── Helper: indent a block of text ────────────────────────────────────────────

_indent() { sed 's/^/           /'; }

# ── Helper: TCP reachability from inside a container ─────────────────────────
# Tries bash /dev/tcp first; falls back to nc -zw2 if bash is unavailable.
# Usage: _tcp_reach <exec_container> <target_host> <port>
# Returns 0 if reachable, 1 if not

_tcp_reach() {
    local container="$1" host="$2" port="$3"
    if podman exec "$container" bash -c \
            "echo > /dev/tcp/${host}/${port}" 2>/dev/null; then
        return 0
    fi
    # bash unavailable or /dev/tcp failed — try nc
    podman exec "$container" nc -zw2 "$host" "$port" 2>/dev/null
}

# ── Quick check: network existence ────────────────────────────────────────────

_check_network() {
    local net_name
    net_name=$(jq -r '.network.name' "$CONFIG_FILE" 2>/dev/null || echo "ai-stack-net")
    echo "  Network"
    if podman network exists "$net_name" 2>/dev/null; then
        printf "  [PASS] %-20s exists\n" "$net_name"
        return 0
    else
        printf "  [FAIL] %-20s MISSING — run: podman network create %s\n" "$net_name" "$net_name"
        return 1
    fi
}

# ── Quick check: model availability (Ollama CPU + vLLM GPU) ─────────────────

_check_models() {
    echo ""
    echo "  Model Availability"
    local ollama_state vllm_state
    ollama_state=$(systemctl --user is-active "ollama.service" 2>/dev/null || true)
    vllm_state=$(systemctl --user is-active "vllm.service" 2>/dev/null || true)

    # Ollama CPU models
    if [[ "$ollama_state" != "active" ]]; then
        printf "  [SKIP] %-28s ollama not running\n" "ollama/models"
    else
        local model_list
        model_list=$(podman exec ollama ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || true)

        if [[ -z "$model_list" ]]; then
            printf "  [WARN] %-28s no models loaded — run: ./scripts/pull-models.sh\n" "ollama/models"
        else
            local count
            count=$(echo "$model_list" | wc -l)
            printf "  [PASS] %-28s %d model(s): %s\n" "ollama/models" "$count" \
                "$(echo "$model_list" | tr '\n' ' ' | sed 's/ $//')"
        fi

        # Check CPU pinning
        local cuda_vis
        cuda_vis=$(podman exec ollama sh -c 'echo "${CUDA_VISIBLE_DEVICES-unset}"' 2>/dev/null || true)
        if [[ "$cuda_vis" == "" ]]; then
            printf "  [PASS] %-28s CUDA_VISIBLE_DEVICES=\"\" (CPU-pinned)\n" "ollama/cpu-pinned"
        elif [[ "$cuda_vis" == "unset" ]]; then
            printf "  [WARN] %-28s CUDA_VISIBLE_DEVICES not set — Ollama may claim GPU\n" "ollama/cpu-pinned"
        else
            printf "  [WARN] %-28s CUDA_VISIBLE_DEVICES=%s (unexpected value)\n" "ollama/cpu-pinned" "$cuda_vis"
        fi
    fi

    # vLLM GPU model
    if [[ "$vllm_state" != "active" ]]; then
        if _is_gpu_gated "vllm"; then
            printf "  [SKIP] %-28s vllm not running (GPU-gated)\n" "vllm/model"
        fi
    else
        local vllm_models
        vllm_models=$(curl -sf http://localhost:8000/v1/models 2>/dev/null \
            | jq -r '.data[].id' 2>/dev/null | tr '\n' ' ' | sed 's/ $//' || true)
        if [[ -n "$vllm_models" ]]; then
            printf "  [PASS] %-28s %s (GPU)\n" "vllm/model" "$vllm_models"
        else
            printf "  [WARN] %-28s vllm running but no models served\n" "vllm/model"
        fi
    fi
}

# ── Per-service diagnostic ────────────────────────────────────────────────────
# Sets _RESULT to: PASS | WARN | SKIP | FIXD | FAIL

_diagnose() {
    local svc="$1"
    local col=20
    local state health

    state=$(systemctl --user is-active "${svc}.service" 2>/dev/null || true)
    [[ -z "$state" ]] && state="unknown"

    # ── Check for failing dependencies (cascade warning) ──────────────────────
    local cascade_warn=""
    local dep
    while IFS= read -r dep; do
        [[ -z "$dep" ]] && continue
        if [[ "${svc_result[$dep]:-}" == "FAIL" ]]; then
            cascade_warn+="         ! dependency '${dep}' is also FAIL — may be cascading\n"
        fi
    done < <(jq -r --arg s "$svc" '.services[$s].depends_on[]?' "$CONFIG_FILE" 2>/dev/null || true)

    # ── GPU-gated: stopped service with GPU requirement → SKIP ────────────────
    if [[ "$state" != "active" ]] && _is_gpu_gated "$svc"; then
        printf "  [SKIP] %-${col}s stopped (GPU-gated — expected on CPU-only node)\n" "$svc"
        _RESULT="SKIP"
        return
    fi

    # ── Active: check container health ────────────────────────────────────────
    if [[ "$state" == "active" ]]; then
        health=$(podman inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || true)
        case "$health" in
            healthy|"")
                local health_label="healthy"
                [[ -z "$health" ]] && health_label="no health check"

                # ── Dependency reachability ────────────────────────────────
                local dep dep_host dep_port reach_fail=0 reach_msgs=()
                while IFS= read -r dep; do
                    [[ -z "$dep" ]] && continue
                    _is_gpu_gated "$dep" && continue
                    dep_host=$(jq -r --arg d "$dep" '.services[$d].dns_alias // empty' "$CONFIG_FILE")
                    dep_port=$(jq -r --arg d "$dep" '.services[$d].ports[0].container // empty' "$CONFIG_FILE")
                    [[ -z "$dep_host" || -z "$dep_port" ]] && continue
                    if ! _tcp_reach "$svc" "$dep_host" "$dep_port" 2>/dev/null; then
                        reach_msgs+=("cannot reach ${dep_host}:${dep_port}")
                        reach_fail=$((reach_fail + 1))
                    fi
                done < <(jq -r --arg s "$svc" '.services[$s].depends_on[]?' "$CONFIG_FILE" 2>/dev/null || true)

                if [[ $reach_fail -gt 0 ]]; then
                    printf "  [WARN] %-${col}s active / %s\n" "$svc" "$health_label"
                    for msg in "${reach_msgs[@]}"; do
                        printf "         ! %s\n" "$msg"
                    done
                    _RESULT="WARN"
                else
                    printf "  [PASS] %-${col}s active / %s\n" "$svc" "$health_label"
                    _RESULT="PASS"
                fi
                return ;;
            starting)
                printf "  [WARN] %-${col}s active / health check in progress\n" "$svc"
                _RESULT="WARN"
                return ;;
            unhealthy)
                : ;; # fall through to failure handling
        esac
    fi

    # ── Service is failed / unhealthy / stopped unexpectedly ──────────────────

    # Attempt restart if --fix was requested
    if $FIX; then
        printf "  [....] %-${col}s %s — restarting...\n" "$svc" "${health:-$state}"
        systemctl --user restart "${svc}.service" 2>/dev/null || true
        sleep 8
        local new_state new_health
        new_state=$(systemctl --user is-active "${svc}.service" 2>/dev/null || true)
        new_health=$(podman inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || true)
        if [[ "$new_state" == "active" ]]; then
            printf "  [FIXD] %-${col}s restarted → active / %s\n" "$svc" "${new_health:-no health check}"
            _RESULT="FIXD"
            return
        else
            printf "  [FAIL] %-${col}s restart attempted — still: %s\n" "$svc" "$new_state"
        fi
    else
        printf "  [FAIL] %-${col}s %s / %s\n" "$svc" "$state" "${health:-n/a}"
    fi

    # ── Detail block ──────────────────────────────────────────────────────────

    # Cascade warning
    [[ -n "$cascade_warn" ]] && printf "%b" "$cascade_warn"

    # Health check log (last 3 entries, for active/unhealthy)
    if [[ "$state" == "active" ]]; then
        local hlog
        hlog=$(podman inspect --format \
            '{{range .State.Health.Log}}Exit:{{.ExitCode}} | {{.Output}}{{"\n"}}{{end}}' \
            "$svc" 2>/dev/null | grep -v '^[[:space:]]*$' | tail -3 || true)
        if [[ -n "$hlog" ]]; then
            echo "         Health log (last 3):"
            echo "$hlog" | _indent
        fi
    fi

    # Journal (for failed/stopped units)
    if [[ "$state" == "failed" || "$state" == "stopped" || "$state" == "unknown" ]]; then
        echo "         Journal (last 5 lines):"
        journalctl --user -u "${svc}.service" --no-pager -n 5 2>/dev/null \
            | _indent || true
    fi

    # Container log tail
    echo "         Container logs (last ${LOG_LINES} lines):"
    podman logs --tail "$LOG_LINES" "$svc" 2>&1 | _indent || true
    echo ""

    _RESULT="FAIL"
}

# ── Full check: cross-service integration probes ─────────────────────────────
# Checks functional relationships between services that go beyond TCP
# reachability: authentication, API key alignment, URL correctness.

_check_integrations() {
    echo ""
    echo "  Integrations"
    local fail=0

    # ── openwebui → litellm: API key auth ────────────────────────────────────
    local ow_state litellm_state
    ow_state=$(systemctl --user is-active "openwebui.service" 2>/dev/null || true)
    litellm_state=$(systemctl --user is-active "litellm.service" 2>/dev/null || true)

    if [[ "$ow_state" == "active" && "$litellm_state" == "active" ]]; then
        local ow_key litellm_url
        ow_key=$(podman exec openwebui env 2>/dev/null | grep '^OPENAI_API_KEY=' | cut -d= -f2- || true)
        litellm_url=$(podman exec openwebui env 2>/dev/null | grep '^OPENAI_API_BASE=' | cut -d= -f2- || true)

        if [[ -z "$ow_key" ]]; then
            printf "  [WARN] %-28s OPENAI_API_KEY not set in openwebui\n" "openwebui→litellm"
            warn=$((warn + 1))
        else
            local auth_rc=0
            podman exec openwebui curl -sf \
                -H "Authorization: Bearer ${ow_key}" \
                "${litellm_url}/v1/models" &>/dev/null || auth_rc=$?

            if [[ $auth_rc -eq 0 ]]; then
                printf "  [PASS] %-28s API key authenticates to LiteLLM\n" "openwebui→litellm"
            else
                printf "  [FAIL] %-28s OPENAI_API_KEY rejected by LiteLLM (401)\n" "openwebui→litellm"
                echo "         ! openwebui OPENAI_API_KEY does not match litellm_master_key"
                if $FIX; then
                    local master_key
                    master_key=$(podman secret inspect litellm_master_key --showsecret \
                        2>/dev/null | jq -r '.[].SecretData' || true)
                    if [[ -n "$master_key" ]]; then
                        podman secret rm openwebui_api_key &>/dev/null || true
                        printf '%s' "$master_key" | podman secret create openwebui_api_key - &>/dev/null
                        systemctl --user restart openwebui.service 2>/dev/null || true
                        sleep 12
                        printf "  [FIXD] %-28s openwebui_api_key aligned to litellm_master_key; restarted\n" "openwebui→litellm"
                    else
                        echo "         ! --fix: could not read litellm_master_key secret"
                        fail=$((fail + 1))
                    fi
                else
                    echo "         ! Fix: align openwebui_api_key to litellm_master_key"
                    echo "         !   podman secret rm openwebui_api_key"
                    echo "         !   printf '<master-key>' | podman secret create openwebui_api_key -"
                    echo "         !   systemctl --user restart openwebui.service"
                    fail=$((fail + 1))
                fi
            fi
        fi
    else
        printf "  [SKIP] %-28s openwebui or litellm not active\n" "openwebui→litellm"
    fi

    # ── openwebui: OLLAMA_BASE_URL env must be a proper http:// URL ─────────
    if [[ "$ow_state" == "active" ]]; then
        local ollama_url
        ollama_url=$(podman exec openwebui env 2>/dev/null | grep '^OLLAMA_BASE_URL=' | cut -d= -f2- || true)

        if [[ -z "$ollama_url" ]]; then
            printf "  [WARN] %-28s OLLAMA_BASE_URL not set (will use image default)\n" "openwebui/OLLAMA_BASE_URL"
            warn=$((warn + 1))
        elif [[ "$ollama_url" != http://* && "$ollama_url" != https://* ]]; then
            printf "  [FAIL] %-28s OLLAMA_BASE_URL='%s' is not a valid URL\n" "openwebui/OLLAMA_BASE_URL" "$ollama_url"
            echo "         ! Image default '/ollama' is a Docker Compose nginx-proxy path"
            echo "         ! Expected: http://ollama.ai-stack:11434"
            if $FIX; then
                # Update config.json and regenerate quadlet
                local tmp
                tmp=$(mktemp)
                jq '.services.openwebui.environment.OLLAMA_BASE_URL = "http://ollama.ai-stack:11434"' \
                    "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
                "$SCRIPT_DIR/configure.sh" generate-quadlets &>/dev/null
                systemctl --user daemon-reload
                systemctl --user restart openwebui.service 2>/dev/null || true
                sleep 12
                printf "  [FIXD] %-28s OLLAMA_BASE_URL set in config.json; quadlet regenerated; restarted\n" "openwebui/OLLAMA_BASE_URL"
            else
                echo "         ! Fix: add to configs/config.json openwebui.environment:"
                echo "         !   \"OLLAMA_BASE_URL\": \"http://ollama.ai-stack:11434\""
                echo "         !   Then: configure.sh generate-quadlets && systemctl --user restart openwebui"
                fail=$((fail + 1))
            fi
        else
            printf "  [PASS] %-28s OLLAMA_BASE_URL=%s\n" "openwebui/OLLAMA_BASE_URL" "$ollama_url"
        fi

        # ── openwebui: DB-persisted Ollama base_url must not be Docker default ──
        # Open WebUI stores connection URLs in its SQLite config table.
        # The image ships with host.docker.internal:11434 as the default; it takes
        # precedence over OLLAMA_BASE_URL when it has been written to the DB.
        local db_ollama_url
        db_ollama_url=$(podman exec openwebui python3 -c "
import sqlite3, json, sys
try:
    conn = sqlite3.connect('/app/backend/data/webui.db')
    row = conn.execute('SELECT data FROM config WHERE id=1').fetchone()
    if row:
        cfg = json.loads(row[0])
        urls = cfg.get('ollama', {}).get('base_urls', [])
        print(urls[0] if urls else '')
except Exception as e:
    print('', file=sys.stderr)
" 2>/dev/null || true)

        if [[ -n "$db_ollama_url" && "$db_ollama_url" == *"docker.internal"* ]]; then
            printf "  [FAIL] %-28s DB Ollama URL='%s' (Docker default)\n" "openwebui/db-ollama-url" "$db_ollama_url"
            echo "         ! webui.db config.ollama.base_urls still points to host.docker.internal"
            echo "         ! This overrides OLLAMA_BASE_URL env and blocks all Ollama API calls"
            if $FIX; then
                podman exec openwebui python3 -c "
import sqlite3, json
conn = sqlite3.connect('/app/backend/data/webui.db')
row = conn.execute('SELECT data FROM config WHERE id=1').fetchone()
cfg = json.loads(row[0])
cfg['ollama']['base_urls'] = ['http://ollama.ai-stack:11434']
conn.execute('UPDATE config SET data=? WHERE id=1', (json.dumps(cfg),))
conn.commit()
" 2>/dev/null
                systemctl --user restart openwebui.service 2>/dev/null || true
                sleep 12
                printf "  [FIXD] %-28s DB Ollama URL updated to http://ollama.ai-stack:11434; restarted\n" "openwebui/db-ollama-url"
            else
                echo "         ! Fix: update webui.db or use Admin Panel > Connections > Ollama API"
                echo "         !   Set URL to: http://ollama.ai-stack:11434"
                fail=$((fail + 1))
            fi
        elif [[ -n "$db_ollama_url" ]]; then
            printf "  [PASS] %-28s DB Ollama URL=%s\n" "openwebui/db-ollama-url" "$db_ollama_url"
        fi
    else
        printf "  [SKIP] %-28s openwebui not active\n" "openwebui/OLLAMA_BASE_URL"
    fi

    return $fail
}

# ── Full check: GPU state and CDI configuration ──────────────────────────────

_check_gpu() {
    echo ""
    echo "  GPU / CDI"

    # CDI config
    if ls /etc/cdi/nvidia.yaml &>/dev/null || ls /run/cdi/nvidia.yaml &>/dev/null; then
        printf "  [PASS] %-28s nvidia.yaml present\n" "cdi/config"
    else
        printf "  [FAIL] %-28s CDI not configured\n" "cdi/config"
        echo "         ! Fix: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
        return 1
    fi

    if ! command -v nvidia-smi &>/dev/null; then
        printf "  [SKIP] %-28s nvidia-smi not found on host\n" "gpu/vram"
        return 0
    fi

    # GPU VRAM utilisation
    local total free used pct
    total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    free=$(nvidia-smi  --query-gpu=memory.free  --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    used=$(nvidia-smi  --query-gpu=memory.used  --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
    pct=$(awk "BEGIN{printf \"%d\", ($used/$total)*100}" 2>/dev/null || echo "?")
    printf "  [PASS] %-28s %d MiB used / %d MiB total (%d%%)\n" "gpu/vram" "$used" "$total" "$pct"

    # vLLM process on GPU
    local vllm_state
    vllm_state=$(systemctl --user is-active "vllm.service" 2>/dev/null || true)
    if [[ "$vllm_state" == "active" ]]; then
        local vllm_gpu_proc
        vllm_gpu_proc=$(nvidia-smi --query-compute-apps=pid,process_name,used_memory \
            --format=csv,noheader 2>/dev/null | grep -i vllm || true)
        if [[ -n "$vllm_gpu_proc" ]]; then
            printf "  [PASS] %-28s vLLM process using GPU\n" "gpu/vllm-process"
        else
            printf "  [WARN] %-28s vLLM running but no GPU process found\n" "gpu/vllm-process"
        fi
    else
        printf "  [SKIP] %-28s vLLM not active\n" "gpu/vllm-process"
    fi
}

# ── Full check: config validation via configure.sh ───────────────────────────

_check_config_validate() {
    echo ""
    echo "  Config Validation"
    local out rc=0
    out=$("$SCRIPT_DIR/configure.sh" validate 2>&1) || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "  [PASS] %-20s config valid\n" "configure.sh"
    else
        printf "  [FAIL] %-20s configure.sh validate reported errors\n" "configure.sh"
        echo "$out" | sed 's/^/           /'
    fi
    return $rc
}

# ── Full check: secrets presence ─────────────────────────────────────────────
# Checks that every podman secret referenced across all services exists.

_check_secrets() {
    echo ""
    echo "  Secrets"
    local all_secrets fail=0
    all_secrets=$(jq -r '[.services[].secrets[]?.name] | unique[]' "$CONFIG_FILE" 2>/dev/null || true)

    if [[ -z "$all_secrets" ]]; then
        printf "  [SKIP] %-20s no secrets defined\n" "secrets"
        return 0
    fi

    while IFS= read -r secret; do
        [[ -z "$secret" ]] && continue
        if podman secret inspect "$secret" &>/dev/null; then
            printf "  [PASS] %-20s present\n" "$secret"
        else
            printf "  [FAIL] %-20s MISSING — run: ./scripts/configure.sh generate-secrets\n" "$secret"
            fail=$((fail + 1))
        fi
    done <<< "$all_secrets"
    return $fail
}

# ── Full check: volume/data path existence ────────────────────────────────────
# Expands $AI_STACK_DIR and $HOME in volume host paths and checks existence.

_check_volumes() {
    echo ""
    echo "  Volume Paths"
    local ai_stack_dir fail=0
    ai_stack_dir=$(jq -r '.ai_stack_dir' "$CONFIG_FILE" 2>/dev/null || echo '$HOME/ai-stack')
    ai_stack_dir="${ai_stack_dir//\$HOME/$HOME}"

    # Collect unique host paths across all services (scoped to TARGETS if set)
    local paths
    if [[ ${#TARGETS[@]} -gt 0 ]]; then
        local svc_filter
        svc_filter=$(printf '"%s",' "${TARGETS[@]}")
        svc_filter="[${svc_filter%,}]"
        paths=$(jq -r --argjson svcs "$svc_filter" \
            '[.services | to_entries[] | select([.key] | inside($svcs))
             | .value.volumes[]?.host] | unique[]' "$CONFIG_FILE" 2>/dev/null || true)
    else
        paths=$(jq -r '[.services[].volumes[]?.host] | unique[]' "$CONFIG_FILE" 2>/dev/null || true)
    fi

    if [[ -z "$paths" ]]; then
        printf "  [SKIP] %-20s no volumes configured for checked services\n" "volumes"
        return 0
    fi

    while IFS= read -r raw_path; do
        [[ -z "$raw_path" ]] && continue
        local expanded="${raw_path//\$AI_STACK_DIR/$ai_stack_dir}"
        expanded="${expanded//\$HOME/$HOME}"
        local label="${raw_path/$ai_stack_dir/\$AI_STACK_DIR}"
        if [[ -e "$expanded" ]]; then
            printf "  [PASS] %-44s exists\n" "$label"
        else
            printf "  [WARN] %-44s MISSING — run: ./scripts/install.sh\n" "$label"
            fail=$((fail + 1))
        fi
    done <<< "$paths"
    return $fail
}

# ── Full check: container resource pressure ───────────────────────────────────
# Warns when a container is using >85% of its memory limit.

_check_resource_pressure() {
    echo ""
    echo "  Resource Pressure"
    local threshold=85 warn=0

    # podman stats --no-stream exits non-zero when no containers match; tolerate
    local stats_out
    stats_out=$(podman stats --no-stream \
        --format "{{.Name}} {{.MemPerc}}" 2>/dev/null || true)

    if [[ -z "$stats_out" ]]; then
        printf "  [SKIP] %-20s no running containers found\n" "resource-pressure"
        return 0
    fi

    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        local name pct
        name=$(echo "$line" | awk '{print $1}')
        pct=$(echo "$line" | awk '{gsub(/%/,"",$2); printf "%.0f", $2}')

        # Filter to scoped targets if provided
        if [[ ${#TARGETS[@]} -gt 0 ]]; then
            local match=false
            for t in "${TARGETS[@]}"; do [[ "$name" == "$t" ]] && { match=true; break; }; done
            $match || continue
        fi

        local usage_raw
        usage_raw=$(podman stats --no-stream --format "{{.MemUsage}}" "$name" 2>/dev/null || true)
        if [[ $pct -ge $threshold ]]; then
            printf "  [WARN] %-20s memory ${pct}%% of limit  (%s)\n" "$name" "$usage_raw"
            warn=$((warn + 1))
        else
            printf "  [PASS] %-20s memory ${pct}%% of limit  (%s)\n" "$name" "$usage_raw"
        fi
    done <<< "$stats_out"
    return $warn
}

# ── Full check: library custody status (controller only) ─────────────────────
# Hits GET /v1/catalog on the local knowledge-index KI and reports which
# libraries have been synced (synced_at non-null) and which are missing.
# Only runs when NODE_PROFILE=controller and knowledge-index is active.

_check_library_custody() {
    echo ""
    echo "  Library Custody"
    local node_profile
    node_profile=$(_get_node_profile)

    if [[ "$node_profile" != "controller" ]]; then
        printf "  [SKIP] %-20s not a controller node\n" "library-custody"
        return 0
    fi

    local ki_state
    ki_state=$(systemctl --user is-active knowledge-index.service 2>/dev/null || true)
    if [[ "$ki_state" != "active" ]]; then
        printf "  [SKIP] %-20s knowledge-index not active\n" "library-custody"
        return 0
    fi

    local ki_port catalog_url response
    ki_port=$(jq -r '.services["knowledge-index"].ports[0] // "8100"' "$CONFIG_FILE" 2>/dev/null \
        | grep -oP '^\d+' || echo "8100")
    catalog_url="http://localhost:${ki_port}/v1/catalog"

    response=$(curl -sf --max-time 5 "$catalog_url" 2>/dev/null) || {
        printf "  [FAIL] %-20s /v1/catalog unreachable at %s\n" "library-custody" "$catalog_url"
        return 1
    }

    local total synced unsynced
    total=$(echo "$response"   | jq '.libraries | length' 2>/dev/null || echo 0)
    synced=$(echo "$response"  | jq '[.libraries[] | select(.synced_at != null)] | length' 2>/dev/null || echo 0)
    unsynced=$(echo "$response" | jq '[.libraries[] | select(.synced_at == null)] | length' 2>/dev/null || echo 0)

    if [[ "$total" -eq 0 ]]; then
        printf "  [PASS] %-20s no libraries in custody\n" "library-custody"
        return 0
    fi

    if [[ "$unsynced" -gt 0 ]]; then
        printf "  [WARN] %-20s %d/%d libraries missing custody copy\n" "library-custody" "$unsynced" "$total"
        echo "$response" | jq -r '.libraries[] | select(.synced_at == null) | "         ! \(.name):\(.version) (origin: \(.origin_node // "unknown"))"' 2>/dev/null || true
        warn=$((warn + 1))
    else
        printf "  [PASS] %-20s %d/%d libraries synced\n" "library-custody" "$synced" "$total"
    fi

    # Warn if any known worker node has contributed zero libraries
    local worker_nodes
    worker_nodes=$(jq -r '.nodes[] | select(.profile == "inference-worker") | .name' "$CONFIG_FILE" 2>/dev/null || true)
    while IFS= read -r node; do
        [[ -z "$node" ]] && continue
        local node_count
        node_count=$(echo "$response" | jq --arg n "$node" '[.libraries[] | select(.origin_node == $n)] | length' 2>/dev/null || echo 0)
        if [[ "$node_count" -eq 0 ]]; then
            printf "  [WARN] %-20s worker '%s' has 0 libraries in catalog\n" "library-custody" "$node"
            warn=$((warn + 1))
        fi
    done <<< "$worker_nodes"

    return 0
}

# ── Full check: per-service API readiness probe ───────────────────────────────
# Runs the service's health_check.command inside the container to confirm
# the application layer is responding (not just the port).
# Only runs for active+healthy services with a real command (not /dev/tcp or null).

_api_probe() {
    local svc="$1"
    local cmd
    cmd=$(jq -r --arg s "$svc" \
        '.services[$s].health_check.command // empty' "$CONFIG_FILE" 2>/dev/null || true)

    # Skip: no command, null, or a /dev/tcp port-only check
    [[ -z "$cmd" || "$cmd" == "null" ]] && return 0
    [[ "$cmd" == bash\ -c* ]] && return 0

    local state
    state=$(systemctl --user is-active "${svc}.service" 2>/dev/null || true)
    [[ "$state" != "active" ]] && return 0

    local rc=0
    podman exec "$svc" sh -c "$cmd" &>/dev/null || rc=$?
    if [[ $rc -eq 0 ]]; then
        printf "  [PASS] %-20s API ready\n" "$svc"
    else
        printf "  [FAIL] %-20s API probe failed (exit $rc): %s\n" "$svc" "$cmd"
    fi
    return $rc
}

# ── Main ──────────────────────────────────────────────────────────────────────

echo ""
echo "AI Stack Diagnostic  [profile: ${PROFILE}]"
echo "════════════════════════════════════════"
if [[ ${#TARGETS[@]} -gt 0 ]]; then
    echo "  Scope: ${TARGETS[*]}"
else
    echo "  Scope: all services (dependency order)"
fi
if $FIX; then
    echo "  Mode:  --fix  (will attempt restarts on failure)"
else
    echo "  Mode:  report only  (pass --fix to auto-restart)"
fi
echo ""

pass=0; warn=0; fail=0; skip=0; fixd=0

# ── Quick: network existence ──────────────────────────────────────────────────

net_ok=true
_check_network || { net_ok=false; fail=$((fail + 1)); }

# ── Quick: per-service checks ─────────────────────────────────────────────────

echo ""
echo "  Services"
for svc in "${ordered[@]}"; do
    _RESULT=""
    _diagnose "$svc"
    svc_result[$svc]="${_RESULT:-FAIL}"
    case "${_RESULT:-FAIL}" in
        PASS) pass=$((pass + 1)) ;;
        WARN) warn=$((warn + 1)) ;;
        SKIP) skip=$((skip + 1)) ;;
        FIXD) fixd=$((fixd + 1)) ;;
        FAIL) fail=$((fail + 1)) ;;
    esac
done

# ── Quick: model availability ─────────────────────────────────────────────────

model_ok=true
_check_models || { model_ok=false; warn=$((warn + 1)); }

# ── Full profile additions ────────────────────────────────────────────────────

if [[ "$PROFILE" == "full" ]]; then

    # Integration probes (cross-service auth/config)
    integ_fail=0
    _check_integrations || integ_fail=$?
    fail=$((fail + integ_fail))

    # GPU / CDI state
    gpu_fail=0
    _check_gpu || gpu_fail=$?
    fail=$((fail + gpu_fail))

    # Config validation
    _check_config_validate || fail=$((fail + 1))

    # Secrets presence
    secrets_fail=0
    _check_secrets || secrets_fail=$?
    fail=$((fail + secrets_fail))

    # Volume paths
    vols_fail=0
    _check_volumes || vols_fail=$?
    warn=$((warn + vols_fail))

    # Resource pressure
    pressure_fail=0
    _check_resource_pressure || pressure_fail=$?
    warn=$((warn + pressure_fail))

    # API readiness probes
    echo ""
    echo "  API Readiness Probes"
    for svc in "${ordered[@]}"; do
        local_state=$(systemctl --user is-active "${svc}.service" 2>/dev/null || true)
        [[ "$local_state" != "active" ]] && continue
        _is_gpu_gated "$svc" && continue
        probe_rc=0
        _api_probe "$svc" || probe_rc=$?
        [[ $probe_rc -ne 0 ]] && fail=$((fail + 1))
    done

    # Library custody status (controller only)
    custody_fail=0
    _check_library_custody || custody_fail=$?
    fail=$((fail + custody_fail))
fi

echo ""
echo "════════════════════════════════════════"
printf "  Pass: %-3d  Warn: %-3d  Fail: %-3d  Skip: %-3d" "$pass" "$warn" "$fail" "$skip"
$FIX && printf "  Fixed: %d" "$fixd"
echo ""
echo ""

if [[ $fail -gt 0 ]]; then
    echo "  ${fail} check(s) need attention."
    $FIX || echo "  Run with --fix to attempt automatic restarts."
    exit 1
elif [[ $warn -gt 0 ]]; then
    echo "  Warning(s) detected. Review items above."
    exit 1
else
    echo "  All services nominal."
    exit 0
fi

