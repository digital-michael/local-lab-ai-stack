#!/usr/bin/env bash
# scripts/backup.sh — AI Stack data backup
#
# Backs up all persistent stack data to $AI_STACK_DIR/backups/<timestamp>/.
# Intended to be run daily as a systemd timer or cron job.
#
# What is backed up:
#   PostgreSQL  — pg_dump of every database in the cluster
#   Qdrant      — snapshot via REST API
#   Libraries   — tar of $AI_STACK_DIR/libraries/
#   Config      — tar of $AI_STACK_DIR/configs/ (excluding tls/ private keys)
#
# Retention: by default the 7 most recent backup sets are kept.
#
# Usage:
#   backup.sh                        # run backup with default retention (7)
#   backup.sh --dry-run              # show what would be done, no writes
#   BACKUP_KEEP=14 backup.sh         # keep 14 backup sets
#   backup.sh --restore <timestamp>  # restore from a specific backup
#
# Environment variables:
#   AI_STACK_DIR   Base directory (default: $HOME/ai-stack)
#   BACKUP_KEEP    Number of backup sets to retain (default: 7)
#   QDRANT_PORT    Qdrant HTTP port (default: 6333)

set -euo pipefail

AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
BACKUP_BASE="$AI_STACK_DIR/backups"
BACKUP_KEEP="${BACKUP_KEEP:-7}"
QDRANT_PORT="${QDRANT_PORT:-6333}"
DRY_RUN=false
RESTORE_TIMESTAMP=""

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --dry-run              Print actions without executing them
  --restore <timestamp>  Restore from backup set (e.g. 20260308T120000)
  --help                 Show this message

Environment:
  AI_STACK_DIR   Stack base directory (default: \$HOME/ai-stack)
  BACKUP_KEEP    Retention count — number of sets to keep (default: 7)
  QDRANT_PORT    Qdrant HTTP port (default: 6333)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)   DRY_RUN=true; shift ;;
        --restore)   RESTORE_TIMESTAMP="${2:?--restore requires a timestamp}"; shift 2 ;;
        --help|-h)   usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[$(date '+%H:%M:%S')] $*"; }
run() {
    if [[ "$DRY_RUN" == "true" ]]; then
        echo "  [dry-run] $*"
    else
        "$@"
    fi
}

