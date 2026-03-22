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

            # Secrets
            jq -r --arg s "$svc" '.services[$s].secrets[]? | "Secret=" + .name + ",type=env,target=" + .target' "$CONFIG_FILE"

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
    help|--help|-h)          usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
