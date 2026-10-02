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
    opendkim \
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
    useradd -r -u "$VMAIL_UID" -g vmail -d "$VMAIL_HOME" -s /sbin/nologin -m vmail
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
postconf -e "smtpd_milters = local:opendkim/opendkim.sock, local:spamass/spamass.sock"
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

mkdir -p /var/spool/postfix/opendkim
chown opendkim:postfix /var/spool/postfix/opendkim
sed -i \
    -e 's/^Socket.*/Socket                  local:\/var\/spool\/postfix\/opendkim\/opendkim.sock/' \
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

cat > /etc/dovecot/conf.d/99-local.conf <<EOF
mail_location = maildir:${VMAIL_HOME}/%d/%n
mail_uid = vmail
mail_gid = vmail
first_valid_uid = ${VMAIL_UID}
last_valid_uid = ${VMAIL_UID}

passdb {
  driver = passwd-file
  args = scheme=SHA512-CRYPT username_format=%u /etc/dovecot/users
}
userdb {
  driver = static
  args = uid=vmail gid=vmail home=${VMAIL_HOME}/%d/%n
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

# Dovecot, unlike Postfix, does not tolerate ssl_cert/ssl_key pointing at a
# file that doesn't exist — with ssl=required it refuses to start at all,
# not a graceful degrade. So this part genuinely can't be set unconditionally:
# if the shared cert isn't there yet, leave Dovecot on its own packaged
# self-signed default (ships automatically via mkcert.sh, always present)
# and note in the final summary that THIS script needs a re-run once the
# real cert exists — the daily timer alone won't fix Dovecot's half, only
# Postfix's.
if [[ "$HAVE_SHARED_CERT" == "1" ]]; then
    cat >> /etc/dovecot/conf.d/99-local.conf <<EOF

ssl = required
ssl_cert = <${SHARED_CERT_DIR}/fullchain.pem
ssl_key = <${SHARED_CERT_DIR}/privkey.pem
EOF
else
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
mkdir -p /var/spool/postfix/spamass
# spamass-milter runs as the unprivileged 'sa-milt' user (confirmed from its
# own shipped unit file, not a guess) — it needs write access to create the
# socket; -g postfix (below) then makes that socket itself group-writable
# by postfix, which is the documented, intended way to wire this milter up
# to an MTA that doesn't run as root, rather than hand-chmod'ing it here.
chown sa-milt:postfix /var/spool/postfix/spamass
chmod 750 /var/spool/postfix/spamass
# /etc/sysconfig/spamass-milter-postfix is a supported override file the
# shipped unit already reads (EnvironmentFile=-...) but doesn't ship a
# default for — writing it fresh here, rather than sed-patching the main
# /etc/sysconfig/spamass-milter (which ships SOCKET/EXTRA_FLAGS commented
# out, so a naive sed replace on an already-uncommented pattern would
# silently match nothing).
cat > /etc/sysconfig/spamass-milter-postfix <<'EOF'
SOCKET=/var/spool/postfix/spamass/spamass.sock
EXTRA_FLAGS="-g postfix"
EOF

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

DES_KEY="$(openssl rand -base64 24)"
mkdir -p /etc/roundcubemail
cat > /etc/roundcubemail/config.inc.php <<EOF
<?php
\$config = [];
\$config['db_dsnw'] = 'sqlite:///${RC_DB}?mode=0640';
\$config['default_host'] = 'tls://127.0.0.1';
\$config['default_port'] = 143;
\$config['smtp_server'] = 'tls://127.0.0.1';
\$config['smtp_port'] = 587;
\$config['smtp_user'] = '%u';
\$config['smtp_pass'] = '%p';
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
old = f"""{host} {{
    root * /var/www/photondatum
    file_server
}}"""
new = f"""{host} {{
    root * /var/www/roundcube
    php_fastcgi unix//run/php-fpm/roundcube.sock
    file_server
}}"""
if old not in content:
    print(f"WARNING: expected placeholder block for {host} not found verbatim — Caddyfile left unchanged, edit it by hand.", file=sys.stderr)
    sys.exit(0)
content = content.replace(old, new)
with open(path, "w") as f:
    f.write(content)
print(f"Updated {host}'s block in {path}")
PYEOF

caddy validate --config "$CADDYFILE" --adapter caddyfile

# ---------------------------------------------------------------------------
# 11. SELinux — Caddy runs under httpd_t (confirmed), which already has
#     httpd_can_network_connect on; the roundcube docroot and PHP-FPM socket
#     need the standard httpd contexts so that still applies under
#     enforcing mode.
# ---------------------------------------------------------------------------
log "Applying SELinux contexts"
semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/roundcube/logs(/.*)?" 2>/dev/null || true
semanage fcontext -a -t httpd_sys_rw_content_t "/var/www/roundcube/temp(/.*)?" 2>/dev/null || true
semanage fcontext -a -t httpd_sys_content_t "/var/www/roundcube(/.*)?" 2>/dev/null || true
restorecon -Rv /var/www/roundcube >/dev/null 2>&1 || true
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
