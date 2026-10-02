#!/usr/bin/env bash
# scripts/setup-photondatum-mailserver.sh
#
# Sets up a real inbound+outbound mail server for photondatum.space:
# Postfix (SMTP) + Dovecot (IMAP, LMTP delivery, Sieve) + OpenDKIM (signing)
# + SpamAssassin/spamass-milter (inbound filtering) + Roundcube (webmail via
# Caddy, which already fronts this host). Every component comes from Fedora's
# own dnf repos — deliberately chosen over Stalwart (not packaged at all,
# would need its own standalone update mechanism forever) once the VPS
# upgrade (2 CPU / 4GB RAM / 80GB, confirmed zero swap pressure) removed the
# original resource argument for a single-process alternative. See
# output/CENTAURI-playbook.md §13 L-42 and docs/library/framework_components/
# authentik/access-control.md for the fuller history (this started as
# "just make provision-user.sh --send work" and grew into this).
#
# *** THIS MUST BE RUN ON photondatum.space ITSELF, NOT on CENTAURI. ***
# It is additive to that host's existing Authentik/Caddy/Headscale/Forgejo
# setup and does not touch any of it except the one Caddyfile edit noted
# below (with a timestamped backup made first).
#
# What this script does NOT do (deliberately left as manual follow-up,
# printed at the end):
#   - Publish the SPF/DKIM/DMARC DNS TXT records it generates — you add
#     those in whatever DNS provider manages photondatum.space.
#   - Create any paid-member mailboxes beyond the one "invites@" address
#     needed for provision-user.sh's existing --send/--see-queue feature.
#     A companion scripts/add-mail-user.sh is the next piece to write for
#     that — intentionally not bundled into one-time infrastructure setup.
#   - Fill in the Podman secret (photondatum_smtp) provision-user.sh reads
#     on CENTAURI — that's a separate step once this is confirmed working.
#
# Usage (on photondatum.space):
#   sudo bash setup-photondatum-mailserver.sh
#
# Idempotent: every step either checks for its own prior completion first,
# or uses a tool (postconf -e, dnf install) that's already idempotent by
# design. Safe to re-run after fixing something it flagged.
#
# Exit codes:
#   0  Completed (see the printed summary for required manual DNS steps)
#   1  Safety check failed (not root, wrong host, missing a required tool)
#   2  A setup step failed — see the message immediately above

set -euo pipefail

# ---------------------------------------------------------------------------
# Safety checks
# ---------------------------------------------------------------------------
DOMAIN="photondatum.space"
MAIL_HOST="mail.${DOMAIN}"
DKIM_SELECTOR="mail"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: must be run as root — sudo bash $0" >&2
    exit 1
fi

actual_host="$(hostname -f 2>/dev/null || hostname)"
if [[ "$actual_host" != "photondatum"* ]]; then
    echo "ERROR: this host is '$actual_host', not photondatum.space." >&2
    echo "This script makes system-wide changes (Postfix/Dovecot/firewall/Caddyfile)" >&2
    echo "specific to that host — refusing to run anywhere else." >&2
    exit 1
fi

for cmd in dnf systemctl firewall-cmd caddy; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "ERROR: required command not found: $cmd" >&2
        exit 1
    fi
done

log() { echo; echo "=== $* ==="; }

# ---------------------------------------------------------------------------
# 1. Packages — everything from dnf, nothing hand-downloaded, so the normal
#    `dnf upgrade` this host already gets covers all of it going forward.
# ---------------------------------------------------------------------------
log "Installing packages"
dnf install -y \
    postfix dovecot dovecot-pigeonhole \
    opendkim opendkim-tools \
    spamassassin spamass-milter \
    roundcubemail \
    php php-fpm php-mbstring php-intl php-xml php-pdo php-pdo_sqlite php-gd php-zip \
    policycoreutils-python-utils sqlite

# ---------------------------------------------------------------------------
# 2. Firewall — mail ports only. The admin/management side of every
#    component here (Postfix/Dovecot config, Roundcube's own DB) stays on
#    this host; nothing new needs a public port beyond what mail itself
#    requires.
# ---------------------------------------------------------------------------
log "Opening firewall ports (25 smtp, 587 submission, 465 smtps, 993 imaps)"
firewall-cmd --permanent --add-service=smtp
firewall-cmd --permanent --add-port=587/tcp
firewall-cmd --permanent --add-port=465/tcp
firewall-cmd --permanent --add-service=imaps
firewall-cmd --reload

# ---------------------------------------------------------------------------
# 3. Virtual mailbox user + storage. A dedicated, unprivileged system
#    account owns every mailbox on disk — no real Unix account per mail
#    user, standard practice for a multi-user virtual-mailbox setup.
# ---------------------------------------------------------------------------
log "Creating vmail system user and mailbox storage"
VMAIL_UID=5000
VMAIL_GID=5000
VMAIL_HOME="/var/mail/vhosts"
if ! getent group vmail >/dev/null; then
    groupadd -g "$VMAIL_GID" vmail
