#!/usr/bin/env bash
# scripts/diagnose.sh — Per-service diagnostic walkthrough for the AI stack
#
# Profiles:
#   quick (default) — systemd state, container health, network existence,
#                     dependency reachability, model availability
#   full            — quick + secrets, config validation, volume paths,
#                     resource pressure, API readiness  [TODO]
#
# Exit codes:
#   0  All checked services pass or are intentionally skipped
#   1  One or more services have warnings or failures
#   2  Stack not deployed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"
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

  full  [TODO — not yet implemented]
    - Everything in quick, plus:
    - Secrets presence and completeness
    - Config validation (configure.sh validate)
    - Volume / data path existence and permissions
    - Container resource pressure (memory near limit)
    - Per-service API readiness probes

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
  diagnose.sh --profile full         # full check (once implemented)
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

if [[ "$PROFILE" == "full" ]]; then
    echo "ERROR: --profile full is not yet implemented (TODO)." >&2
    exit 1
fi
if [[ "$PROFILE" != "quick" ]]; then
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

# ── Quick check: ollama model availability ────────────────────────────────────

_check_models() {
    echo ""
    echo "  Model Availability"
    local ollama_state
    ollama_state=$(systemctl --user is-active "ollama.service" 2>/dev/null || true)

    if [[ "$ollama_state" != "active" ]]; then
        printf "  [SKIP] %-20s ollama not running\n" "ollama/models"
        return 0
    fi

    local model_list
    model_list=$(podman exec ollama ollama list 2>/dev/null | tail -n +2 | awk '{print $1}' || true)

    if [[ -z "$model_list" ]]; then
        printf "  [WARN] %-20s no models loaded — run: ./scripts/pull-models.sh\n" "ollama/models"
        return 1
    fi

    local count
    count=$(echo "$model_list" | wc -l)
    printf "  [PASS] %-20s %d model(s): %s\n" "ollama/models" "$count" \
        "$(echo "$model_list" | tr '\n' ' ' | sed 's/ $//')"
    return 0
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

echo ""
echo "════════════════════════════════════════"
printf "  Pass: %-3d  Warn: %-3d  Fail: %-3d  Skip: %-3d" "$pass" "$warn" "$fail" "$skip"
$FIX && printf "  Fixed: %d" "$fixd"
echo ""
echo ""

if [[ $fail -gt 0 ]]; then
    echo "  ${fail} service(s) need attention."
    $FIX || echo "  Run with --fix to attempt automatic restarts."
    exit 1
elif [[ $warn -gt 0 ]]; then
    echo "  Health checks still initialising. Re-run in ~60s."
    exit 1
else
    echo "  All services nominal."
    exit 0
fi
