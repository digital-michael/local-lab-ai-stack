#!/usr/bin/env bash
set -euo pipefail

# configure.sh — CRUD operations on AI Stack config.json
# Generates quadlet files and Podman secrets from configuration.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG_FILE="${CONFIG_FILE:-$PROJECT_ROOT/configs/config.json}"
QUADLET_DIR="${QUADLET_DIR:-$HOME/.config/containers/systemd}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

usage() {
    cat <<'EOF'
Usage: configure.sh <command> [args]

Commands:
  init                      Generate default config.json (if missing)
  get <json-path>           Read a value  (e.g. .services.postgres.tag)
  set <json-path> <value>   Update a value
  list-services             List all service names
  validate                  Check config completeness
  generate-quadlets         Produce systemd quadlet files from config
  generate-secrets          Prompt for and create Podman secrets
  generate-litellm-config   Regenerate configs/models.json from models[] in config.json
  detect-hardware           Detect GPU/VRAM/RAM and suggest node profile
  recommend                 Interactive node profile recommender (writes to config.json)
  help                      Show this message

Environment:
  CONFIG_FILE   Path to config.json  (default: ./configs/config.json)
  QUADLET_DIR   Output dir for quadlets (default: ~/.config/containers/systemd)
EOF
}

require_jq() {
    if ! command -v jq &>/dev/null; then
        echo "ERROR: jq is required. Install with: sudo dnf install -y jq" >&2
        exit 1
    fi
}

require_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "ERROR: Config file not found at $CONFIG_FILE" >&2
        echo "Run: configure.sh init" >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_init() {
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "Config already exists at $CONFIG_FILE"
        echo "To reset, remove it first."
        return 0
    fi
    mkdir -p "$(dirname "$CONFIG_FILE")"
    cp "$PROJECT_ROOT/configs/config.json" "$CONFIG_FILE" 2>/dev/null || {
        echo "ERROR: Default config template not found at $PROJECT_ROOT/configs/config.json" >&2
        exit 1
    }
    echo "Config initialized at $CONFIG_FILE"
}

cmd_get() {
    local path="${1:?Usage: configure.sh get <json-path>}"
    require_config
    jq -r "$path" "$CONFIG_FILE"
}

cmd_set() {
    local path="${1:?Usage: configure.sh set <json-path> <value>}"
    local value="${2:?Usage: configure.sh set <json-path> <value>}"
    require_config

    # Determine if value is a number, boolean, null, or string
    local jq_expr
    if [[ "$value" =~ ^(true|false|null)$ ]] || [[ "$value" =~ ^-?[0-9]+\.?[0-9]*$ ]]; then
        jq_expr="$path = $value"
    else
        jq_expr="$path = \"$value\""
    fi

    local tmp
    tmp=$(mktemp)
    jq "$jq_expr" "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
    echo "Updated $path"
}

cmd_list_services() {
    require_config
    jq -r '.services | keys[]' "$CONFIG_FILE"
}

cmd_validate() {
    require_config
    local errors=0

    echo "Validating $CONFIG_FILE ..."

    # Check for TBD image tags
    local tbd_services
    tbd_services=$(jq -r '.services | to_entries[] | select(.value.tag == "TBD") | .key' "$CONFIG_FILE")
    if [[ -n "$tbd_services" ]]; then
        echo "ERROR: Image tag is TBD for:"
        echo "$tbd_services" | sed 's/^/  - /'
        errors=$((errors + $(echo "$tbd_services" | wc -l)))
    fi

    # Check for required secret names that don't exist yet
    local required_secrets
    required_secrets=$(jq -r '[.services[].secrets[]?.name] | unique[]' "$CONFIG_FILE")
    for secret in $required_secrets; do
        if ! podman secret inspect "$secret" &>/dev/null; then
            echo "WARN: Podman secret '$secret' does not exist (run: configure.sh generate-secrets)"
        fi
    done

    # Check network
    local net_name
    net_name=$(jq -r '.network.name' "$CONFIG_FILE")
    if ! podman network exists "$net_name" 2>/dev/null; then
        echo "WARN: Network '$net_name' does not exist (deploy.sh will create it)"
    fi

    # Check AI_STACK_DIR
    local ai_stack_dir
    ai_stack_dir=$(jq -r '.ai_stack_dir' "$CONFIG_FILE")
    ai_stack_dir="${ai_stack_dir//\$HOME/$HOME}"
    if [[ ! -d "$ai_stack_dir" ]]; then
        echo "WARN: AI_STACK_DIR=$ai_stack_dir does not exist (run: install.sh)"
    fi

    if [[ $errors -gt 0 ]]; then
        echo "Validation FAILED with $errors error(s)."
        exit 1
    fi

    echo "Validation passed."
}