fi
if ! getent passwd vmail >/dev/null; then
    useradd -u "$VMAIL_UID" -g vmail -d "$VMAIL_HOME" -s /sbin/nologin -m vmail
fi
mkdir -p "$VMAIL_HOME/$DOMAIN"
chown -R vmail:vmail "$VMAIL_HOME"
chmod -R 700 "$VMAIL_HOME"

# ---------------------------------------------------------------------------
# 4. TLS — reuse Caddy's own cert for mail.photondatum.space rather than
#    running a second, independent ACME client. Caddy already serves this
#    hostname over HTTPS (the placeholder site block), so it already holds
#    a valid cert in its own CertMagic storage. Caddy's storage is
#    0600/caddy:caddy and not meant to be read directly by other services,
#    so instead of loosening that, a small copy-and-reload script (run now,
#    and daily via a timer) mirrors the current cert/key into a
#    postfix+dovecot-readable location whenever it actually changes.
# ---------------------------------------------------------------------------
log "Setting up shared TLS cert (reusing Caddy's existing cert for ${MAIL_HOST})"
CADDY_CERT_DIR="$(find /var/lib/caddy -type d -iname "${MAIL_HOST}" 2>/dev/null | head -1)"
if [[ -z "$CADDY_CERT_DIR" ]]; then
    echo "WARNING: couldn't find an existing Caddy-managed cert for ${MAIL_HOST} under /var/lib/caddy." >&2
    echo "Postfix/Dovecot TLS will be left using Dovecot's self-signed default for now —" >&2
    echo "mail will still work, but clients will see a certificate warning until this is fixed." >&2
    CADDY_CERT_DIR=""
fi

SHARED_CERT_DIR="/etc/pki/mail-shared"
mkdir -p "$SHARED_CERT_DIR"
if ! getent group mailcert >/dev/null; then
    groupadd mailcert
fi
usermod -a -G mailcert postfix
usermod -a -G mailcert dovecot
chgrp mailcert "$SHARED_CERT_DIR"
chmod 750 "$SHARED_CERT_DIR"

cat > /usr/local/sbin/sync-mail-cert.sh <<SYNCEOF
#!/usr/bin/env bash
# Mirrors Caddy's current cert for ${MAIL_HOST} into ${SHARED_CERT_DIR},
# group-readable by postfix/dovecot, and reloads both only if it actually
# changed. Installed by setup-photondatum-mailserver.sh; run daily via
# sync-mail-cert.timer plus once now.
set -euo pipefail
src_dir="\$(find /var/lib/caddy -type d -iname '${MAIL_HOST}' 2>/dev/null | head -1)"
[[ -z "\$src_dir" ]] && exit 0
crt="\$(find "\$src_dir" -iname '*.crt' | head -1)"
key="\$(find "\$src_dir" -iname '*.key' | head -1)"
[[ -z "\$crt" || -z "\$key" ]] && exit 0
if ! cmp -s "\$crt" "${SHARED_CERT_DIR}/fullchain.pem" 2>/dev/null; then
    install -m 640 -o root -g mailcert "\$crt" "${SHARED_CERT_DIR}/fullchain.pem"
    install -m 640 -o root -g mailcert "\$key" "${SHARED_CERT_DIR}/privkey.pem"
    systemctl reload postfix dovecot 2>/dev/null || true
    logger -t sync-mail-cert "Updated ${MAIL_HOST} cert for postfix/dovecot"
fi
SYNCEOF
chmod 755 /usr/local/sbin/sync-mail-cert.sh

