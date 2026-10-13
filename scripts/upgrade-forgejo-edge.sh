#!/usr/bin/env bash
# scripts/upgrade-forgejo-edge.sh — Safe, hostname-guarded Forgejo binary upgrade
#
# Forgejo (15.0.3+gitea-1.22.0 -> 15.0.10) is a native, root-owned single-binary
# install on photondatum.space (the edge VPS) — there is no passwordless sudo
# there, so this cannot be driven non-interactively over SSH. Run it directly,
# at an interactive shell, ON photondatum.space, so sudo can prompt you.
#
# This script refuses to run anywhere else (see the hostname guard below) —
# it exists specifically because a prior manual attempt at this same upgrade
# left it unclear which host a command had actually executed on.
#
# Forgejo's release hosts (codeberg.org, code.forgejo.org) sit behind an
# anti-bot challenge that returns a stub instead of the real file to scripted
# clients (curl/wget), so this script cannot download the binary itself.
# Download it yourself in a browser first:
#   https://code.forgejo.org/forgejo/forgejo/releases/download/v15.0.10/forgejo-15.0.10-linux-amd64
#   https://code.forgejo.org/forgejo/forgejo/releases/download/v15.0.10/forgejo-15.0.10-linux-amd64.asc
# scp both to this host, then run this script against the local copy.
#
# Usage:
#   ./upgrade-forgejo-edge.sh <path-to-forgejo-15.0.10-linux-amd64> [path-to-.asc]
#   ./upgrade-forgejo-edge.sh --rollback
#
# Note on rollback: if the new binary already started and ran its DB
# migrations before you roll back, a binary-only revert may not be
# compatible with the migrated schema. Roll back immediately on a failed
# start; if migrations already ran, restore the DB dump this script takes
# (via `forgejo restore`) before trusting the older binary against it.

set -euo pipefail

# ---- Safety: refuse to run anywhere but the edge host ----
EXPECTED_HOST="photondatum"
ACTUAL_HOST="$(hostname -s)"
if [[ "$ACTUAL_HOST" != "$EXPECTED_HOST" ]]; then
    echo "ERROR: this script upgrades Forgejo on the edge VPS and must be run" >&2
    echo "       there directly. Current host is '$ACTUAL_HOST', expected '$EXPECTED_HOST'." >&2
    echo "       Refusing to continue." >&2
    exit 1
fi

CURRENT_VERSION_EXPECTED="15.0.3+gitea-1.22.0"
TARGET_VERSION="15.0.10"
BINARY_PATH="/usr/local/bin/forgejo"
SERVICE_NAME="forgejo.service"
BACKUP_DIR="$HOME/ai-stack-manual-backups"
GPG_KEY_FPR="EB114F5E6C0DC2BCDD183550A4B61A2DC5923710"
FORGEJO_USER="git"
TS="$(date -u +%Y%m%dT%H%M%S)"

usage() {
    cat <<EOF
Usage:
  $0 <path-to-forgejo-${TARGET_VERSION}-linux-amd64> [path-to-.asc-signature]
  $0 --rollback

Download the binary (and ideally its .asc signature) yourself first —
Forgejo's release hosts sit behind an anti-bot challenge that blocks
scripted downloads:
  https://code.forgejo.org/forgejo/forgejo/releases/download/v${TARGET_VERSION}/forgejo-${TARGET_VERSION}-linux-amd64
  https://code.forgejo.org/forgejo/forgejo/releases/download/v${TARGET_VERSION}/forgejo-${TARGET_VERSION}-linux-amd64.asc
scp both to this host, then run this script against the local copy.
EOF
    exit 1
}