cmd_generate_quadlets() {
    require_config
    mkdir -p "$QUADLET_DIR"

    local net_name net_driver net_internal
    net_name=$(jq -r '.network.name' "$CONFIG_FILE")
    net_driver=$(jq -r '.network.driver' "$CONFIG_FILE")
    net_internal=$(jq -r '.network.internal' "$CONFIG_FILE")

    # Network quadlet
    local net_file="$QUADLET_DIR/ai-stack.network"
    cat > "$net_file" <<EOF
# Generated by configure.sh — do not edit manually
[Network]
NetworkName=$net_name
Driver=$net_driver
Internal=$net_internal
EOF
    echo "Generated $net_file"

    # Service quadlets — filter by node_profile
    local node_profile services
    node_profile=$(jq -r '.node_profile // "controller"' "$CONFIG_FILE")
    case "$node_profile" in
        inference-worker)
            # Ollama (CPU inference) + Promtail (log shipping) only
            services=$'ollama\npromtail'
            echo "Note: node_profile=$node_profile — generating ollama + promtail quadlets only"
            ;;
        *)
            # controller, peer: generate all services
            services=$(jq -r '.services | keys[]' "$CONFIG_FILE")
            ;;
    esac

    local ai_stack_dir
    ai_stack_dir=$(jq -r '.ai_stack_dir' "$CONFIG_FILE")

    # Cache existing Podman secrets once — used to skip Secret= lines for unstored optional keys
    local existing_podman_secrets
    existing_podman_secrets=$(podman secret ls --format '{{.Name}}' 2>/dev/null)

    for svc in $services; do
        local file="$QUADLET_DIR/${svc}.container"
        local image tag container_name
        image=$(jq -r --arg s "$svc" '.services[$s].image' "$CONFIG_FILE")
        tag=$(jq -r --arg s "$svc" '.services[$s].tag' "$CONFIG_FILE")
        container_name=$(jq -r --arg s "$svc" '.services[$s].container_name' "$CONFIG_FILE")

        # Start building quadlet
        {
            echo "# Generated by configure.sh — do not edit manually"
            echo "[Unit]"
            echo "Description=AI Stack $container_name"

            # Dependencies — only emit for services that are also being generated
            local deps
            deps=$(jq -r --arg s "$svc" '.services[$s].depends_on[]?' "$CONFIG_FILE")
            echo "After=ai-stack-network.service"
            echo "Requires=ai-stack-network.service"
            for dep in $deps; do
                if echo "$services" | grep -qx "$dep"; then
                    echo "After=${dep}.service"
                    echo "Requires=${dep}.service"
                fi
            done

            echo ""
            echo "[Container]"
            echo "Image=${image}:${tag}"
            echo "ContainerName=${container_name}"
            echo "Label=com.docker.compose.project=ai-stack"
            echo "Label=ai-stack.service=${svc}"
            local dns_alias
            dns_alias=$(jq -r --arg s "$svc" '.services[$s].dns_alias' "$CONFIG_FILE")
            echo "Network=${net_name}:alias=${dns_alias}"

            # Volumes — rw mode maps to :Z (SELinux relabel), ro mode maps to :ro,Z
            jq -r --arg s "$svc" --arg dir "${ai_stack_dir}" \
                '.services[$s].volumes[]? | "Volume=" + $dir + "/" + (.host | sub("[$]AI_STACK_DIR/"; "")) + ":" + .container + ":" + (if .mode == "ro" then "ro,Z" else "Z" end)' \
                "$CONFIG_FILE" 2>/dev/null | while read -r line; do
                echo "${line//\$HOME/%h}"
            done

            # Secrets — only emit lines for secrets that actually exist in the Podman store;
            # optional cloud API keys may be absent if skipped during generate-secrets.
            while IFS=' ' read -r _sn _tgt; do
                if echo "$existing_podman_secrets" | grep -qx "$_sn"; then
                    echo "Secret=${_sn},type=env,target=${_tgt}"
                else
                    printf '  [warn] %s: secret "%s" not in Podman store — skipping\n' "$svc" "$_sn" >&2
                fi
            done < <(jq -r --arg s "$svc" '.services[$s].secrets[]? | .name + " " + .target' "$CONFIG_FILE")

            # Environment — DATABASE_URL uses EnvironmentFile for credential injection at deploy time
            local has_db_url
            has_db_url=$(jq -r --arg s "$svc" '.services[$s].environment // {} | has("DATABASE_URL")' "$CONFIG_FILE")
            if [[ "$has_db_url" == "true" ]]; then
                echo "EnvironmentFile=${ai_stack_dir//\$HOME/%h}/configs/run/${svc}.env"
            fi
            jq -r --arg s "$svc" '.services[$s].environment // {} | to_entries[] | select(.key != "DATABASE_URL") | "Environment=" + .key + "=" + .value' "$CONFIG_FILE"

            # Ports
            jq -r --arg s "$svc" '.services[$s].ports[]? | "PublishPort=" + (if .bind then .bind + ":" else "" end) + (.host|tostring) + ":" + (.container|tostring)' "$CONFIG_FILE"

            # Health check
            local hc_cmd
            hc_cmd=$(jq -r --arg s "$svc" '.services[$s].health_check.command // empty' "$CONFIG_FILE")
            if [[ -n "$hc_cmd" ]]; then
                echo "HealthCmd=$hc_cmd"
                echo "HealthInterval=$(jq -r --arg s "$svc" '.services[$s].health_check.interval' "$CONFIG_FILE")"
                echo "HealthRetries=$(jq -r --arg s "$svc" '.services[$s].health_check.retries' "$CONFIG_FILE")"
                echo "HealthTimeout=$(jq -r --arg s "$svc" '.services[$s].health_check.timeout' "$CONFIG_FILE")"
            fi

            # Resource limits
            local cpus mem gpu
            cpus=$(jq -r --arg s "$svc" '.services[$s].resources.cpus // empty' "$CONFIG_FILE")
            mem=$(jq -r --arg s "$svc" '.services[$s].resources.memory // empty' "$CONFIG_FILE")
            gpu=$(jq -r --arg s "$svc" '.services[$s].resources.gpu // empty' "$CONFIG_FILE")
            local podman_args=""
            [[ -n "$cpus" ]] && podman_args+="--cpus=$cpus "
            [[ -n "$mem" ]] && podman_args+="--memory=$mem "
            [[ -n "$podman_args" ]] && echo "PodmanArgs=${podman_args% }"
            [[ -n "$gpu" ]] && echo "AddDevice=$gpu"

            # Container command override (overrides image CMD)
            local cmd_override
            cmd_override=$(jq -r --arg s "$svc" '.services[$s].command // empty' "$CONFIG_FILE")
            [[ -n "$cmd_override" ]] && echo "Exec=$cmd_override"

            echo ""
            echo "[Service]"
            echo "Restart=always"
            echo ""
            echo "[Install]"
            echo "WantedBy=default.target"
        } > "$file"

        echo "Generated $file"
    done

    echo ""
    echo "Quadlets written to $QUADLET_DIR"
    echo "Reload with: systemctl --user daemon-reload"
}