cat > /etc/systemd/system/sync-mail-cert.service <<'EOF'
[Unit]
Description=Sync Caddy's mail.photondatum.space cert for Postfix/Dovecot
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/sync-mail-cert.sh
EOF
cat > /etc/systemd/system/sync-mail-cert.timer <<'EOF'
[Unit]
Description=Daily sync of the shared mail TLS cert
[Timer]
OnCalendar=daily
Persistent=true
[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now sync-mail-cert.timer
/usr/local/sbin/sync-mail-cert.sh || true

# Whether to actually point Postfix/Dovecot at the shared cert, checked
# fresh here rather than trusted from the earlier CADDY_CERT_DIR warning —
# if Caddy genuinely hasn't issued one yet, both fall back to their own
# packaged self-signed defaults instead (Dovecot ships one automatically at
# /etc/pki/dovecot via mkcert.sh; Postfix with smtpd_tls_cert_file simply
# unset still runs, just without offering STARTTLS). Neither is a startup
# failure either way, and the daily timer upgrades both to the real cert —
# with an automatic reload — the moment it exists.
HAVE_SHARED_CERT=0
if [[ -f "${SHARED_CERT_DIR}/fullchain.pem" && -f "${SHARED_CERT_DIR}/privkey.pem" ]]; then
    HAVE_SHARED_CERT=1
fi

# ---------------------------------------------------------------------------
# 5. Postfix — inbound (25) + authenticated submission (587, 465), virtual
#    mailboxes handed off to Dovecot over LMTP (so Sieve filing into Junk
#    actually works — Postfix's own delivery agent isn't Sieve-aware),
#    OpenDKIM + spamass-milter as milters.
# ---------------------------------------------------------------------------
log "Configuring Postfix"
postconf -e "myhostname = ${MAIL_HOST}"
postconf -e "mydomain = ${DOMAIN}"
postconf -e "myorigin = \$mydomain"
postconf -e "inet_interfaces = all"
postconf -e "inet_protocols = ipv4, ipv6"
postconf -e "mydestination = localhost"
postconf -e "virtual_mailbox_domains = ${DOMAIN}"
postconf -e "virtual_mailbox_maps = hash:/etc/postfix/vmailbox"
postconf -e "virtual_alias_maps = hash:/etc/postfix/virtual"
postconf -e "virtual_transport = lmtp:unix:private/dovecot-lmtp"
postconf -e "smtpd_sasl_type = dovecot"
postconf -e "smtpd_sasl_path = private/auth"
postconf -e "smtpd_sasl_auth_enable = yes"
# Set unconditionally, even if the file doesn't exist yet (HAVE_SHARED_CERT
# checked below is for Dovecot, which behaves differently — see there).
# Postfix's smtpd_tls_security_level=may degrades gracefully if the
# referenced cert file is missing at startup: it logs a warning and
# disables STARTTLS rather than refusing to start, so this is genuinely
# self-healing once the daily sync timer actually creates the file and
# reloads postfix — no re-run of this script needed for Postfix's half.
postconf -e "smtpd_tls_cert_file = ${SHARED_CERT_DIR}/fullchain.pem"
postconf -e "smtpd_tls_key_file = ${SHARED_CERT_DIR}/privkey.pem"
postconf -e "smtpd_tls_security_level = may"
postconf -e "smtp_tls_security_level = may"
# Absolute unix: paths pointing at each milter's own packaged default
# socket location (/run/opendkim, /run/spamass-milter) -- NOT a custom
# location under the postfix queue dir as an earlier version of this
# script used. That seemed necessary assuming smtpd ran chrooted (which
# would make local: 's queue-dir-relative resolution the only way to reach
# a milter socket), but this host's master.cf ships chroot=n on every smtpd
# variant (confirmed directly), so smtpd can already reach any absolute
# path. The custom location actively broke things: confirmed via
# `ausearch -m avc` that dkim_milter_t/spamass_milter_t were both denied
# *search* on the postfix spool directory itself (postfix_spool_t) before
# ever reaching the relabeled subdirectory -- relabeling the leaf directory
# can't fix a denial one level up blocking entry to it at all. The default
# /run/* paths are pre-labeled correctly by the base policy for exactly
# this integration and don't need any custom SELinux work at all.
postconf -e "smtpd_milters = unix:/run/opendkim/opendkim.sock, unix:/run/spamass-milter/spamass-milter.sock"
postconf -e "non_smtpd_milters = \$smtpd_milters"
postconf -e "milter_default_action = accept"
postconf -e "milter_protocol = 6"

MARKER="# --- added by setup-photondatum-mailserver.sh ---"
if ! grep -qF "$MARKER" /etc/postfix/master.cf; then
    cat >> /etc/postfix/master.cf <<EOF

${MARKER}
submission inet n       -       n       -       -       smtpd
  -o syslog_name=postfix/submission
  -o smtpd_tls_security_level=encrypt
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING

smtps     inet  n       -       n       -       -       smtpd
  -o syslog_name=postfix/smtps
  -o smtpd_tls_wrappermode=yes
  -o smtpd_sasl_auth_enable=yes
  -o smtpd_reject_unlisted_recipient=no
  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
  -o milter_macro_daemon_name=ORIGINATING
EOF
fi

# One initial mailbox: invites@ — what provision-user.sh's --send already
# needs. Everything else (paid-member accounts) is a separate follow-up via
# the add-mail-user.sh companion script, not invented here.
if [[ ! -f /etc/postfix/vmailbox ]] || ! grep -q "^invites@${DOMAIN}" /etc/postfix/vmailbox 2>/dev/null; then
    echo "invites@${DOMAIN}    invites/" >> /etc/postfix/vmailbox
fi
touch /etc/postfix/virtual
postmap /etc/postfix/vmailbox
postmap /etc/postfix/virtual

# ---------------------------------------------------------------------------
# 6. OpenDKIM — signs outgoing mail. The generated public key (mail.txt)
#    is printed in the final summary for you to publish as a DNS TXT record.
# ---------------------------------------------------------------------------
log "Configuring OpenDKIM"
mkdir -p "/etc/opendkim/keys/${DOMAIN}"
if [[ ! -f "/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private" ]]; then
    opendkim-genkey -b 2048 -d "$DOMAIN" -s "$DKIM_SELECTOR" -D "/etc/opendkim/keys/${DOMAIN}"
fi
chown -R opendkim:opendkim "/etc/opendkim/keys/${DOMAIN}"
chmod 600 "/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private"

cat > /etc/opendkim/KeyTable <<EOF
${DKIM_SELECTOR}._domainkey.${DOMAIN} ${DOMAIN}:${DKIM_SELECTOR}:/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.private
EOF
cat > /etc/opendkim/SigningTable <<EOF
*@${DOMAIN} ${DKIM_SELECTOR}._domainkey.${DOMAIN}
EOF
cat > /etc/opendkim/TrustedHosts <<EOF
127.0.0.1
localhost
${DOMAIN}
*.${DOMAIN}
EOF

# Socket is explicitly reset to the package default (/run/opendkim/opendkim.sock
# -- confirmed correct and already properly SELinux-labeled by the base
# policy) rather than just left alone: an earlier version of this script
# pointed it at a custom path instead, and anyone who already ran that
# version has it sitting in /etc/opendkim.conf right now, which merely not
# touching this line would leave in place. Mode also changes (v -> sv, to
# actually sign outgoing mail, not just verify).
sed -i \
    -e 's/^Socket.*/Socket                  local:\/run\/opendkim\/opendkim.sock/' \
    -e 's/^#\?Mode.*/Mode                    sv/' \
    /etc/opendkim.conf
grep -q '^KeyTable' /etc/opendkim.conf || echo "KeyTable /etc/opendkim/KeyTable" >> /etc/opendkim.conf
grep -q '^SigningTable' /etc/opendkim.conf || echo "SigningTable /etc/opendkim/SigningTable" >> /etc/opendkim.conf
grep -q '^ExternalIgnoreList' /etc/opendkim.conf || echo "ExternalIgnoreList /etc/opendkim/TrustedHosts" >> /etc/opendkim.conf
grep -q '^InternalHosts' /etc/opendkim.conf || echo "InternalHosts /etc/opendkim/TrustedHosts" >> /etc/opendkim.conf
usermod -a -G opendkim postfix

# ---------------------------------------------------------------------------
# 7. Dovecot — IMAP (993), LMTP delivery (Sieve-aware, spam -> Junk later),
#    passwd-file virtual users, auth socket shared with Postfix.
# ---------------------------------------------------------------------------
log "Configuring Dovecot"
touch /etc/dovecot/users
chmod 640 /etc/dovecot/users
chgrp dovecot /etc/dovecot/users

# Fedora's dovecot package ships /etc/dovecot/dovecot.conf pre-populated
# with its own "minimal configuration file using system user authentication"
# template (its own comment, verbatim) -- including a default
# `passdb pam {}` / `userdb passwd {}` pair for real Unix accounts. That is
# a DIFFERENTLY NAMED block from the `passdb passwdfile {}` /
# `userdb static_vmail {}` pair this script adds in 99-local.conf below, and
# Dovecot does not let one named passdb/userdb block override another by
# purpose -- distinctly named blocks just accumulate as a list, evaluated in
# file order (dovecot.conf's own body first, conf.d/*.conf after, confirmed
# via `doveconf -P`). The default pam passdb harmlessly falls through on
# "user unknown" to reach ours (confirmed: `doveadm auth test` -- which only
# exercises the passdb/credential-check step -- succeeded every time,
# regardless of password, even while real logins kept failing). The
# default `userdb passwd {}` does NOT fall through the same way for a
# virtual user with no real Unix account: every actual IMAP LOGIN needs a
# successful userdb lookup too (to resolve mailbox uid/gid/home), and that
# one failed outright -- which is exactly why the password itself was never
# the problem (confirmed by testing with a password change: doveadm auth
# test kept succeeding, every real login kept 401'ing, identically before
# and after).
# Removed here rather than left in place: this host has no real Unix mail
# accounts at all, so the whole system-user template section is dead
# weight that actively conflicts with the virtual-mailbox design.
DOVECOT_CONF="/etc/dovecot/dovecot.conf"
cp "$DOVECOT_CONF" "${DOVECOT_CONF}.bak.$(date +%Y%m%d%H%M%S)"
python3 - "$DOVECOT_CONF" <<'PYEOF'
import re, sys
path = sys.argv[1]
with open(path) as f:
    content = f.read()
pattern = re.compile(
    r"# Authenticate as system users:\n"
    r"passdb pam \{\n\}\n"
    r"\n"
    r"userdb passwd \{\n\}\n"
    r"\n"
)
if pattern.search(content):
    content = pattern.sub("", content, count=1)
    with open(path, "w") as f:
        f.write(content)
    print(f"Removed the default system-user passdb/userdb block from {path}")
else:
    print(f"{path} already has no default system-user passdb/userdb block — nothing to do")
PYEOF

# Dovecot 2.4 (this is the 2.4.x generation, not legacy 2.3) changed its
# config syntax substantially from what's documented almost everywhere —
# mail_location split into mail_driver/mail_path, passdb/userdb now require
# a name, ssl_cert/ssl_key renamed to ssl_server_cert_file/ssl_server_key_file,
# and every file here now needs dovecot_config_version/dovecot_storage_version
# as literal first settings. None of this was guessed: found the first break
# the hard way (doveconf: "Unknown setting: mail_location" at actual runtime),
# then verified every single line below by testing it directly against this
# host's installed `doveconf` binary (dovecot_config_version 2.4.5) before
# writing it here — not trusted from any single blog post or AI-summarized
# doc page, several of which gave subtly different or SQL-backend-specific
# syntax that doesn't apply to this plain passwd-file setup.
# Hardcoded rather than self-detected: an earlier attempt at auto-detecting
# this via `doveconf -c /dev/null dovecot_config_version` killed the script
# outright under set -e — doveconf itself requires dovecot_config_version to
# be literally the first setting in any file it's given via -c, so querying
# against an empty /dev/null fails immediately, and that failure propagates
# through the command substitution before the "fall back to a default" logic
# below it ever gets a chance to run. Matches the Dovecot actually installed
# and tested against on this host (Fedora 43, dovecot-2.4.5) — if that ever
# changes, this needs a human to re-verify the config syntax again anyway,
# not a silent runtime auto-detect.
DOVECOT_VERSION="2.4.5"

cat > /etc/dovecot/conf.d/99-local.conf <<EOF
dovecot_config_version = ${DOVECOT_VERSION}
dovecot_storage_version = ${DOVECOT_VERSION}

mail_driver = maildir
mail_path = ${VMAIL_HOME}/%{user|domain}/%{user|username}
mail_uid = vmail
mail_gid = vmail
first_valid_uid = ${VMAIL_UID}
last_valid_uid = ${VMAIL_UID}

passdb passwdfile {
  driver = passwd-file
  passwd_file_path = /etc/dovecot/users
  default_password_scheme = SHA512-CRYPT
}
userdb static_vmail {
  driver = static
  fields {
    uid = vmail
    gid = vmail
    home = ${VMAIL_HOME}/%{user|domain}/%{user|username}
  }
}

service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}

