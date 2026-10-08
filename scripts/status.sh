#!/usr/bin/env bash
# scripts/status.sh — AI Stack health status
#
# Exit codes:
#   0  All services active
#   1  Deployed but one or more services not active (degraded/stopped/failed)
#   2  Not deployed (no quadlet .container files found in QUADLET_DIR)

# macOS ships bash 3.2; this script requires bash 4+ (mapfile, declare -A).
# Re-exec automatically with a newer bash if one is available.
if [[ "${BASH_VERSINFO[0]}" -lt 4 ]]; then
    for _b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
        if [[ -x "$_b" ]] && [[ "$("$_b" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]]; then
            exec "$_b" "$0" "$@"
        fi
    done
    echo "ERROR: bash 4+ required (found $BASH_VERSION)." >&2
    echo "  Install: brew install bash" >&2
    exit 1
fi

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
# Runtime config lives with the deployed instance ($AI_STACK_DIR), not the repo checkout —
# this is git-ignored and never touched by `git pull`/`checkout`/`stash` on the repo.
# See configs/config.json.example for the tracked bootstrap template (used by `init`).
CONFIG_FILE="${CONFIG_FILE:-$AI_STACK_DIR/configs/config.json}"
NODE_PROFILE_FILE="${NODE_PROFILE_FILE:-$PROJECT_ROOT/configs/node_profile}"
QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"

_get_node_profile() {
    if [[ -f "$NODE_PROFILE_FILE" ]]; then
        local p; p=$(tr -d '[:space:]' < "$NODE_PROFILE_FILE")
        [[ -n "$p" ]] && { echo "$p"; return; }
    fi
    jq -r '.node_profile // "controller"' "$CONFIG_FILE" 2>/dev/null || echo "controller"
}

QUIET=false
CHECK_ONLY=false
VERBOSE=0  # 0=default, 1=-v (add PORT column), 2=-vv (add PORT + URL columns)

usage() {
    cat <<'EOF'
Usage: status.sh [options]

Purpose:
  Show the health and running state of all AI stack services.
  Used by start.sh, stop.sh, and undeploy.sh to detect deployment state.

Options:
  --quiet       Suppress all output; rely on exit code only
  --check       Only check if stack is deployed (skips service state queries)
  -v            Add PORT column (expected host port from config.json), and
                in the top stanza: an "ollama tuning" summary showing the live
                NUM_PARALLEL/MAX_LOADED_MODELS/KEEP_ALIVE/CONTEXT_LENGTH/
                KV_CACHE_TYPE settings, plus an "ollama loaded models" list of
                every currently-resident model with ACTIVE/MAX request slots
                -- MAX is that model's own -np ceiling (can differ per model
                even under one global setting, e.g. qwen3.8's D-051 cap of 1)
                and ACTIVE is the true, instantaneous in-flight count queried
                live from that model's own llama-server /slots endpoint, not
                inferred (see docs/decisions.md D-049/D-051). CONTEXT also
                shows that model's real total KV-cache memory in GiB -- its
                own architecture/KV_CACHE_TYPE, same formula as the D-047
                ceiling check, times its *actual* total allocated context
                (per-slot context_length * -np slots)
  -vv           Add a URL column (replaces PORT; full http://localhost:PORT
                URL) plus a CPU PRESSURE column -- each service's own
                cgroup PSI "some avg10/avg60/avg300" (% of time something in
                that service wanted CPU and had to wait; the nearest real
                per-service multi-window load metric the kernel tracks
                natively, not a literal load1/5/15). Also adds, after the
                Summary line, an "Under Load:" tag (idle/light/moderate/
                heavy/struggling) folding together host-wide CPU load (vs.
                physical core count), memory %, GPU utilization (if an
                NVIDIA GPU is present), and network utilization (busiest
                real-link-speed interface) -- the worst of these, not an
                average, since one saturated resource is a bottleneck
                regardless of the others' headroom. Same ollama tuning /
                loaded-models summary as -v.
  -h, --help    Show this message

Exit codes:
  0   All services active
  1   Deployed but one or more services not active (degraded/stopped/failed)
  2   Not deployed (no quadlet files found in QUADLET_DIR)

Environment:
  CONFIG_FILE   Path to config.json  (default: $AI_STACK_DIR/configs/config.json)
  QUADLET_DIR   Quadlet directory    (default: ~/.config/containers/systemd)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --quiet)  QUIET=true ;;
        --check)  CHECK_ONLY=true ;;
        -vv)      VERBOSE=2 ;;
        -v)       VERBOSE=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 3 ;;
    esac
    shift
done

# ── Service state helpers ────────────────────────────────────────────────────
# Returns: active | inactive | failed | unknown
# Uses systemctl when a quadlet file exists; falls back to HTTP probe otherwise.
_svc_state() {
    local svc="$1"
    # On Darwin, systemd quadlets cannot run — always use HTTP probe regardless
    # of whether stale .container files are present.
    if [[ "$(uname -s)" != "Darwin" && -f "$QUADLET_DIR/${svc}.container" ]]; then
        local s; s=$(systemctl --user is-active "${svc}.service" 2>/dev/null || true)
        echo "${s:-unknown}"
    else
        local port path
        case "$svc" in
            ollama)          port=11434; path="" ;;
            promtail)        port=9080;  path="/metrics" ;; # /ready → 500 when scrape_configs is empty
            qdrant)          port=6333;  path="/healthz" ;;
            *)               echo "unknown"; return ;;
        esac
        if curl -sf --max-time 2 "http://localhost:${port}${path}" >/dev/null 2>&1; then
            echo "active"
        else
            echo "inactive"
        fi
    fi
}

