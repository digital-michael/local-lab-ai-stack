#!/usr/bin/env bash
# scripts/cleanup.sh — AI Stack disk/DB maintenance
#
# Placeholder for future maintenance needs — currently scoped to exactly
# three actions:
#   images       podman image prune       (dangling ai-stack images only)
#   images-all   podman image prune -a    (all unused ai-stack images, incl. tagged)
#   postgres     VACUUM (ANALYZE) every database in the cluster
#
# image/image-all are filtered to this stack's own images via the
# `com.docker.compose.project=ai-stack` label already set on every
# ai-stack quadlet, so a host also running unrelated podman workloads
# won't have those images touched.
#
# postgres runs a plain VACUUM (ANALYZE): reclaims dead-tuple space for
# reuse and refreshes planner statistics, without an exclusive lock or
# blocking normal traffic — the right default for routine maintenance.
# VACUUM FULL (returns space to the OS, but takes a per-table exclusive
# lock) and REINDEX (rebuilds bloated indexes) are heavier, occasionally-
# useful tools better run deliberately by hand when actually needed, not
# defaulted into by a maintenance script — not wired up here.
#
# Also explicitly not attempted here: log rotation, Qdrant snapshot
# pruning, backup retention (already handled by backup.sh). Left for a
# future pass, whenever they're actually needed.
#
# Usage:
#   cleanup.sh report              # disk usage + postgres dead-tuple summary (read-only)
#   cleanup.sh images               # prune dangling ai-stack images
#   cleanup.sh images-all           # prune all unused ai-stack images (tagged too)
#   cleanup.sh postgres             # VACUUM (ANALYZE) every database
#   cleanup.sh <command> --dry-run  # print what would run, don't execute
#
# Environment:
#   AI_STACK_DIR   Deployed instance root (default: ~/ai-stack) — unused
#                  today, kept for parity with the rest of scripts/ and
#                  for whatever future actions end up needing it.

set -euo pipefail

AI_STACK_DIR="${AI_STACK_DIR:-$HOME/ai-stack}"
COMPOSE_LABEL="com.docker.compose.project=ai-stack"
DRY_RUN=false

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

ai_stack_present() {
    podman container exists postgres 2>/dev/null
}

require_ai_stack() {
    if ! ai_stack_present; then
        echo "AI stack not detected on this host (no 'postgres' container) — nothing to do." >&2
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_report() {
    echo "--- Podman disk usage ---"
    podman system df -v
    echo ""
    if podman container exists postgres 2>/dev/null; then
        echo "--- PostgreSQL dead tuples (aistack db, top 10 by dead-tuple count) ---"
        podman exec postgres psql -U aistack -d aistack -c \
            "SELECT relname, n_live_tup, n_dead_tup, last_autovacuum
             FROM pg_stat_user_tables
             ORDER BY n_dead_tup DESC
             LIMIT 10;"
    else
        echo "postgres container not found — skipping dead-tuple report."
    fi
}

cmd_images() {
    require_ai_stack
    log "Pruning dangling ai-stack images (label ${COMPOSE_LABEL})..."
    # -f: podman's own confirmation prompt has no stdin to answer when this
    # runs non-interactively (cron/systemd timer) and errors out (EOF)
    # instead of pruning — --dry-run is this script's safety net instead,
    # same as backup.sh.
    run podman image prune -f --filter "label=${COMPOSE_LABEL}"
}

cmd_images_all() {
    require_ai_stack
    log "Pruning ALL unused ai-stack images (label ${COMPOSE_LABEL}) — this also removes tagged images not used by any current container."
    run podman image prune -a -f --filter "label=${COMPOSE_LABEL}"
}

cmd_postgres() {
    require_ai_stack
    log "Running VACUUM (ANALYZE) against every database in the cluster..."
    run podman exec postgres vacuumdb -U aistack --all --analyze
}

usage() {
    cat <<'EOF'
Usage: cleanup.sh <command> [--dry-run]

Commands:
  report        Show podman disk usage and postgres dead-tuple counts (read-only)
  images        podman image prune — remove dangling ai-stack images
  images-all    podman image prune -a — remove all unused ai-stack images (tagged too)
  postgres      VACUUM (ANALYZE) every database in the cluster
  help          Show this message

Options:
  --dry-run     Print the action that would run, without executing it

Environment:
  AI_STACK_DIR  Deployed instance root (default: ~/ai-stack)

This is a placeholder for future maintenance needs, scoped to exactly the
three actions above for now. See the header comment for what was
deliberately left out (VACUUM FULL, REINDEX, log rotation, Qdrant
snapshot pruning) and why.
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

ARGS=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) ARGS+=("$arg") ;;
    esac
done
if [[ ${#ARGS[@]} -gt 0 ]]; then
    set -- "${ARGS[@]}"
else
    set --
fi

case "${1:-help}" in
    report)         cmd_report ;;
    images)         cmd_images ;;
    images-all)     cmd_images_all ;;
    postgres)       cmd_postgres ;;
    help|--help|-h) usage ;;
    *)
        echo "Unknown command: $1" >&2
        usage >&2
        exit 1
        ;;
esac