service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}

protocol lmtp {
  mail_plugins = \$mail_plugins sieve
}
EOF

# Dovecot, unlike Postfix, does not tolerate ssl_server_cert_file/key_file
# pointing at a file that doesn't exist — with ssl=required it refuses to
# start at all, not a graceful degrade. Also unlike older Dovecot, 2.4 has
# NO compiled-in default cert path at all (verified: both settings resolve
# empty with nothing configured) — the self-signed cert/key the package
# ships via mkcert.sh still exist on disk, but Dovecot won't find them on
# its own anymore, so the "fall back to default" case has to point at them
# explicitly too, not just omit the setting as earlier versions allowed.
if [[ "$HAVE_SHARED_CERT" == "1" ]]; then
    cat >> /etc/dovecot/conf.d/99-local.conf <<EOF

ssl = required
ssl_server_cert_file = ${SHARED_CERT_DIR}/fullchain.pem
ssl_server_key_file = ${SHARED_CERT_DIR}/privkey.pem
EOF
else
    cat >> /etc/dovecot/conf.d/99-local.conf <<'EOF'

ssl = required
ssl_server_cert_file = /etc/pki/dovecot/certs/dovecot.pem
ssl_server_key_file = /etc/pki/dovecot/private/dovecot.pem
EOF
    echo "NOTE: no shared cert yet — Dovecot will use its own self-signed default for now." >&2
    echo "      Unlike Postfix, Dovecot needs this script re-run (not just time) once" >&2
    echo "      Caddy's real cert for ${MAIL_HOST} exists, to pick it up." >&2