# Returns the host-side port for a service from config.json, or empty if none.
_svc_port() {
    local svc="$1"
    jq -r --arg s "$svc" '.services[$s].ports[0].host // empty' "$CONFIG_FILE" 2>/dev/null
}

# Returns the user-facing URL for a service.
# Traefik-routed services get their *.stack.localhost hostname.
# Direct-access services get http://localhost:PORT.
_svc_url() {
    local svc="$1"
    case "$svc" in
        openwebui)       echo "https://openwebui.stack.localhost" ;;
        grafana)         echo "https://grafana.stack.localhost" ;;
        flowise)         echo "https://flowise.stack.localhost" ;;
        prometheus)      echo "https://prometheus.stack.localhost" ;;
        litellm)         echo "https://litellm.stack.localhost" ;;
        qdrant)          echo "https://qdrant.stack.localhost" ;;
        minio)           echo "https://minio.stack.localhost" ;;
        homepage)        echo "https://dashboard.stack.localhost" ;;
        traefik)         echo "http://localhost:8080" ;;
        postgres)        echo "localhost:5432" ;;
        ollama)          echo "http://localhost:11434" ;;
        *)               echo "-" ;;
    esac
}

# Returns the display category for a service — groups status.sh output into
# logical sections so it's clear at a glance what each service is *for*.
# Mirrors the taxonomy already used in CENTAURI-playbook.md §2.2 (Service Inventory)
# so the same mental model applies across docs and tooling.
_svc_category() {
    local svc="$1"
    case "$svc" in
        openwebui|flowise|homepage)       echo "Applications" ;;
        traefik)                          echo "Edge & Routing" ;;
        litellm|ollama|vllm)              echo "Model Serving" ;;
        postgres|qdrant|minio)            echo "Storage & Data" ;;
        grafana|prometheus|loki|promtail) echo "Observability & Metrics" ;;
        *)                                echo "Other" ;;
    esac
}

# Display order for categories follows a request's actual path through the
# stack: in through the edge, into the user-facing apps, out to model serving,
# out again to RAG/knowledge, down to the storage everything ultimately reads
# and writes. Observability sits last — it watches the other five, but isn't
# itself a hop a normal request passes through.
# Empty categories (no services in scope for this node profile) are skipped
# automatically at print time.
CATEGORY_ORDER=("Edge & Routing" "Applications" "Model Serving" "Knowledge / RAG" "Storage & Data" "Observability & Metrics" "Other")

# Returns a service's CPU PSI (Pressure Stall Information) -- "some avg10/
# avg60/avg300" from its own systemd-managed cgroup, as "avg10|avg60|avg300".
# This is the closest real per-service multi-window load metric the kernel
# tracks natively (cgroup v2, CONFIG_PSI), continuously, with no extra
# sampling infrastructure needed on our part. Its windows are 10s/60s/300s
# -- not the traditional 1/5/15-minute loadavg windows, which the kernel
# does not track per-cgroup (there is no persistent avg900) -- so this is
# the nearest available equivalent, not a literal load1/5/15.
# PSI's "some" value is the % of time *something* in the cgroup wanted CPU
# and had to wait (contention), not raw CPU utilization -- arguably a more
# direct "is this service struggling" signal than %CPU would be.
# Empty on Darwin, bare-metal services, or any service whose cgroup can't
# be resolved (inactive, or no quadlet unit for it).
_svc_cpu_pressure() {
    local svc="$1"
    [[ "$(uname -s)" == "Darwin" ]] && return 0
    local cg
    cg=$(systemctl --user show -p ControlGroup "${svc}.service" 2>/dev/null | cut -d= -f2-)
    [[ -z "$cg" ]] && return 0
    local psi_file="/sys/fs/cgroup${cg}/cpu.pressure"
    [[ -r "$psi_file" ]] || return 0
    awk '
        /^some/ {
            for (i = 1; i <= NF; i++) {
                split($i, a, "=")
                if (a[1] == "avg10")  a10  = a[2]
                if (a[1] == "avg60")  a60  = a[2]
                if (a[1] == "avg300") a300 = a[2]
            }
            print a10 "|" a60 "|" a300
        }
    ' "$psi_file" 2>/dev/null
}

# Returns container health (only for quadlet-managed active containers)
_svc_health() {
    local svc="$1" state="$2"
    if [[ "$state" == "active" && -f "$QUADLET_DIR/${svc}.container" ]]; then
        podman inspect --format '{{.State.Health.Status}}' "$svc" 2>/dev/null || true
    fi
}