cmd_generate_secrets() {
    require_config

    local secrets
    secrets=$(jq -r '[.services[].secrets[]?.name] | unique[]' "$CONFIG_FILE")

    if [[ -z "$secrets" ]]; then
        echo "No secrets defined in config."
        return 0
    fi

    local captured_postgres_pw=""
    local captured_litellm_master_key=""

    for secret in $secrets; do
        if podman secret inspect "$secret" &>/dev/null; then
            echo "Secret '$secret' already exists — skipping"
            continue
        fi

        local value=""

        # openwebui_api_key MUST equal litellm_master_key — auto-derive rather than prompt
        if [[ "$secret" == "openwebui_api_key" ]]; then
            if [[ -n "$captured_litellm_master_key" ]]; then
                value="$captured_litellm_master_key"
                echo "NOTE: 'openwebui_api_key' must match 'litellm_master_key' — auto-deriving value"
            else
                # litellm_master_key was already present in secret store; read it
                local existing_master
                existing_master=$(podman secret inspect litellm_master_key --showsecret \
                    2>/dev/null | jq -r '.[].SecretData' || true)
                if [[ -n "$existing_master" ]]; then
                    value="$existing_master"
                    echo "NOTE: 'openwebui_api_key' auto-derived from existing 'litellm_master_key'"
                else
                    echo "WARN: Cannot determine litellm_master_key — prompting for openwebui_api_key manually"
                    echo "      Ensure it matches litellm_master_key or OpenWebUI will get 401 from LiteLLM."
                    read -rsp "Enter value for secret '$secret': " value
                    echo ""
                fi
            fi
        # Cloud API keys are optional — press Enter to skip
        elif [[ "$secret" == "openai_api_key" || "$secret" == "groq_api_key" || "$secret" == "anthropic_api_key" || "$secret" == "mistral_api_key" ]]; then
            read -rsp "Enter value for secret '$secret' (press Enter to skip — cloud model will be unavailable): " value
            echo ""
        else
            read -rsp "Enter value for secret '$secret': " value
            echo ""
        fi

        if [[ -z "$value" ]]; then
            echo "WARN: Empty value for '$secret' — skipping"
            continue
        fi

        printf '%s' "$value" | podman secret create "$secret" -
        echo "Created secret '$secret'"

        if [[ "$secret" == "postgres_password" ]]; then
            captured_postgres_pw="$value"
        fi
        if [[ "$secret" == "litellm_master_key" ]]; then
            captured_litellm_master_key="$value"
        fi
    done

    # Write DATABASE_URL env files for services that embed the postgres password
    if [[ -n "$captured_postgres_pw" ]]; then
        local ai_stack_dir run_dir
        ai_stack_dir=$(jq -r '.ai_stack_dir' "$CONFIG_FILE")
        ai_stack_dir="${ai_stack_dir//\$HOME/$HOME}"
        run_dir="$ai_stack_dir/configs/run"
        mkdir -p "$run_dir"

        local db_services
        db_services=$(jq -r '.services | to_entries[] | select(.value.environment.DATABASE_URL != null) | .key' "$CONFIG_FILE")
        for svc in $db_services; do
            local db_url
            db_url=$(jq -r --arg s "$svc" '.services[$s].environment.DATABASE_URL' "$CONFIG_FILE")
            # Inject password: aistack:@host → aistack:PASSWORD@host
            db_url="${db_url/:@/:${captured_postgres_pw}@}"
            printf 'DATABASE_URL=%s\n' "$db_url" > "$run_dir/${svc}.env"
            chmod 0600 "$run_dir/${svc}.env"
            echo "Wrote env file: $run_dir/${svc}.env"
        done
    fi

    echo "Done."
}