fi

# ---------------------------------------------------------------------------
# 8. SpamAssassin + spamass-milter — tag only (adds X-Spam-* headers), never
#    hard-rejects at SMTP time. Actual filing into a Junk folder is a Sieve
#    rule, added once there's at least one real mailbox to attach it to
#    (the add-mail-user.sh follow-up, not here).
# ---------------------------------------------------------------------------
log "Configuring SpamAssassin + spamass-milter"
systemctl enable --now spamassassin
# Socket is left at its package default (/run/spamass-milter/spamass-milter.sock
# — confirmed auto-created via its own shipped tmpfiles.d rule, correctly
# SELinux-labeled by the base policy already) rather than a custom location
# under the postfix spool tree, which an earlier version of this script used
# and which broke: confirmed via `ausearch -m avc` that both this milter's
# and OpenDKIM's domains were denied *search* on the postfix spool directory
# itself, before ever reaching the custom subdirectory's own label. Only
# -g postfix is still needed here — it makes the milter's own socket
# group-writable by postfix (the documented, intended way to wire a non-root
# milter up to a non-root MTA), independent of where the socket lives.
# /etc/sysconfig/spamass-milter-postfix is a supported override file the
# shipped unit already reads (EnvironmentFile=-...) but doesn't ship a
# default for.
cat > /etc/sysconfig/spamass-milter-postfix <<'EOF'
EXTRA_FLAGS="-g postfix"
EOF
# -g postfix has spamass-milter chgrp its own socket to the postfix group —
# but it runs as the unprivileged sa-milt user, and an unprivileged owner can
# only change a file's group to one they're already a member of (confirmed:
# "group option, chown: Operation not permitted", exit 77/NOPERM, without
# this). Mirrors the same fix already applied the other direction for
# OpenDKIM (usermod -a -G opendkim postfix) above.
usermod -a -G postfix sa-milt