# Returns the live Ollama tuning parameters under active testing/tracked in
# docs/decisions.md (D-049/D-050/D-051): NUM_PARALLEL, MAX_LOADED_MODELS,
# KEEP_ALIVE, CONTEXT_LENGTH, KV_CACHE_TYPE. One "key=value" pair per line.
# Prefers the live running container's actual environment (reflects reality,
# catches any drift from config.json); falls back to config.json's configured
# values, clearly marked, if the container isn't reachable.
_ollama_tuning() {
    local keys=(OLLAMA_NUM_PARALLEL OLLAMA_MAX_LOADED_MODELS OLLAMA_KEEP_ALIVE OLLAMA_CONTEXT_LENGTH OLLAMA_KV_CACHE_TYPE)
    local live=""
    if command -v podman &>/dev/null; then
        live=$(podman exec ollama env 2>/dev/null | grep '^OLLAMA_' || true)
    fi
    if [[ -n "$live" ]]; then
        local k v
        for k in "${keys[@]}"; do
            v=$(grep "^${k}=" <<< "$live" | cut -d= -f2-)
            echo "${k}=${v:-unset}|live"
        done
    else
        local k v
        for k in "${keys[@]}"; do
            v=$(jq -r --arg k "$k" '.services.ollama.environment[$k] // empty' "$CONFIG_FILE" 2>/dev/null)
            echo "${k}=${v:-unset}|configured"
        done
    fi
}

# Performs a minimal raw HTTP GET over bash's /dev/tcp and prints only the
# response body -- the ollama container image ships neither curl nor wget,
# so this is the only way to reach a loaded model's own llama-server runner
# on its private, container-internal 127.0.0.1:<port> (not reachable from
# the host; confirmed by a direct curl attempt timing out).
# $1=host $2=port $3=path $4=podman|bare (where to run the raw request from)
_raw_http_get() {
    local host="$1" port="$2" path="$3" mode="$4" raw script
    script="exec 3<>/dev/tcp/${host}/${port} || exit 1
printf 'GET %s HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' '${path}' >&3
cat <&3"
    if [[ "$mode" == "podman" ]]; then
        raw=$(podman exec ollama bash -c "$script" 2>/dev/null || true)
    else
        raw=$(bash -c "$script" 2>/dev/null || true)
    fi
    awk 'body{print} /^\r?$/{body=1}' <<< "$raw"
}

# Bytes per KV cache element for a given --cache-type-k/-v value. Mirrors
# Ollama's own supported OLLAMA_KV_CACHE_TYPE values; unrecognized/unknown
# types fall back to f16 (2 bytes), the conservative direction (same
# fallback convention as pull-models.sh's D-047 ceiling check).
_kv_bytes_per_element() {
    case "$1" in
        q4_0) echo 0.5 ;;
        q8_0) echo 1 ;;
        f32)  echo 4 ;;
        *)    echo 2 ;;  # f16 or unknown
    esac
}