cmd_generate_litellm_config() {
    require_config

    local models_file="$PROJECT_ROOT/configs/models.json"
    local ai_stack_dir
    ai_stack_dir=$(jq -r '.ai_stack_dir' "$CONFIG_FILE")

    local ollama_url vllm_url
    ollama_url="http://$(jq -r '.services.ollama.dns_alias // "ollama.ai-stack"' "$CONFIG_FILE"):11434"
    vllm_url="http://$(jq -r '.services.vllm.dns_alias // "vllm.ai-stack"' "$CONFIG_FILE"):8000/v1"

    local model_count
    model_count=$(jq '.models | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    if [[ "$model_count" -eq 0 ]]; then
        echo "ERROR: No models[] defined in $CONFIG_FILE" >&2
        exit 1
    fi

    # Build local model entries (models without 'host' field)
    local entries
    entries=$(jq -c '[
      .models[] | select(has("host") | not) |
      if .backend == "ollama" then {
        id: .name,
        description: (.name + " — CPU inference via Ollama"),
        litellm_params: {
          model: ("ollama_chat/" + .name),
          api_base: "OLLAMA_URL",
          api_key: "none",
          max_tokens: 4096
        },
        model_info: { mode: "chat", input_cost_per_token: 0, output_cost_per_token: 0 }
      }
      elif .backend == "vllm" then {
        id: .name,
        description: (.name + " — GPU inference via vLLM" + (if .quantization then " (" + .quantization + ")" else "" end)),
        litellm_params: {
          model: ("openai/" + .name),
          api_base: "VLLM_URL",
          api_key: "none",
          max_tokens: 4096
        },
        model_info: { mode: "chat", input_cost_per_token: 0, output_cost_per_token: 0 }
      }
      elif .backend == "openai" then {
        id: .name,
        description: (.name + " — hosted via OpenAI"),
        litellm_params: {
          model: .name,
          api_key: ("os.environ/" + ((.api_key_secret // "openai_api_key") | ascii_upcase)),
          max_tokens: 4096
        },
        model_info: { mode: "chat", input_cost_per_token: 0, output_cost_per_token: 0 }
      }
      elif .backend == "groq" then {
        id: .name,
        description: (.name + " — hosted via Groq"),
        litellm_params: {
          model: ("groq/" + .name),
          api_key: ("os.environ/" + ((.api_key_secret // "groq_api_key") | ascii_upcase)),
          max_tokens: 4096
        },
        model_info: { mode: "chat", input_cost_per_token: 0, output_cost_per_token: 0 }
      }
      elif .backend == "anthropic" then {
        id: .name,
        description: (.name + " — hosted via Anthropic"),
        litellm_params: {
          model: ("anthropic/" + .name),
          api_key: ("os.environ/" + ((.api_key_secret // "anthropic_api_key") | ascii_upcase)),
          max_tokens: 4096
        },
        model_info: { mode: "chat", input_cost_per_token: 0, output_cost_per_token: 0 }
      }
      elif .backend == "mistral" then {
        id: .name,
        description: (.name + " — hosted via Mistral AI"),
        litellm_params: {
          model: ("mistral/" + .name),
          api_key: ("os.environ/" + ((.api_key_secret // "mistral_api_key") | ascii_upcase)),
          max_tokens: 4096
        },
        model_info: { mode: "chat", input_cost_per_token: 0, output_cost_per_token: 0 }
      }
      else empty
      end
    ]' "$CONFIG_FILE")

    # Substitute URL placeholders
    entries=$(echo "$entries" | sed "s|OLLAMA_URL|${ollama_url}|g; s|VLLM_URL|${vllm_url}|g")

    # Append remote model entries — resolves node addresses (DNS preferred, IP fallback)
    local merged_entries
    merged_entries=$(python3 - "$CONFIG_FILE" "$entries" <<'PYEOF'
import json, sys, subprocess

config_file = sys.argv[1]
entries = json.loads(sys.argv[2])

with open(config_file) as f:
    config = json.load(f)

nodes_map = {n['name']: n for n in config.get('nodes', [])}

for model in config.get('models', []):
    if 'host' not in model:
        continue
    host_name = model['host']
    model_name = model['name']
    node = nodes_map.get(host_name)
    if not node:
        print(f"WARN: Node '{host_name}' not in nodes[] — skipping {model_name}", file=sys.stderr)
        continue
    addr = node.get('address') or ''
    fallback = node.get('address_fallback') or ''
    resolved = ''
    if addr:
        try:
            r = subprocess.run(['getent', 'hosts', addr], capture_output=True, timeout=5)
            if r.returncode == 0:
                resolved = addr
        except Exception:
            pass
    if not resolved and fallback:
        print(f"WARN: DNS '{addr}' unresolvable — using fallback {fallback} for {model_name}", file=sys.stderr)
        resolved = fallback
    if not resolved:
        print(f"WARN: No resolvable address for node '{host_name}' — skipping {model_name}", file=sys.stderr)
        continue
    entries.append({
        'id': model_name,
        'description': f"{model_name} — remote Ollama on {host_name}",
        'litellm_params': {
            'model': f"ollama_chat/{model_name}",
            'api_base': f"http://{resolved}:11434",
            'api_key': 'none',
            'max_tokens': 4096
        },
        'model_info': {'mode': 'chat', 'input_cost_per_token': 0, 'output_cost_per_token': 0}
    })
    print(f"  Added remote model: {model_name} (node: {host_name}, address: {resolved})", file=sys.stderr)

print(json.dumps(entries))
PYEOF
)
    [[ -n "$merged_entries" ]] && entries="$merged_entries"

    # Write models.json
    local comment
    comment="Model routing definitions for LiteLLM — generated by configure.sh generate-litellm-config. Register with: scripts/pull-models.sh"
    python3 - "$comment" "$entries" <<'PYEOF' > "$models_file"
import json, sys
comment = sys.argv[1]
entries = json.loads(sys.argv[2])
print(json.dumps({'_comment': comment, 'default_models': entries}, indent=2))
PYEOF

    echo "Written: $models_file ($model_count model(s))"
    echo "Run 'scripts/pull-models.sh' to register routes in LiteLLM."
}

cmd_detect_hardware() {
    echo "=== Hardware Detection ==="
    echo ""

    local os
    os=$(uname -s 2>/dev/null || echo "Linux")

    if [[ "$os" == "Darwin" ]]; then
        # macOS / Apple Silicon path
        local cpu_model cpu_cores ram_bytes ram_gb is_arm64
        cpu_model=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || echo "unknown")
        cpu_cores=$(sysctl -n hw.logicalcpu 2>/dev/null || echo "?")
        ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        ram_gb=$(( ram_bytes / 1073741824 ))
        is_arm64=$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)

        echo "CPU:  $cpu_model ($cpu_cores cores)"
        echo "RAM:  ${ram_gb} GB unified"
        if [[ "$is_arm64" == "1" ]]; then
            echo "GPU:  Apple Silicon (Metal — unified memory, no dedicated VRAM)"
        else
            echo "GPU:  Intel/x86 Mac (no Metal GPU inference)"
        fi

        # Use ~40% of unified RAM as conservative model-fit target (Ollama manages paging)
        local target_gb=$(( ram_gb * 40 / 100 ))
        echo ""
        echo "=== Model Recommendations (target ~${target_gb} GB of ${ram_gb} GB unified) ==="
        if [[ $target_gb -ge 8 ]]; then
            echo "  llama3.1:8b-instruct-q4_K_M  (~5.0 GB) — high quality, fits with headroom"
            echo "  llama3.2:3b-q4_K_M           (~2.0 GB) — fast, minimal"
        elif [[ $target_gb -ge 5 ]]; then
            echo "  llama3.1:8b-instruct-q4_K_M  (~5.0 GB) — fits, Ollama may page slightly"
            echo "  llama3.2:3b-q4_K_M           (~2.0 GB) — safer choice with headroom"
        elif [[ $target_gb -ge 3 ]]; then
            echo "  llama3.2:3b-q4_K_M           (~2.0 GB) — recommended for this RAM"
            echo "  qwen2.5:1.5b-q8_0            (~1.7 GB) — minimal"
        else
            echo "  qwen2.5:1.5b-q8_0            (~1.7 GB) — only safe option at this RAM"
        fi

    else
        # Linux path
        local cpu_model cpu_cores
        cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "unknown")
        cpu_cores=$(nproc 2>/dev/null || echo "?")
        echo "CPU:  $cpu_model ($cpu_cores cores)"

        local ram_gb
        ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo "?")
        echo "RAM:  ${ram_gb} GB"

        echo ""
        if command -v nvidia-smi &>/dev/null; then
            local gpu_name vram_total vram_free
            gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "unknown")
            vram_total=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
            vram_free=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
            local vram_total_gb vram_free_gb
            vram_total_gb=$(awk "BEGIN{printf \"%.1f\", $vram_total/1024}")
            vram_free_gb=$(awk "BEGIN{printf \"%.1f\", $vram_free/1024}")
            echo "GPU:  $gpu_name"
            echo "VRAM: ${vram_total_gb} GB total, ${vram_free_gb} GB free"

            # CDI check
            if ls /etc/cdi/nvidia.yaml &>/dev/null || ls /run/cdi/nvidia.yaml &>/dev/null; then
                echo "CDI:  nvidia.yaml found — rootless Podman GPU passthrough ready"
            else
                echo "CDI:  NOT configured — run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
            fi

            # Model recommendations based on free VRAM (Q4_K_M Ollama naming)
            echo ""
            echo "=== Model Recommendations (based on ${vram_free_gb} GB free VRAM) ==="
            local vram_free_int
            vram_free_int=$(echo "$vram_free_gb" | cut -d. -f1)
            if [[ $vram_free_int -ge 8 ]]; then
                echo "  llama3.1:8b-instruct-q4_K_M  (~5.0 GB) — high quality, fits with headroom"
                echo "  mistral:7b-q4_K_M            (~4.1 GB) — strong reasoning"
                echo "  llama3.2:3b-q4_K_M           (~2.0 GB) — fast, lightweight"
            elif [[ $vram_free_int -ge 4 ]]; then
                echo "  mistral:7b-q4_K_M            (~4.1 GB) — recommended for this VRAM"
                echo "  llama3.2:3b-q4_K_M           (~2.0 GB) — safe choice with headroom"
                echo "  (FP16 7B+ will OOM — use Q4_K_M only)"
            elif [[ $vram_free_int -ge 3 ]]; then
                echo "  llama3.2:3b-q4_K_M           (~2.0 GB) — recommended"
                echo "  qwen2.5:1.5b-q8_0            (~1.7 GB) — alternative"
                echo "  (Limited VRAM — avoid 7B+ models)"
            else
                echo "  Insufficient free VRAM for GPU inference (< 3 GB)"
                echo "  Recommendation: use Ollama CPU-only (node_profile=inference-worker)"
            fi
        else
            echo "GPU:  No NVIDIA GPU detected (nvidia-smi not found)"
            echo "CDI:  N/A"
            echo ""
            echo "=== Node Profile Recommendation ==="
            echo "  CPU-only node — use Ollama for inference"
            echo "  Suggested node_profile: inference-worker (or controller without vLLM)"
        fi
    fi

    echo ""
    echo "=== Current config.json ==="
    if [[ -f "$CONFIG_FILE" ]]; then
        echo "  node_profile: $(jq -r '.node_profile // "not set"' "$CONFIG_FILE")"
        local model_count
        model_count=$(jq '.models | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        echo "  models[]:     $model_count defined"
        jq -r '.models[]? | "    - " + .name + " (" + .backend + "/" + .device + ")"' "$CONFIG_FILE" 2>/dev/null
    fi
}

cmd_recommend() {
    require_config

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║           AI Stack — Node Profile Recommender               ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    echo ""

    # -----------------------------------------------------------------------
    # 1. OS detection — gate out unsupported immediately
    # -----------------------------------------------------------------------
    local os arch
    os=$(uname -s 2>/dev/null || echo "Linux")
    arch=$(uname -m 2>/dev/null || echo "x86_64")

    local os_label deployment_method
    case "$os" in
        Linux)
            os_label="Linux ($arch)"
            deployment_method="podman"   # refined below
            ;;
        Darwin)
            os_label="macOS ($arch)"
            deployment_method="bare-metal-macos"
            ;;
        *)
            echo "⚠  Unsupported OS: $os"
            echo "   Windows native is not supported as a stack node."
            echo "   Options:"
            echo "     • Use WSL2 (Ubuntu) and re-run this script inside WSL2"
            echo "     • Connect this machine as a client only (no node deployment)"
            exit 0
            ;;
    esac
    echo "OS:   $os_label"

    # -----------------------------------------------------------------------
    # 2. Hardware detection
    # -----------------------------------------------------------------------
    local cpu_cores ram_gb gpu_name vram_gb podman_ver podman_ok disk_free_gb
    cpu_cores=$(nproc 2>/dev/null || sysctl -n hw.logicalcpu 2>/dev/null || echo 0)

    if [[ "$os" == "Darwin" ]]; then
        local ram_bytes
        ram_bytes=$(sysctl -n hw.memsize 2>/dev/null || echo 0)
        ram_gb=$(( ram_bytes / 1073741824 ))
        gpu_name="Apple Silicon (Metal/unified)"
        vram_gb=$ram_gb    # unified memory — conservative 40% used below
    else
        ram_gb=$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0)
        if command -v nvidia-smi &>/dev/null; then
            gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || echo "")
            local vram_mb
            vram_mb=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 || echo 0)
            vram_gb=$(awk "BEGIN{printf \"%.0f\", $vram_mb/1024}")
        else
            gpu_name=""
            vram_gb=0
        fi
    fi

    # Podman availability + version
    if command -v podman &>/dev/null; then
        podman_ver=$(podman --version 2>/dev/null | awk '{print $3}')
        local podman_maj
        podman_maj=$(echo "$podman_ver" | cut -d. -f1)
        if [[ "$podman_maj" -ge 4 ]]; then
            podman_ok=true
        else
            podman_ok=false
        fi
    else
        podman_ver="not installed"
        podman_ok=false
    fi

    # Disk free on project partition
    disk_free_gb=$(df -BG "$PROJECT_ROOT" 2>/dev/null | awk 'NR==2{gsub("G",""); print $4}' || echo 0)

    echo "CPU:  $cpu_cores cores"
    echo "RAM:  ${ram_gb} GB"
    [[ -n "$gpu_name" ]] && echo "GPU:  $gpu_name (${vram_gb} GB VRAM)"
    [[ -z "$gpu_name" && "$os" != "Darwin" ]] && echo "GPU:  none detected"
    echo "Disk: ${disk_free_gb} GB free (on project partition)"
    echo "Podman: $podman_ver"
    echo ""

    # -----------------------------------------------------------------------
    # 3. Shared-use gate — exit early for high-contention machines
    # -----------------------------------------------------------------------
    local machine_type hours_available
    read -r -p "Machine type? [server/shared-use/laptop] (default: server): " machine_type
    machine_type="${machine_type:-server}"

    read -r -p "Hours available to the stack per day? [0-24] (default: 24): " hours_available
    hours_available="${hours_available:-24}"

    if [[ "$machine_type" == "shared-use" && "$hours_available" -lt 12 ]]; then
        echo ""
        echo "⚠  High-use shared systems with limited availability are not recommended"
        echo "   as stack nodes — resource contention and intermittent uptime reduce"
        echo "   reliability for other stack users."
        echo ""
        echo "   Alternatives:"
        echo "     • Add a cloud provider (OpenAI / Anthropic / Mistral) for inference"
        echo "     • Use this machine as a client only (OpenWebUI in a browser)"
        echo ""
        echo "No profile written."
        exit 0
    fi

    # -----------------------------------------------------------------------
    # 4. Remaining prompts
    # -----------------------------------------------------------------------
    local dedicated stays_awake connectivity

    read -r -p "Dedicated to the stack (not also a desktop in active use)? [yes/no] (default: yes): " dedicated
    dedicated="${dedicated:-yes}"

    read -r -p "Stays awake under load (no sleep/suspend)? [yes/no] (default: yes): " stays_awake
    stays_awake="${stays_awake:-yes}"

    read -r -p "Connectivity to controller? [lan/vpn/internet] (default: internet): " connectivity
    connectivity="${connectivity:-internet}"

    # -----------------------------------------------------------------------
    # 5. Profile decision logic
    # -----------------------------------------------------------------------
    local profile
    local deploy_method
    local warnings=()
    local prereqs=()

    # macOS — always inference-worker, bare-metal only
    if [[ "$os" == "Darwin" ]]; then
        profile="inference-worker"
        deploy_method="bare-metal (ollama native)"
        local target_vram=$(( vram_gb * 40 / 100 ))
        if [[ $target_vram -ge 8 ]]; then
            prereqs+=("Recommended model: llama3.1:8b-instruct-q4_K_M (~5 GB from unified RAM)")
        else
            prereqs+=("Recommended model: llama3.2:3b-q4_K_M (~2 GB from unified RAM)")
        fi
        prereqs+=("Install ollama: https://ollama.com/download")

    # Linux path
    else
        # Determine deployment method
        if [[ "$podman_ok" == "true" ]]; then
            deploy_method="podman quadlets (systemd)"
        else
            deploy_method="bare-metal systemd (Podman unavailable or < 4.x)"
            [[ "$podman_ok" == "false" && "$podman_ver" != "not installed" ]] && \
                warnings+=("Podman $podman_ver < 4.0 — upgrade for full quadlet support")
            [[ "$podman_ver" == "not installed" ]] && \
                warnings+=("Podman not found — install: sudo dnf install -y podman")
        fi

        # Controller threshold: ≥ 12 cores, ≥ 48 GB RAM
        local is_controller_capable=false
        if [[ "$cpu_cores" -ge 12 && "$ram_gb" -ge 48 && "$dedicated" == "yes" && "$hours_available" -ge 20 ]]; then
            is_controller_capable=true
        fi

        # Peer threshold: same as controller (Phase 10)
        # For now peer == controller requirements
        local is_peer_capable=false
        if [[ "$cpu_cores" -ge 12 && "$ram_gb" -ge 48 && "$dedicated" == "yes" ]]; then
            is_peer_capable=true
        fi

        # Inference worker: GPU-capable, any uptime
        local is_inference_capable=false
        if [[ "$vram_gb" -ge 4 || "$ram_gb" -ge 16 ]]; then
            is_inference_capable=true
        fi

        # Assign profile
        if [[ "$is_controller_capable" == "true" ]]; then
            profile="controller"
        elif [[ "$is_peer_capable" == "true" ]]; then
            profile="peer"
            warnings+=("Peer profile requires Phase 10 implementation (not yet complete)")
        elif [[ "$is_inference_capable" == "true" ]]; then
            profile="inference-worker"
        else
            profile="none"
            warnings+=("Insufficient resources for any node role — recommend client-only use")
        fi

        # Resource warnings
        [[ "$ram_gb" -lt 16 ]] && warnings+=("Low RAM (${ram_gb} GB) — inference will be CPU-only and slow")
        [[ "$disk_free_gb" -lt 20 ]] && warnings+=("Low disk (${disk_free_gb} GB free) — model storage may be constrained")
        [[ "$stays_awake" == "no" ]] && warnings+=("Sleep/suspend enabled — node will drop from mesh when idle; set power plan to never-sleep")
        [[ "$vram_gb" -ge 4 ]] && \
            { ls /etc/cdi/nvidia.yaml &>/dev/null 2>&1 || ls /run/cdi/nvidia.yaml &>/dev/null 2>&1; } || \
            { [[ "$vram_gb" -ge 4 ]] && warnings+=("CDI not configured — GPU passthrough unavailable. Run: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"); }

        # Prerequisites by profile
        case "$profile" in
            controller)
                prereqs+=("Run: bash scripts/configure.sh generate-secrets")
                prereqs+=("Run: bash scripts/configure.sh generate-quadlets")
                prereqs+=("Run: systemctl --user daemon-reload && bash scripts/start.sh")
                ;;
            inference-worker)
                prereqs+=("Run: bash scripts/configure.sh generate-quadlets  (ollama + promtail only)")
                prereqs+=("Run: systemctl --user daemon-reload && systemctl --user start ollama.service")
                ;;
            peer)
                prereqs+=("Phase 10 implementation required before deploying peer profile")
                ;;
        esac

        # Networking note
        case "$connectivity" in
            internet)
                prereqs+=("Internet node: port 443 must be forwarded to this host")
                prereqs+=("Recommend static IP or DDNS hostname for reliable connectivity")
                prereqs+=("TLS + Authentik auth are handled by Traefik (already configured)")
                ;;
            vpn)
                prereqs+=("VPN node: ensure WireGuard/Tailscale tunnel is up before deploying")
                prereqs+=("Treat as LAN once tunnel is active — no extra port forwarding needed")
                ;;
            lan)
                prereqs+=("LAN node: no external firewall changes needed")
                ;;
        esac
    fi

    # -----------------------------------------------------------------------
    # 6. Output recommendation
    # -----------------------------------------------------------------------
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "  Recommended profile:    $profile"
    echo "  Deployment method:      $deploy_method"
    echo "  Machine type:           $machine_type ($hours_available hrs/day)"
    echo "  Connectivity:           $connectivity"
    echo ""

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo "  ⚠  Warnings:"
        for w in "${warnings[@]}"; do
            echo "       • $w"
        done
        echo ""
    fi

    if [[ ${#prereqs[@]} -gt 0 ]]; then
        echo "  Next steps:"
        for p in "${prereqs[@]}"; do
            echo "       • $p"
        done
        echo ""
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    if [[ "$profile" == "none" ]]; then
        echo "No profile written (insufficient resources)."
        return 0
    fi

    # -----------------------------------------------------------------------
    # 7. Offer to write profile to config.json
    # -----------------------------------------------------------------------
    local current_profile
    current_profile=$(jq -r '.node_profile // "not set"' "$CONFIG_FILE")
    local confirm
    read -r -p "Write node_profile=\"$profile\" to config.json? (current: $current_profile) [yes/no] (default: yes): " confirm
    confirm="${confirm:-yes}"

    if [[ "$confirm" == "yes" ]]; then
        local tmp
        tmp=$(mktemp)
        jq --arg p "$profile" '.node_profile = $p' "$CONFIG_FILE" > "$tmp" && mv "$tmp" "$CONFIG_FILE"
        echo "✓ node_profile set to \"$profile\" in $CONFIG_FILE"
        echo "  Run 'bash scripts/configure.sh generate-quadlets' to apply."
    else
        echo "Profile not written."
    fi
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

require_jq

case "${1:-help}" in
    init)                    cmd_init ;;
    get)                     cmd_get "${2:-}" ;;
    set)                     cmd_set "${2:-}" "${3:-}" ;;
    list-services)           cmd_list_services ;;
    validate)                cmd_validate ;;
    generate-quadlets)       cmd_generate_quadlets ;;
    generate-secrets)        cmd_generate_secrets ;;
    generate-litellm-config) cmd_generate_litellm_config ;;
    detect-hardware)         cmd_detect_hardware ;;
    recommend)               cmd_recommend ;;
    help|--help|-h)          usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