# ---------------------------------------------------------------------------
# 9. Roundcube — PHP-FPM pool + SQLite DB, Caddy fronting it at
#    mail.photondatum.space (replacing the placeholder static-site block
#    that's been there since before any of this).
# ---------------------------------------------------------------------------
log "Configuring Roundcube"
RC_DATA_DIR="/var/lib/roundcubemail"
mkdir -p "$RC_DATA_DIR"
RC_DB="${RC_DATA_DIR}/roundcube.db"

if [[ ! -f "$RC_DB" ]]; then
    RC_INIT_SQL="/usr/share/roundcubemail/SQL/sqlite.initial.sql"
    [[ -f "$RC_INIT_SQL" ]] || RC_INIT_SQL=""
    if [[ -n "$RC_INIT_SQL" ]]; then
        sqlite3 "$RC_DB" < "$RC_INIT_SQL"
    else
        echo "WARNING: could not find Roundcube's SQLite schema file — initialize ${RC_DB} manually." >&2
    fi
fi
chown -R apache:apache "$RC_DATA_DIR" 2>/dev/null || chown -R caddy:caddy "$RC_DATA_DIR"

# The package ships /var/lib/roundcubemail and /var/log/roundcubemail owned
# apache:apache mode 0770 (confirmed via a live install, not assumed), but
# the PHP-FPM pool below runs as user/group "caddy" (there's no reason to
# run httpd here at all — Caddy is the webserver). An unprivileged process
# can't read a 0770 dir it's not in the owning group for, so without this,
# php-fpm gets "Permission denied" opening roundcube.db and writing logs/temp.
# Group membership (rather than chowning the package's dirs to caddy:caddy)
# survives a package reinstall resetting ownership — same pattern already
# used for opendkim/postfix and sa-milt/postfix above.
usermod -a -G apache caddy

DES_KEY="$(openssl rand -base64 24)"
mkdir -p /etc/roundcubemail
cat > /etc/roundcubemail/config.inc.php <<EOF
<?php
\$config = [];
\$config['db_dsnw'] = 'sqlite:///${RC_DB}?mode=0640';
// Must be the hostname the TLS cert actually covers (mail.photondatum.space),
// NOT 127.0.0.1/localhost -- confirmed directly with a standalone PHP
// reproduction of exactly what rcube_imap_generic.php does internally
// (stream_socket_client + stream_socket_enable_crypto, no explicit SSL
// context since imap_conn_options isn't set): PHP enforces certificate
// hostname (subjectAltName) verification strictly by default on that call,
// and silently fails the STARTTLS upgrade for a loopback address with a
// cert issued for the real hostname -- "Peer certificate subjectAltName
// did not match expected name 127.0.0.1". Every login attempt failed at
// this step, before Roundcube ever got to send credentials, independent of
// the password -- which is why a manual openssl s_client STARTTLS test
// against 127.0.0.1 kept "succeeding" throughout debugging: unlike PHP, it
// does not enforce hostname verification unless explicitly told to, so it
// never caught this. Postfix's submission port (587, used for smtp_server
// below) serves the exact same certificate, so it has the identical
// requirement.
\$config['default_host'] = 'tls://${MAIL_HOST}';
\$config['default_port'] = 143;
\$config['smtp_server'] = 'tls://${MAIL_HOST}';
\$config['smtp_port'] = 587;
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
// Roundcube's OWN default session storage driver is 'db' (its SQLite
// database), NOT plain PHP file-based sessions -- confirmed by reading
// rcube.php directly: \$storage = \$this->config->get('session_storage', 'db').
// Every login attempt failed with "Invalid request! No data was saved."
// regardless of password, TLS fixes, or dovecot fixes, because of this --
// confirmed by writing a standalone diagnostic page that uses plain PHP
// sessions directly (bypassing Roundcube's framework) and proving THOSE
// persist perfectly (same session_id, same request_token, across separate
// requests) -- meaning the earlier session.save_path fix (for PHP's native
// file-based sessions) was real and necessary for other things, but never
// actually touched the code path Roundcube's login form depends on, since
// Roundcube wasn't using that mechanism at all by default. Forcing 'php'
// here switches Roundcube onto the exact mechanism just proven to work.
\$config['session_storage'] = 'php';
// Without this, rcmail::login() silently returns false for a mailbox's
// very FIRST login attempt even after a fully successful IMAP auth --
// confirmed by reading that method directly: if there's no existing row
// in Roundcube's OWN users table yet (nothing to do with Dovecot/virtual
// mailboxes at all) and auto_create_user isn't enabled, it logs "Access
// denied for new user ... 'auto_create_user' is disabled" and falls
// through to return false, which looks identical to a real credential
// failure ("Login failed.") from the outside. This is exactly why
// `doveadm auth test` and raw IMAP LOGIN tests kept succeeding with the
// real password while every real Roundcube login kept failing --
// those bypass Roundcube's own user database entirely, so they never
// exercised this check. Since Dovecot (not Roundcube) is the actual
// authority over mailbox accounts here, enabling this is the correct
// and standard configuration for any IMAP-backed Roundcube install, not
// a security tradeoff -- the real auth already happened against Dovecot
// before this check is ever reached.
\$config['auto_create_user'] = true;
\$config['support_url'] = '';
\$config['product_name'] = 'photondatum.space Mail';
\$config['des_key'] = '${DES_KEY}';
\$config['plugins'] = ['archive', 'zipdownload'];
\$config['skin'] = 'elastic';
EOF