# Returns the actual total KV-cache memory (GiB) a loaded model's current
# launch has reserved. Same per-token-bytes formula as pull-models.sh's
# D-047 ceiling check (model's own /api/show: block_count, head_count_kv,
# key_length/embedding_length), but computing a real figure instead of a
# conservative ceiling: uses the KV_CACHE_TYPE actually baked into this
# model's own launch command (not assumed to be f16), and multiplies by the
# *total* allocated context -- per-slot context_length * -np slots, since
# Ollama reserves KV cache for every slot up front at load time, not just
# the one slot in use (confirmed directly: mistral's launch command showed
# "-c 65536 -np 4" for a configured 16384 context_length -- 16384*4=65536).
# $1=model name  $2=per-slot context_length  $3=np slots  $4=cache_type
# Prints "?" if the model's architecture fields aren't present or inputs
# are unresolved.
_model_kv_gib() {
    local name="$1" ctx="$2" np="$3" cache_type="$4"
    if [[ "$ctx" == "?" || "$np" == "?" || -z "$ctx" || -z "$np" ]]; then
        echo "?"; return
    fi

    local show_json
    show_json=$(curl -sf --max-time 3 http://localhost:11434/api/show \
        -d "$(jq -n --arg m "$name" '{model:$m}')" 2>/dev/null) || { echo "?"; return; }

    local bytes_per_elem; bytes_per_elem=$(_kv_bytes_per_element "$cache_type")

    jq -r --argjson ctx "$ctx" --argjson np "$np" --argjson bpe "$bytes_per_elem" '
      (.model_info // {}) as $mi |
      ($mi | to_entries | map(select(.key | endswith(".block_count"))) | .[0].value // null) as $block_count |
      ($mi | to_entries | map(select(.key | endswith(".attention.head_count_kv"))) | .[0].value // null) as $kv_heads_raw |
      ($mi | to_entries | map(select(.key | endswith(".attention.key_length"))) | .[0].value // null) as $key_length |
      ($mi | to_entries | map(select(.key | endswith(".attention.head_count"))) | .[0].value // null) as $head_count |
      ($mi | to_entries | map(select(.key | endswith(".embedding_length"))) | .[0].value // null) as $embedding_length |
      (if $key_length != null then $key_length
       elif ($head_count != null and $embedding_length != null and $head_count > 0) then ($embedding_length / $head_count)
       else null end) as $head_dim |
      (if ($kv_heads_raw | type) == "array" then ($kv_heads_raw | add)
       elif ($kv_heads_raw != null and $block_count != null) then ($kv_heads_raw * $block_count)
       else null end) as $total_kv_head_layers |
      if ($total_kv_head_layers == null or $head_dim == null or $total_kv_head_layers == 0 or $head_dim == 0) then "?"
      else
        (2 * $total_kv_head_layers * $head_dim * $bpe) as $bytes_per_token |
        (($bytes_per_token * $ctx * $np) / 1073741824)
      end
    ' <<< "$show_json" 2>/dev/null | { read -r _g; [[ "$_g" == "?" || -z "$_g" ]] && echo "?" || printf '%.2f\n' "$_g"; }
}

# Returns every currently-resident (loaded-in-memory) Ollama model together
# with its real-time active request count and its max parallel-slot count
# (-np). The max is read straight out of the live llama-server launch
# command; NUM_PARALLEL is baked in at each model's own load time (D-049),
# so different resident models can have different ceilings under the same
# global setting -- e.g. qwen3.8's static MTP classification forces -np 1
# regardless (D-051). The *active* count is the true instantaneous instance
# count: queried live from that runner's own /slots endpoint (llama.cpp's
# own concurrency scheduler -- each slot reports is_processing true/false),
# not inferred or assumed from the max.
#
# A runner subprocess is matched to its /api/ps entry by weights-blob digest,
# resolved from Ollama's own manifest file on disk: /api/ps's own "digest"
# field is the *manifest's* digest, a different hash that never matches the
# blob path a runner is invoked with (first worked out in scripts/loads.sh).
#
# Also computes the real total KV-cache memory that model's launch has
# reserved (see _model_kv_gib above) -- the max expected memory a context of
# that size takes up for this specific model's architecture and KV_CACHE_TYPE.
#
# Takes the already-fetched /api/ps JSON as $1. One "name|active|max|ctx|kv_gib"
# line per resident model; any field is "?" if it couldn't be resolved.
_ollama_loaded_models() {
    local ps_json="$1"
    local names
    mapfile -t names < <(jq -r '.models[]?.name // empty' <<< "$ps_json" 2>/dev/null)
    [[ ${#names[@]} -eq 0 ]] && return 0

    local in_podman=false
    if command -v podman &>/dev/null && podman inspect ollama &>/dev/null 2>&1; then
        in_podman=true
    fi

    local procs=""
    if $in_podman; then
        procs=$(podman exec ollama ps aux 2>/dev/null | grep 'llama-server' || true)
    else
        procs=$(ps aux 2>/dev/null | grep 'llama-server' | grep -v grep || true)
    fi

    local models_dir=""
    if ! $in_podman; then
        for _c in "${OLLAMA_MODELS:-}" "$AI_STACK_DIR/ollama/models" "$HOME/.ollama/models"; do
            [[ -n "$_c" && -d "$_c" ]] && { models_dir="$_c"; break; }
        done
    fi

    local name base_part namespace model tag manifest_path manifest_json digest np ctx line port
    local slots_json active cache_type kv_gib
    for name in "${names[@]}"; do
        ctx=$(jq -r --arg n "$name" '.models[] | select(.name==$n) | .context_length // empty' <<< "$ps_json" 2>/dev/null)

        base_part="${name%%:*}"
        tag="${name#*:}"
        [[ "$tag" == "$name" ]] && tag="latest"
        if [[ "$base_part" == */* ]]; then
            namespace="${base_part%%/*}"
            model="${base_part#*/}"
        else
            namespace="library"
            model="$base_part"
        fi
        manifest_path="manifests/registry.ollama.ai/${namespace}/${model}/${tag}"

        manifest_json=""
        if $in_podman; then
            manifest_json=$(podman exec ollama cat "/root/.ollama/models/${manifest_path}" 2>/dev/null || true)
        elif [[ -n "$models_dir" ]]; then
            manifest_json=$(cat "${models_dir}/${manifest_path}" 2>/dev/null || true)
        fi

        digest=""
        if [[ -n "$manifest_json" ]]; then
            digest=$(jq -r '.layers[]? | select(.mediaType=="application/vnd.ollama.image.model") | .digest' \
                <<< "$manifest_json" 2>/dev/null | sed 's/^sha256://')
        fi

        np="?"
        port=""
        cache_type="f16"
        if [[ -n "$digest" && -n "$procs" ]]; then
            line=$(grep -- "sha256-${digest}" <<< "$procs" | head -1 || true)
            if [[ -n "$line" ]]; then
                np=$(awk '{for(i=1;i<=NF;i++) if($i=="-np"){print $(i+1); exit}}' <<< "$line")
                [[ -z "$np" ]] && np="?"
                port=$(awk '{for(i=1;i<=NF;i++) if($i=="--port"){print $(i+1); exit}}' <<< "$line")
                cache_type=$(awk '{for(i=1;i<=NF;i++) if($i=="--cache-type-k"){print $(i+1); exit}}' <<< "$line")
                [[ -z "$cache_type" ]] && cache_type="f16"
            fi
        fi

        active="?"
        if [[ -n "$port" ]]; then
            if $in_podman; then
                slots_json=$(_raw_http_get "127.0.0.1" "$port" "/slots" "podman")
            else
                slots_json=$(_raw_http_get "127.0.0.1" "$port" "/slots" "bare")
            fi
            if [[ -n "$slots_json" ]]; then
                active=$(jq '[.[] | select(.is_processing==true)] | length' <<< "$slots_json" 2>/dev/null)
                [[ -z "$active" ]] && active="?"
            fi
        fi
        kv_gib=$(_model_kv_gib "$name" "${ctx:-?}" "$np" "$cache_type")
        echo "${name}|${active}|${np}|${ctx:-?}|${kv_gib:-?}"
    done
}

# Returns a one-line tailnet connectivity summary using tailscale status --json.
# Shows BackendState, this node's tailnet IP, and online-peer count.
_tailnet_status() {
    if ! command -v tailscale &>/dev/null; then
        echo "not installed"
        return 0
    fi
    local ts_json
    ts_json=$(tailscale status --json 2>/dev/null || true)
    if [[ -z "$ts_json" ]]; then
        echo "unavailable (tailscaled not running?)"
        return 0
    fi
    local backend self_ip online_peers total_peers
    backend=$(jq -r '.BackendState // "unknown"' <<< "$ts_json")
    self_ip=$(jq -r '(.Self.TailscaleIPs // ["?"])[0]' <<< "$ts_json")
    online_peers=$(jq '[.Peer // {} | to_entries[] | select(.value.Online == true)] | length' <<< "$ts_json")
    total_peers=$(jq '[.Peer // {} | keys[]] | length' <<< "$ts_json")
    if [[ "$backend" == "Running" ]]; then
        echo "connected  ${online_peers}/${total_peers} peers online  (${self_ip})"
    else
        echo "${backend}  (${self_ip})"
    fi
}

# Buckets a numeric value against four ascending thresholds into a
# five-level qualitative scale. $1=value $2..$5=light/moderate/heavy/
# struggling cutoffs (below $2 is "idle").
_classify_level() {
    awk -v v="$1" -v t1="$2" -v t2="$3" -v t3="$4" -v t4="$5" 'BEGIN{
        if (v < t1)      print "idle";
        else if (v < t2) print "light";
        else if (v < t3) print "moderate";
        else if (v < t4) print "heavy";
        else             print "struggling";
    }'
}

# Returns this host's physical (non-hyperthread) core count, falling back
# to the logical count (nproc) if lscpu's fields aren't parseable. Matters
# because llama.cpp defaults its own thread count to the physical core
# count, not logical (see docs/governance/lessons-learned.md, 2026-10-06) --
# a load1 figure only makes sense measured against the count the workload
# actually schedules against.
_physical_cores() {
    local per_socket sockets phys
    per_socket=$(lscpu 2>/dev/null | awk -F: '/^Core\(s\) per socket/{gsub(/ /,"",$2); print $2}')
    sockets=$(lscpu 2>/dev/null | awk -F: '/^Socket\(s\)/{gsub(/ /,"",$2); print $2}')
    if [[ -n "$per_socket" && -n "$sockets" ]]; then
        phys=$((per_socket * sockets))
    fi
    if [[ -z "$phys" || "$phys" -le 0 ]]; then
        phys=$(nproc 2>/dev/null || echo 1)
    fi
    echo "$phys"
}

# Returns "gpu_util_pct|mem_used_mib|mem_total_mib" for GPU 0, or empty if
# no NVIDIA GPU/driver is present (this fleet is CPU-inference-only today,
# but the controller host does have a GPU available for other uses).
_gpu_status() {
    command -v nvidia-smi &>/dev/null || return 0
    nvidia-smi --query-gpu=utilization.gpu,memory.used,memory.total \
        --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -d ' ' | tr ',' '|'
}

# Auto-picks the busiest network interface that has a known physical link
# speed (excludes loopback and container/VPN virtual interfaces, which
# report no fixed speed), samples its rx/tx byte counters 1s apart, and
# returns "pct_of_link|iface|rx_mbps|tx_mbps". Empty if no such interface
# exists (e.g. only virtual interfaces up). The 1s sample is deliberate --
# only run at -vv, the already-heaviest/most-diagnostic verbosity tier.
_net_util() {
    local iface="" best_bytes=0 name speed bytes
    while read -r name _; do
        name="${name%:}"
        case "$name" in lo|veth*|cni*|podman*|docker*|br-*|tailscale*) continue ;; esac
        speed=$(cat "/sys/class/net/${name}/speed" 2>/dev/null)
        [[ -z "$speed" ]] && continue
        (( speed <= 0 )) 2>/dev/null && continue
        bytes=$(awk -v n="${name}:" '$1 == n {print $2 + $10}' /proc/net/dev 2>/dev/null)
        [[ -z "$bytes" ]] && continue
        if (( bytes > best_bytes )); then
            best_bytes=$bytes
            iface="$name"
        fi
    done < <(awk -F: 'NR>2{print $1}' /proc/net/dev)
    [[ -z "$iface" ]] && return 0

    local speed_mbit rx1 tx1 rx2 tx2
    speed_mbit=$(cat "/sys/class/net/${iface}/speed" 2>/dev/null)
    read -r rx1 tx1 <<< "$(awk -v n="${iface}:" '$1 == n {print $2, $10}' /proc/net/dev)"
    sleep 1
    read -r rx2 tx2 <<< "$(awk -v n="${iface}:" '$1 == n {print $2, $10}' /proc/net/dev)"

    awk -v rx1="$rx1" -v rx2="$rx2" -v tx1="$tx1" -v tx2="$tx2" -v s="$speed_mbit" -v iface="$iface" 'BEGIN{
        rx_mbps = (rx2-rx1)*8/1000000
        tx_mbps = (tx2-tx1)*8/1000000
        peak = (rx_mbps > tx_mbps) ? rx_mbps : tx_mbps
        pct = (s > 0) ? (peak/s*100) : 0
        printf "%.1f|%s|%.2f|%.2f\n", pct, iface, rx_mbps, tx_mbps
    }'
}

# Composite "Under Load:" read on the whole host, folding together CPU
# (load1 vs. physical core count), memory (% used), GPU utilization (if an
# NVIDIA GPU is present), and network utilization (if a real link-speed
# interface is active) into one idle/light/moderate/heavy/struggling tag.
# The overall tag is the WORST (highest-severity) of whichever dimensions
# could be computed, not an average -- one saturated resource is a real
# bottleneck regardless of the others having headroom. Thresholds are a
# judgment call (documented inline below), not a precise SLO; the raw
# figures are always printed alongside the tag so they can be re-judged.
_system_under_load() {
    local load1 load5 load15 phys cpu_ratio cpu_level
    read -r load1 load5 load15 _ < /proc/loadavg
    phys=$(_physical_cores)
    cpu_ratio=$(awk -v l="$load1" -v p="$phys" 'BEGIN{printf "%.2f", (p>0)? l/p : 0}')
    cpu_level=$(_classify_level "$cpu_ratio" 0.3 0.7 1.2 2.0)

    local mem_total mem_used mem_pct mem_level
    read -r mem_total mem_used <<< "$(free -m | awk '/^Mem:/{print $2, $3}')"
    mem_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN{printf "%.1f", (t>0)? u/t*100 : 0}')
    mem_level=$(_classify_level "$mem_pct" 30 50 75 90)

    local gpu_raw gpu_util gpu_mem_used gpu_mem_total gpu_level="" gpu_note=""
    gpu_raw=$(_gpu_status)
    if [[ -n "$gpu_raw" ]]; then
        IFS='|' read -r gpu_util gpu_mem_used gpu_mem_total <<< "$gpu_raw"
        gpu_level=$(_classify_level "$gpu_util" 10 30 60 85)
        gpu_note=", gpu ${gpu_util}% (${gpu_mem_used}/${gpu_mem_total}MiB) [${gpu_level}]"
    fi

    local net_raw net_pct net_iface net_level="" net_note=""
    net_raw=$(_net_util)
    if [[ -n "$net_raw" ]]; then
        IFS='|' read -r net_pct net_iface _ _ <<< "$net_raw"
        net_level=$(_classify_level "$net_pct" 5 20 50 80)
        net_note=", net ${net_pct}% of ${net_iface} link [${net_level}]"
    fi

    local -A rank=([idle]=0 [light]=1 [moderate]=2 [heavy]=3 [struggling]=4)
    local overall="idle" overall_rank=0 lvl r
    for lvl in "$cpu_level" "$mem_level" "$gpu_level" "$net_level"; do
        [[ -z "$lvl" ]] && continue
        r=${rank[$lvl]}
        if (( r > overall_rank )); then overall_rank=$r; overall="$lvl"; fi
    done

    printf "%s  (cpu load %s/%s/%s, %sc [%s], mem %s%% [%s]%s%s)\n" \
        "${overall^^}" "$load1" "$load5" "$load15" "$phys" "$cpu_level" \
        "$mem_pct" "$mem_level" "$gpu_note" "$net_note"
}

# ── Deployment check ──────────────────────────────────────────────────────────

quadlet_count=0
if [[ -d "$QUADLET_DIR" ]]; then
    quadlet_count=$(find "$QUADLET_DIR" -maxdepth 1 -name "*.container" 2>/dev/null | wc -l)
fi

# Bare-metal nodes have no quadlets but ollama runs natively
if [[ $quadlet_count -eq 0 ]] && ! command -v ollama &>/dev/null; then
    if ! $QUIET; then
        echo "Stack is NOT DEPLOYED (no quadlet files found in $QUADLET_DIR, no bare-metal ollama found)"
        echo "Run: bash scripts/deploy.sh"
    fi
    exit 2
fi

# If caller only wanted a deployment check, we're done
$CHECK_ONLY && exit 0

# ── Prerequisites ─────────────────────────────────────────────────────────────

if ! command -v jq &>/dev/null; then
    echo "ERROR: jq is required." >&2
    exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: Config not found at $CONFIG_FILE" >&2
    exit 1
fi

# ── Gather service states ─────────────────────────────────────────────────────

net_name=$(jq -r '.network.name' "$CONFIG_FILE")

# Filter services to those expected for this node profile
case "$(_get_node_profile)" in
    inference-worker)          _profile_svcs='["ollama","promtail"]' ;;
    enhanced-worker|knowledge-worker)  _profile_svcs='["ollama","promtail","qdrant"]' ;;
    *)                         _profile_svcs='null' ;;  # controller/peer: all services
esac

if [[ "$_profile_svcs" == "null" ]]; then
    mapfile -t services < <(jq -r '.services | keys[]' "$CONFIG_FILE")
else
    mapfile -t services < <(jq -r --argjson svcs "$_profile_svcs" \
        '.services | keys[] | select(. as $k | $svcs | index($k) != null)' "$CONFIG_FILE")
fi

if [[ ${#services[@]} -eq 0 ]]; then
    echo "ERROR: No services found in $CONFIG_FILE" >&2
    echo "  jq -r '.services | keys[]' returned nothing." >&2
    echo "  Verify that CONFIG_FILE points to the correct config and that .services is non-empty." >&2
    echo "  CONFIG_FILE=$CONFIG_FILE" >&2
    exit 1
fi

# Determine deploy mode: Darwin cannot run systemd quadlets — always bare metal.
# On Linux, check per-service quadlet files to detect podman vs bare-metal vs mixed.
_quadlet_svc_count=0
_bare_svc_count=0
if [[ "$(uname -s)" != "Darwin" ]]; then
    for svc in "${services[@]}"; do
        if [[ -f "$QUADLET_DIR/${svc}.container" ]]; then
            _quadlet_svc_count=$((_quadlet_svc_count + 1))
        else
            _bare_svc_count=$((_bare_svc_count + 1))
        fi
    done
fi
if [[ $_quadlet_svc_count -gt 0 && $_bare_svc_count -gt 0 ]]; then
    _deploy_mode="mixed (podman + bare metal)"
elif [[ $_quadlet_svc_count -gt 0 ]]; then
    _deploy_mode="podman (quadlets)"
else
    _deploy_mode="bare metal"
fi

total=${#services[@]}
active=0
failed_count=0
unhealthy_count=0

declare -A svc_states=()
declare -A svc_health=()
for svc in "${services[@]}"; do
    state=$(_svc_state "$svc")
    svc_states[$svc]="$state"
    [[ "$state" == "active"  ]] && active=$((active + 1))
    [[ "$state" == "failed"  ]] && failed_count=$((failed_count + 1))

    health=$(_svc_health "$svc" "$state")
    svc_health[$svc]="$health"
    [[ "$health" == "unhealthy" ]] && unhealthy_count=$((unhealthy_count + 1))
done

# ── Print table ───────────────────────────────────────────────────────────────

if ! $QUIET; then
    # Column width = longest service name + 2
    max_len=7  # minimum width ("SERVICE")
    for svc in "${services[@]}"; do
        [[ ${#svc} -gt $max_len ]] && max_len=${#svc}
    done
    col=$((max_len + 2))

    echo ""
    echo "AI Stack Status"
    echo "════════════════════════════════════════"
    printf "  %-${col}s %s\n" "node profile" "$(_get_node_profile)"
    printf "  %-${col}s %s\n" "deploy mode" "$_deploy_mode"

    # Network and secrets — only relevant when podman is in use
    if [[ $_quadlet_svc_count -gt 0 ]]; then
        if podman network exists "$net_name" 2>/dev/null; then
            printf "  %-${col}s %s\n" "network/${net_name}" "exists"
        else
            printf "  %-${col}s %s\n" "network/${net_name}" "MISSING"
        fi

        # Secrets summary — scoped to profile services
        if [[ "$_profile_svcs" == "null" ]]; then
            mapfile -t all_secrets < <(jq -r \
                '[.services | to_entries[] | .value.secrets[]?.name] | unique[]' \
                "$CONFIG_FILE" 2>/dev/null || true)
        else
            mapfile -t all_secrets < <(jq -r --argjson svcs "$_profile_svcs" \
                '[.services | to_entries[] | select(.key as $k | $svcs | index($k) != null) | .value.secrets[]?.name] | unique[]' \
                "$CONFIG_FILE" 2>/dev/null || true)
        fi
        total_secrets=${#all_secrets[@]}
        present_secrets=0
        for secret in "${all_secrets[@]}"; do
            if podman secret inspect "$secret" &>/dev/null 2>&1; then
                present_secrets=$((present_secrets + 1))
            fi
        done
        printf "  %-${col}s %s\n" "secrets" "${present_secrets}/${total_secrets} present"
    fi

    # Tailnet connectivity (headscale)
    _ts_out=$(_tailnet_status 2>/dev/null || echo "unavailable")
    printf "  %-${col}s %s\n" "tailnet" "$_ts_out"

    # Ollama tuning parameters under active testing (D-049/D-050/D-051) — -v+
    # only, since this is diagnostic detail rather than default-glance status.
    if [[ $VERBOSE -ge 1 ]] && printf '%s\n' "${services[@]}" | grep -qx ollama; then
        echo ""
        printf "  %s\n" "ollama tuning (D-049)"
        while IFS='|' read -r _pair _source; do
            _tkey="${_pair%%=*}"
            _tval="${_pair#*=}"
            _tlabel="${_tkey#OLLAMA_}"
            _tlabel="${_tlabel,,}"
            if [[ "$_source" == "configured" ]]; then
                printf "    %-20s %s %s\n" "$_tlabel" "$_tval" "(configured, ollama not running to confirm)"
            else
                printf "    %-20s %s\n" "$_tlabel" "$_tval"
            fi
        done < <(_ollama_tuning)

        echo ""
        printf "  %s\n" "ollama loaded models"
        _ps_json=$(curl -sf --max-time 3 http://localhost:11434/api/ps 2>/dev/null || true)
        if [[ -z "$_ps_json" ]]; then
            printf "    %s\n" "(ollama unreachable)"
        else
            mapfile -t _loaded_lines < <(_ollama_loaded_models "$_ps_json")
            if [[ ${#_loaded_lines[@]} -eq 0 ]]; then
                printf "    %s\n" "(none resident)"
            else
                printf "    %-28s %-14s %s\n" "MODEL" "ACTIVE/MAX" "CONTEXT (KV mem)"
                for _lline in "${_loaded_lines[@]}"; do
                    IFS='|' read -r _lname _lactive _lnp _lctx _lkvgib <<< "$_lline"
                    if [[ "$_lkvgib" == "?" ]]; then
                        printf "    %-28s %-14s %s\n" "$_lname" "${_lactive}/${_lnp}" "$_lctx"
                    else
                        printf "    %-28s %-14s %s\n" "$_lname" "${_lactive}/${_lnp}" "${_lctx} (${_lkvgib}G)"
                    fi
                done
            fi
        fi
    fi

    echo ""
    # sep_width tracks the visual width of the separator line (excludes 4-space indent,
    # to match the nested service rows printed under each category below)
    sep_width=0
    if [[ $VERBOSE -ge 2 ]]; then
        sep_width=$((col + 68))
        printf "    %-${col}s %-10s %-12s %-36s %s\n" "SERVICE" "STATE" "HEALTH" "URL" "CPU PRESSURE (10s/60s/300s)"
    elif [[ $VERBOSE -eq 1 ]]; then
        sep_width=$((col + 32))
        printf "    %-${col}s %-10s %-12s %s\n" "SERVICE" "STATE" "HEALTH" "PORT"
    else
        sep_width=$((col + 22))
        printf "    %-${col}s %-10s %s\n" "SERVICE" "STATE" "HEALTH"
    fi
    printf "    %s\n" "$(printf '─%.0s' $(seq 1 $sep_width))"

    # Group services by category (§ CATEGORY_ORDER / _svc_category above) so it's
    # clear at a glance what each service is for, not just whether it's up.
    for cat in "${CATEGORY_ORDER[@]}"; do
        cat_svcs=()
        for svc in "${services[@]}"; do
            [[ "$(_svc_category "$svc")" == "$cat" ]] && cat_svcs+=("$svc")
        done
        [[ ${#cat_svcs[@]} -eq 0 ]] && continue

        printf "  %s\n" "$cat"
        for svc in "${cat_svcs[@]}"; do
            display="${svc_states[$svc]}"
            [[ "$display" == "inactive" ]] && display="stopped"
            health_display="${svc_health[$svc]:-}"
            [[ "$display" != "active" ]] && health_display="-"
            [[ -z "$health_display" ]] && health_display="-"
            if [[ $VERBOSE -ge 2 ]]; then
                _url_val=$(_svc_url "$svc")
                _psi_val=$(_svc_cpu_pressure "$svc")
                if [[ -n "$_psi_val" ]]; then
                    IFS='|' read -r _psi_10 _psi_60 _psi_300 <<< "$_psi_val"
                    _psi_display="${_psi_10}/${_psi_60}/${_psi_300}"
                else
                    _psi_display="-"
                fi
                printf "    %-${col}s %-10s %-12s %-36s %s\n" "$svc" "$display" "$health_display" "${_url_val:--}" "$_psi_display"
            elif [[ $VERBOSE -eq 1 ]]; then
                _port_val=$(_svc_port "$svc")
                printf "    %-${col}s %-10s %-12s %s\n" "$svc" "$display" "$health_display" "${_port_val:--}"
            else
                printf "    %-${col}s %-10s %s\n" "$svc" "$display" "$health_display"
            fi
        done
        echo ""
    done

    if [[ $active -eq $total && $unhealthy_count -eq 0 ]]; then
        echo "  Summary: ${active}/${total} active, all healthy  [OK]"
    elif [[ $failed_count -gt 0 ]]; then
        echo "  Summary: ${active}/${total} active, ${failed_count} failed, ${unhealthy_count} unhealthy  [FAILED]"
    elif [[ $unhealthy_count -gt 0 ]]; then
        echo "  Summary: ${active}/${total} active, ${unhealthy_count} unhealthy  [DEGRADED]"
    else
        echo "  Summary: ${active}/${total} active  [DEGRADED]"
    fi

    if [[ $VERBOSE -ge 2 ]]; then
        echo "  Under Load: $(_system_under_load)"
    fi
    echo ""
fi

# ── Exit code ─────────────────────────────────────────────────────────────────

if [[ $active -eq $total && $unhealthy_count -eq 0 ]]; then
    exit 0
else
    exit 1
fi