require_running() {
    local container="$1"
    if ! podman ps --format "{{.Names}}" | grep -qx "$container"; then
        echo "WARN: Container '$container' is not running — skipping its backup."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------

do_backup() {
    local ts
    ts=$(date '+%Y%m%dT%H%M%S')
    local dest="$BACKUP_BASE/$ts"

    log "Starting backup — destination: $dest"
    [[ "$DRY_RUN" == "false" ]] && mkdir -p "$dest"

    # --- PostgreSQL ---
    if require_running postgres; then
        log "PostgreSQL: dumping all databases..."
        run podman exec postgres \
            pg_dumpall -U aistack \
            > "${dest}/postgres_all.sql"
        log "PostgreSQL: dump complete (${dest}/postgres_all.sql)"
    fi

    # --- Qdrant snapshots ---
    if require_running qdrant; then
        log "Qdrant: creating snapshots for all collections..."
        local snap_dir="${dest}/qdrant_snapshots"
        [[ "$DRY_RUN" == "false" ]] && mkdir -p "$snap_dir"

        # Get all collection names
        local collections
        collections=$(curl -sf "http://localhost:${QDRANT_PORT}/collections" \
            | python3 -c "import json,sys; [print(c['name']) for c in json.load(sys.stdin)['result']['collections']]" \
            2>/dev/null || echo "")

        if [[ -z "$collections" ]]; then
            log "Qdrant: no collections found (or API unreachable) — skipping snapshot"
        else
            for coll in $collections; do
                log "Qdrant: snapshotting collection '$coll'..."
                # Create a snapshot and download it
                local snap_name
                snap_name=$(curl -sf -X POST \
                    "http://localhost:${QDRANT_PORT}/collections/${coll}/snapshots" \
                    | python3 -c "import json,sys; print(json.load(sys.stdin)['result']['name'])")
                run curl -sf --output "${snap_dir}/${coll}-${snap_name}" \
                    "http://localhost:${QDRANT_PORT}/collections/${coll}/snapshots/${snap_name}"
                # Clean up the on-container snapshot
                run curl -sf -X DELETE \
                    "http://localhost:${QDRANT_PORT}/collections/${coll}/snapshots/${snap_name}" \
                    > /dev/null
                log "Qdrant: saved ${snap_dir}/${coll}-${snap_name}"
            done
        fi
    fi

    # --- Knowledge Libraries ---
    if [[ -d "$AI_STACK_DIR/libraries" ]]; then
        log "Libraries: archiving $AI_STACK_DIR/libraries/ ..."
        run tar -czf "${dest}/libraries.tar.gz" \
            -C "$AI_STACK_DIR" libraries/
        log "Libraries: archived (${dest}/libraries.tar.gz)"
    else
        log "Libraries: directory not found — skipping"
    fi

    # --- Service configuration (no private keys) ---
    log "Config: archiving stack service configuration..."
    run tar -czf "${dest}/configs.tar.gz" \
        --exclude='configs/tls/*.key' \
        --exclude='configs/tls/*.pem' \
        --exclude='configs/run/' \
        -C "$AI_STACK_DIR" configs/
    log "Config: archived (${dest}/configs.tar.gz)"

    # --- Backup manifest ---
    if [[ "$DRY_RUN" == "false" ]]; then
        {
            echo "timestamp: $ts"
            echo "host: $(hostname)"
            echo "ai_stack_dir: $AI_STACK_DIR"
            echo "files:"
            ls -1 "$dest/"
        } > "${dest}/manifest.txt"
    fi

    log "Backup complete: $dest"

    # --- Retention: remove old backup sets ---
    local n_sets
    n_sets=$(ls -1d "$BACKUP_BASE"/[0-9]* 2>/dev/null | wc -l)
    if (( n_sets > BACKUP_KEEP )); then
        local n_delete=$(( n_sets - BACKUP_KEEP ))
        log "Retention: removing $n_delete oldest backup set(s) (keeping $BACKUP_KEEP)..."
        ls -1d "$BACKUP_BASE"/[0-9]* | head -n "$n_delete" | while read -r old_set; do
            log "Removing: $old_set"
            run rm -rf "$old_set"
        done
    fi

    log "Done. Backup set saved to: $dest"
}

# ---------------------------------------------------------------------------
# Restore
# ---------------------------------------------------------------------------

do_restore() {
    local ts="$RESTORE_TIMESTAMP"
    local src="$BACKUP_BASE/$ts"

    if [[ ! -d "$src" ]]; then
        echo "ERROR: Backup set not found: $src" >&2
        echo "Available backup sets:" >&2
        ls -1d "$BACKUP_BASE"/[0-9]* 2>/dev/null || echo "  (none)" >&2
        exit 1
    fi

    log "Restoring from: $src"
    if [[ -f "${src}/manifest.txt" ]]; then
        log "Manifest:"
        sed 's/^/  /' "${src}/manifest.txt"
    fi

    echo ""
    echo "WARNING: Restore will overwrite current data."
    echo "All running stack services should be stopped before restoring."
    echo ""
    read -rp "Proceed with restore from $ts? [yes/N] " confirm
    [[ "$confirm" == "yes" ]] || { echo "Aborted."; exit 0; }

    # --- Stop all services ---
    log "Stopping stack services..."
    run systemctl --user stop \
        flowise.service openwebui.service grafana.service prometheus.service \
        loki.service promtail.service litellm.service vllm.service llamacpp.service \
        knowledge-index.service authentik.service qdrant.service postgres.service \
        traefik.service 2>/dev/null || true

    # --- PostgreSQL restore ---
    if [[ -f "${src}/postgres_all.sql" ]]; then
        log "PostgreSQL: starting container temporarily for restore..."
        run systemctl --user start postgres.service
        sleep 5
        log "PostgreSQL: restoring from dump..."
        run podman exec -i postgres \
            psql -U aistack -d postgres < "${src}/postgres_all.sql"
        log "PostgreSQL: restore complete"
    else
        log "PostgreSQL: no dump found in backup set — skipping"
    fi

    # --- Qdrant restore ---
    if [[ -d "${src}/qdrant_snapshots" ]]; then
        log "Qdrant: starting container temporarily for restore..."
        run systemctl --user start qdrant.service
        sleep 5
        local snap_files
        snap_files=$(ls "${src}/qdrant_snapshots/"*.snapshot 2>/dev/null || true)
        if [[ -z "$snap_files" ]]; then
            snap_files=$(ls "${src}/qdrant_snapshots/" 2>/dev/null || true)
        fi
        for snap_file in $snap_files; do
            local coll_name
            coll_name=$(basename "$snap_file" | cut -d'-' -f1)
            log "Qdrant: restoring collection '$coll_name' from $(basename "$snap_file")..."
            # Upload snapshot
            run curl -sf -X POST \
                "http://localhost:${QDRANT_PORT}/collections/${coll_name}/snapshots/upload?priority=snapshot" \
                -H "Content-Type: multipart/form-data" \
                -F "snapshot=@${snap_file}" \
                > /dev/null
            log "Qdrant: collection '${coll_name}' restored"
        done
    else
        log "Qdrant: no snapshots found in backup set — skipping"
    fi

    # --- Libraries restore ---
    if [[ -f "${src}/libraries.tar.gz" ]]; then
        log "Libraries: restoring..."
        run tar -xzf "${src}/libraries.tar.gz" -C "$AI_STACK_DIR"
        log "Libraries: restored"
    else
        log "Libraries: no archive in backup set — skipping"
    fi

    # --- Config restore ---
    if [[ -f "${src}/configs.tar.gz" ]]; then
        log "Config: restoring service configuration..."
        run tar -xzf "${src}/configs.tar.gz" -C "$AI_STACK_DIR"
        log "Config: restored"
    else
        log "Config: no archive in backup set — skipping"
    fi

    log ""
    log "Restore complete. Start services with:"
    log "  systemctl --user start postgres.service qdrant.service"
    log "  systemctl --user start authentik.service litellm.service"
    log "  systemctl --user start flowise.service openwebui.service"
    log "  systemctl --user start prometheus.service grafana.service loki.service promtail.service"
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if [[ -n "$RESTORE_TIMESTAMP" ]]; then
    do_restore
else
    do_backup
fi