cat > /etc/php-fpm.d/roundcube.conf <<'EOF'
[roundcube]
user = caddy
group = caddy
listen = /run/php-fpm/roundcube.sock
listen.owner = caddy
listen.group = caddy
pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3
; /etc/php.ini ships session.save_path commented out (confirmed on a live
; install), so without this PHP falls back to its compiled-in default --
; /tmp on this system -- which is SELinux type tmp_t. httpd_t (confirmed
; via `ps -eZ` to be what both Caddy and this pool run under) isn't allowed
; to write there by default policy, so sessions silently failed to persist
; between the Roundcube login page load and its POST, and the login form
; failed with "Invalid request! No data was sent." (no session == no valid
; request token). Fedora's own stock www.conf pool sets exactly this same
; override for exactly this reason -- mirroring it here rather than
; reinventing it. /var/lib/php/session is httpd_var_run_t, which httpd_t
; can read/write by default, and is group "apache" mode 0770 (confirmed),
; which the `usermod -a -G apache caddy` above already covers.
php_value[session.save_path] = /var/lib/php/session
EOF

# ---------------------------------------------------------------------------
# 10. Caddy — replace the mail.photondatum.space placeholder (static
#     file_server block) with a real php_fastcgi block for Roundcube.
#     Backed up first; only this one block is touched.
# ---------------------------------------------------------------------------
log "Updating Caddyfile for ${MAIL_HOST}"
CADDYFILE="/etc/caddy/Caddyfile"
cp "$CADDYFILE" "${CADDYFILE}.bak.$(date +%Y%m%d%H%M%S)"

python3 - "$CADDYFILE" "$MAIL_HOST" <<'PYEOF'
import re, sys
path, host = sys.argv[1], sys.argv[2]
with open(path) as f:
    content = f.read()
# Whitespace-tolerant: the live Caddyfile uses tabs, not the 4-space
# indentation an earlier version of this matched literally against (which
# silently failed — found when actually run, not assumed). Match any
# leading whitespace on the two inner lines instead of a fixed indent style.
new = f"{host} {{\n\troot * /usr/share/roundcubemail/public_html\n\tphp_fastcgi unix//run/php-fpm/roundcube.sock\n\tfile_server\n}}\n"
# Two possible prior states to migrate from: the original static placeholder
# this block replaces the first time the script ever runs, or (self-heal)
# an earlier buggy version of THIS script's own output that pointed root at
# /var/www/roundcube -- a path the roundcubemail dnf package never creates
# (it installs to /usr/share/roundcubemail/public_html; confirmed against
# the live package's file list, not assumed) which silently 404'd every
# request. Matching both keeps re-running the script self-correcting
# instead of silently no-op'ing against an already-wrong live file.
placeholder = re.compile(
    re.escape(host) + r" \{\n"
    r"[ \t]*root \* /var/www/photondatum\n"
    r"[ \t]*file_server\n"
    r"\}\n?"
)
buggy_root = re.compile(
    re.escape(host) + r" \{\n"
    r"[ \t]*root \* /var/www/roundcube\n"
    r"[ \t]*php_fastcgi unix//run/php-fpm/roundcube\.sock\n"
    r"[ \t]*file_server\n"
    r"\}\n?"
)
if placeholder.search(content):
    content = placeholder.sub(new, content, count=1)
elif buggy_root.search(content):
    content = buggy_root.sub(new, content, count=1)
    print(f"Fixed {host}'s block in {path} (was pointing root at the wrong path)")
elif new in content:
    print(f"{host}'s block in {path} is already up to date — nothing to do")
    sys.exit(0)
else:
    print(f"WARNING: expected placeholder block for {host} not found — Caddyfile left unchanged, edit it by hand.", file=sys.stderr)
    sys.exit(0)
with open(path, "w") as f:
    f.write(content)
print(f"Updated {host}'s block in {path}")
PYEOF

caddy validate --config "$CADDYFILE" --adapter caddyfile