[[ $# -ge 1 ]] || usage

mkdir -p "$BACKUP_DIR"

# ---- Rollback path ----
if [[ "$1" == "--rollback" ]]; then
    BACKUP_BIN=$(ls -t "$BACKUP_DIR"/forgejo.pre-*.bak 2>/dev/null | head -1 || true)
    if [[ -z "$BACKUP_BIN" ]]; then
        echo "ERROR: no forgejo.pre-*.bak found in $BACKUP_DIR — nothing to roll back to." >&2
        exit 1
    fi
    echo "Rolling back to $BACKUP_BIN ..."
    sudo systemctl stop "$SERVICE_NAME"
    sudo install -o root -g root -m 755 "$BACKUP_BIN" "$BINARY_PATH"
    sudo systemctl start "$SERVICE_NAME"
    sleep 3
    "$BINARY_PATH" --version
    systemctl is-active "$SERVICE_NAME"
    echo "Rollback complete."
    exit 0
fi

NEW_BINARY="$1"
SIG_FILE="${2:-}"

[[ -f "$NEW_BINARY" ]] || { echo "ERROR: $NEW_BINARY not found." >&2; exit 1; }
NEW_BINARY="$(realpath "$NEW_BINARY")"
[[ -n "$SIG_FILE" ]] && SIG_FILE="$(realpath "$SIG_FILE")"

# ---- Pre-flight: confirm current installed state matches what we expect ----
INSTALLED_VERSION="$("$BINARY_PATH" --version | awk '{print $3}')"
if [[ "$INSTALLED_VERSION" == *"$TARGET_VERSION"* ]]; then
    echo "Already at $TARGET_VERSION ($INSTALLED_VERSION) — nothing to do."
    exit 0
fi
if [[ "$INSTALLED_VERSION" != "$CURRENT_VERSION_EXPECTED" ]]; then
    echo "WARNING: installed version is '$INSTALLED_VERSION', expected '$CURRENT_VERSION_EXPECTED'." >&2
    read -r -p "Continue anyway? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
fi

# ---- Verify the downloaded binary (GPG preferred; fail closed without it) ----
if [[ -n "$SIG_FILE" ]] && command -v gpg >/dev/null; then
    echo "Verifying GPG signature..."
    gpg --keyserver keys.openpgp.org --recv-keys "$GPG_KEY_FPR" 2>&1 | tail -3
    if gpg --verify "$SIG_FILE" "$NEW_BINARY"; then
        echo "GPG signature OK."
    else
        echo "ERROR: GPG signature verification FAILED. Refusing to install." >&2
        exit 1
    fi
else
    echo "WARNING: no .asc signature supplied / gpg unavailable — binary cannot be verified." >&2
    sha256sum "$NEW_BINARY"
    read -r -p "Proceed WITHOUT signature verification? [y/N] " ans
    [[ "$ans" == "y" || "$ans" == "Y" ]] || exit 1
fi

chmod +x "$NEW_BINARY" 2>/dev/null || true
NEW_VERSION_STRING="$("$NEW_BINARY" --version)"
echo "New binary reports: $NEW_VERSION_STRING"
[[ "$NEW_VERSION_STRING" == *"$TARGET_VERSION"* ]] || {
    echo "ERROR: downloaded binary does not report version $TARGET_VERSION. Aborting." >&2
    exit 1
}

# ---- Backups: DB dump + binary copy, both before touching anything live ----
echo "Taking a pre-upgrade Forgejo DB dump..."
DUMP_TMP="/tmp/forgejo-dump-$TS"
mkdir -p "$DUMP_TMP"
sudo -u "$FORGEJO_USER" bash -c "cd '$DUMP_TMP' && '$BINARY_PATH' dump -c /etc/forgejo/app.ini --type tar.gz --file forgejo-dump-pre-${TARGET_VERSION}-${TS}.tar.gz"
sudo mv "$DUMP_TMP/forgejo-dump-pre-${TARGET_VERSION}-${TS}.tar.gz" "$BACKUP_DIR/"
sudo chown "$(id -u):$(id -g)" "$BACKUP_DIR/forgejo-dump-pre-${TARGET_VERSION}-${TS}.tar.gz"
rmdir "$DUMP_TMP" 2>/dev/null || true
echo "DB dump saved: $BACKUP_DIR/forgejo-dump-pre-${TARGET_VERSION}-${TS}.tar.gz"

echo "Backing up current binary..."
sudo cp "$BINARY_PATH" "$BACKUP_DIR/forgejo.pre-${TARGET_VERSION}-${TS}.bak"
sudo chown "$(id -u):$(id -g)" "$BACKUP_DIR/forgejo.pre-${TARGET_VERSION}-${TS}.bak"

# ---- Swap ----
echo "Stopping $SERVICE_NAME..."
sudo systemctl stop "$SERVICE_NAME"
sudo install -o root -g root -m 755 "$NEW_BINARY" "$BINARY_PATH"
echo "Starting $SERVICE_NAME..."
sudo systemctl start "$SERVICE_NAME"

# ---- Validate ----
sleep 3
for _ in $(seq 1 10); do
    systemctl is-active --quiet "$SERVICE_NAME" && break
    sleep 2
done
systemctl is-active "$SERVICE_NAME"
"$BINARY_PATH" --version
curl -sf -o /dev/null http://127.0.0.1:3000/ && echo "Local health check (127.0.0.1:3000): OK"
curl -sf https://git.photondatum.space/api/v1/version && echo

echo
echo "Forgejo upgraded: $INSTALLED_VERSION -> $TARGET_VERSION"
echo "Rollback binary kept at: $BACKUP_DIR/forgejo.pre-${TARGET_VERSION}-${TS}.bak"
echo "DB dump kept at:         $BACKUP_DIR/forgejo-dump-pre-${TARGET_VERSION}-${TS}.tar.gz"
echo "To revert: $0 --rollback"
echo
echo "Next: log in via the web UI and confirm OIDC login through Authentik still works."