# ---------------------------------------------------------------------------
# 11. SELinux — Caddy and the Roundcube PHP-FPM pool both run under httpd_t
#     (confirmed via `ps -eZ` against a live install, not assumed), which
#     already has httpd_can_network_connect on. The real Roundcube docroot
#     is /usr/share/roundcubemail/public_html (confirmed via `rpm -ql
#     roundcubemail` -- an earlier version of this script relabeled
#     /var/www/roundcube instead, a path the package never creates, which
#     did nothing). Its "plugins" and "skins" entries are symlinks out to
#     /usr/share/roundcubemail/{plugins,skins}, so the whole package tree
#     needs the content type, not just public_html itself. The package's
#     own /var/lib/roundcubemail (httpd_var_lib_t) and /var/log/roundcubemail
#     (httpd_log_t) already carry the correct SELinux types out of the box
#     for an httpd_t process to manage -- confirmed via `ls -Z` -- so only
#     DAC (the usermod -a -G apache caddy above) was missing for those, not
#     a relabel.
# ---------------------------------------------------------------------------
log "Applying SELinux contexts"
semanage fcontext -a -t httpd_sys_content_t "/usr/share/roundcubemail(/.*)?" 2>/dev/null || true
restorecon -Rv /usr/share/roundcubemail >/dev/null 2>&1 || true
restorecon -Rv /var/lib/roundcubemail /var/log/roundcubemail >/dev/null 2>&1 || true
# opendkim and spamass-milter use their own packaged default socket
# locations (/run/opendkim, /run/spamass-milter) -- already correctly
# SELinux-labeled by the base policy, nothing to add here. An earlier
# version of this script moved them under /var/spool/postfix/... instead
# (for Postfix's local: milter addressing) and relabeled just those
# subdirectories, which didn't work: `ausearch -m avc` showed both daemons'
# domains denied *search* on the postfix spool directory itself
# (postfix_spool_t) before ever reaching the relabeled subdirectory --
# that denial is one level up from anything a leaf-directory relabel can
# fix. Confirmed separately that Postfix's smtpd doesn't run chrooded on
# this host, so there was never a reason to move the sockets in the first
# place; using unix:/run/.../*.sock (absolute paths) in smtpd_milters
# instead fixed this at the root rather than fighting the policy further.
# Roundcube talks to Postfix/Dovecot over TCP (127.0.0.1:587/143), not by
# invoking a local sendmail binary, so httpd_can_sendmail isn't the relevant
# boolean here — httpd_can_network_connect (confirmed already "on" on this
# host before this script ever ran) is. Not setting anything new for this;
# if Roundcube can't reach either port after everything's started, check
# `ausearch -m avc -ts recent` for a denial before assuming it's a firewall
# or Postfix/Dovecot config issue — PHP-FPM's exact SELinux domain wasn't
# verified against a live install, so this is the one piece of the whole
# setup not confirmed end-to-end ahead of time.

# ---------------------------------------------------------------------------
# 12. Enable and start everything
# ---------------------------------------------------------------------------
log "Enabling and starting services"
systemctl enable --now opendkim
systemctl enable --now spamass-milter
systemctl enable --now dovecot
systemctl enable --now postfix
systemctl enable --now php-fpm
# A plain `enable --now` is a no-op on an already-running service, but a
# supplementary group added via `usermod -a -G` above only takes effect for
# NEW processes -- an already-running php-fpm wouldn't pick up caddy's new
# apache group membership without this (confirmed: that's exactly what left
# Roundcube unable to open its own SQLite db/logs/temp on a prior run).
systemctl restart php-fpm
systemctl reload caddy

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
log "Done — manual steps required"
if [[ "$HAVE_SHARED_CERT" == "0" ]]; then
    echo "*** Dovecot is using its own self-signed cert, not Caddy's real one yet —"
    echo "    re-run this script once Caddy has issued a cert for ${MAIL_HOST}"
    echo "    to fix that (Postfix will pick it up on its own via the daily timer;"
    echo "    Dovecot specifically needs a re-run). ***"
    echo
fi
echo "1. Publish these DNS TXT records for ${DOMAIN}:"
echo
echo "   SPF  (name: ${DOMAIN}):"
echo "     v=spf1 mx -all"
echo
echo "   DKIM (name: ${DKIM_SELECTOR}._domainkey.${DOMAIN}):"
cat "/etc/opendkim/keys/${DOMAIN}/${DKIM_SELECTOR}.txt" 2>/dev/null | sed 's/^/     /'
echo
echo "   DMARC (name: _dmarc.${DOMAIN}):"
echo "     v=DMARC1; p=none; rua=mailto:invites@${DOMAIN}"
echo
echo "2. Set a password for the initial invites@${DOMAIN} mailbox:"
echo "     doveadm pw -s SHA512-CRYPT"
echo "   then add a line to /etc/dovecot/users:"
echo "     invites@${DOMAIN}:<hash from above>"
echo
echo "3. Test: visit https://${MAIL_HOST}/ for Roundcube, log in as invites@${DOMAIN}."
echo
echo "4. Fill in CENTAURI's photondatum_smtp Podman secret once this is confirmed working:"
echo "     echo '{\"host\":\"${MAIL_HOST}\",\"port\":587,\"username\":\"invites@${DOMAIN}\",\"password\":\"...\",\"from\":\"invites@${DOMAIN}\"}' | podman secret create photondatum_smtp -"
echo
echo "Paid-member mailboxes beyond invites@ are a separate follow-up (add-mail-user.sh, not yet written)."
