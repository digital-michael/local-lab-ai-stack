# Headscale Installation Guide — Fedora 42+

**Summary:** Step-by-step installation and configuration guide for running Headscale as a self-hosted WireGuard mesh coordination server on a Fedora 42+ Linode Nanode. Covers the full lifecycle: binary install, DERP relay, Caddy reverse proxy, node enrollment (controller + workers), script integration, Authentik OIDC, and ACL enforcement. Written for the llm-agent-local-2 AI stack.

**Last Updated:** 2026-04-16
**Headscale Version:** v0.28.0 (released 2026-02-04)
**Minimum Tailscale Client:** v1.74.0
**Target OS:** Fedora 42+ (Linode Nanode)
**Status:** Phase 0 steps 0.1–0.7 complete · Phase 0.8+ pending

> **Companion document:** `docs/wip/headscale-proposal.md` — architecture, ACL design, risk assessment, and migration rationale.

---

## Table of Contents

1. [Prerequisites](#1-prerequisites)
2. [Phase 0 — Linode Nanode Setup](#2-phase-0--linode-nanode-setup)
   - [0.1 Create and Provision the Nanode](#01-create-and-provision-the-nanode)
   - [0.2 Initial System Update](#02-initial-system-update)
   - [0.3 SSH Hardening](#03-ssh-hardening)
   - [0.4 Firewall Configuration](#04-firewall-configuration)
   - [0.5 Install Headscale Binary](#05-install-headscale-binary)
   - [0.6 Headscale System User and Directories](#06-headscale-system-user-and-directories)
   - [0.7 Install Caddy](#07-install-caddy)
   - [0.8 Install derper (DERP Relay)](#08-install-derper-derp-relay)
   - [0.9 Configure Headscale](#09-configure-headscale)
   - [0.10 Install Headscale systemd Service](#010-install-headscale-systemd-service)
   - [0.11 Configure Caddy](#011-configure-caddy)
   - [0.12 Configure DERP Map](#012-configure-derp-map)
   - [0.13 Configure DNS Records](#013-configure-dns-records)
   - [0.14 Start and Verify All Services](#014-start-and-verify-all-services)
3. [Phase 1 — Controller Enrollment (CENTAURI)](#3-phase-1--controller-enrollment-centauri)
4. [Phase 2 — Worker Enrollment](#4-phase-2--worker-enrollment)
5. [Phase 3 — Script Updates](#5-phase-3--script-updates)
6. [Phase 4 — Authentik OIDC Integration](#6-phase-4--authentik-oidc-integration)
7. [Phase 5 — ACL Enforcement](#7-phase-5--acl-enforcement)
8. [Phase 6 — Cutover and Validation](#8-phase-6--cutover-and-validation)
9. [Verification Reference](#9-verification-reference)
10. [Troubleshooting](#10-troubleshooting)
11. [References](#11-references)

---

## 1. Prerequisites

### 1.1 Accounts and Services

| Item | Details |
|---|---|
| Linode (Akamai) account | https://www.linode.com/ · Credit card required |
| Domain name | Registered and DNS managed (Cloudflare recommended) |
| SSH key pair | Already generated on your local machine |

### 1.2 Local Tools

```bash
# Verify these are available on your workstation before starting
ssh --version
curl --version
dig yourdomain.com        # part of bind-utils / dnsutils
```

### 1.3 Environment Variables

Set these once in your terminal before running any Phase 0 commands. All scripts in this guide reference these variables — do not skip this step.

```bash
# ── Set these before running any Phase 0 commands ──────────────────────────
DOMAIN="yourdomain.com"           # your registered domain (e.g. photondatum.space)
LINODE_IP="172.105.x.x"           # Nanode public IPv4 (from Linode dashboard)
ADMIN_USER="admin"                # non-root admin user created in §0.3
SSH_PUBKEY="ssh-ed25519 AAAA..."  # content of ~/.ssh/id_ed25519.pub on your workstation
CONTROLLER_IP="100.64.0.1"        # tailnet IP assigned to CENTAURI (confirm after §1.3)
HEADSCALE_VERSION="0.28.0"        # update this when upgrading
# ───────────────────────────────────────────────────────────────────────────
```

> Re-export these in any new SSH session before continuing. Paste them into `~/.bashrc` on the Linode to persist across sessions.

---

## 2. Phase 0 — Linode Nanode Setup

> **Runs as:** `root` on the Linode for all steps in this phase, unless noted otherwise.
> SSH in with `ssh root@${LINODE_IP}` after provisioning.

### 0.1 Create and Provision the Nanode

In the Linode Cloud Manager:

1. Click **Create → Linode**
2. Choose the following:

| Setting | Value |
|---|---|
| **Distribution** | Fedora 42 (or latest available) |
| **Region** | Closest to your home (e.g., `us-east`, `us-southeast`) |
| **Plan** | Nanode 1GB — 1 vCPU / 1 GB RAM / 25 GB SSD |
| **Label** | `headscale-relay` (or similar) |
| **Root password** | Set a strong password (used only for emergency console access) |
| **SSH Keys** | Add your public key |

3. Click **Create Linode** and wait for the status to reach **Running**.
4. Note the public IPv4 address (`<linode-ip>`).

**Verify:**

```bash
# From your local machine
ssh root@<linode-ip> 'hostname && uname -r'
# Expected: linode hostname + Fedora kernel version
```

---

### 0.2 Initial System Update

```bash
# Connect to the Linode
ssh root@${LINODE_IP}

# Full system update
dnf upgrade -y

# Install essential tools
dnf install -y curl wget vim git fail2ban firewalld
```

**Verify:**

```bash
systemctl status firewalld --no-pager
# Expected: active (running) or inactive (will be started in §0.4)
```

---

### 0.3 SSH Hardening

```bash
# Create a non-root admin user (recommended)
useradd -m -G wheel ${ADMIN_USER}
passwd ${ADMIN_USER}

# Add your SSH public key to the admin user
mkdir -p /home/${ADMIN_USER}/.ssh
echo "${SSH_PUBKEY}" > /home/${ADMIN_USER}/.ssh/authorized_keys
chmod 700 /home/${ADMIN_USER}/.ssh
chmod 600 /home/${ADMIN_USER}/.ssh/authorized_keys
chown -R ${ADMIN_USER}:${ADMIN_USER} /home/${ADMIN_USER}/.ssh

# Harden sshd
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Enable fail2ban
systemctl enable --now fail2ban
```

**Verify — open a NEW terminal before closing the current session:**

```bash
# Confirm key-based login works for the admin user
ssh ${ADMIN_USER}@${LINODE_IP} 'whoami'
# Expected: admin (or whatever ADMIN_USER is set to)

# Confirm root login is blocked
ssh root@${LINODE_IP} 'whoami'
# Expected: Permission denied (publickey)
```

---

### 0.4 Firewall Configuration

Fedora uses `firewalld`, not `ufw`. The following opens the required ports:

| Port | Protocol | Purpose |
|---|---|---|
| 80 | TCP | HTTP (Let's Encrypt challenges via Caddy) |
| 443 | TCP | HTTPS (Caddy public entry point, Headscale, DERP over TLS) |
| 41641 | UDP | WireGuard / DERP STUN NAT traversal |

```bash
# Start and enable firewalld if not already running
systemctl enable --now firewalld

# Open required services and ports
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=41641/udp

# Apply changes
firewall-cmd --reload
```

**Verify:**

```bash
firewall-cmd --list-all
# Expected (relevant lines):
#   services: cockpit dhcpv6-client http https ssh
#   ports: 41641/udp
```

---

### 0.5 Install Headscale Binary

> **Note:** The binary filename includes the version number. A URL missing the version (e.g., `headscale_linux_amd64`) will return a 404.
> `HEADSCALE_VERSION` must be set from §1.3 before running these commands.

```bash
# Download the versioned binary
curl -LO "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"

# Install to /usr/local/bin
install -m 755 "headscale_${HEADSCALE_VERSION}_linux_amd64" /usr/local/bin/headscale

# Clean up the download
rm "headscale_${HEADSCALE_VERSION}_linux_amd64"
```

**Verify:**

```bash
headscale version
# Expected: headscale version 0.28.0 ...
```

> **Alternative — build from source (Podman, no host footprint):**
> If the binary is unavailable or you prefer to build:
> ```bash
> # Requires git and Podman (Fedora ships Podman by default)
> git clone https://github.com/juanfont/headscale.git
> cd headscale
> podman run --rm -v "$PWD":/build:z -w /build docker.io/golang:1.26 go build -o ./headscale-bin ./cmd/headscale
> sudo install -m 755 headscale-bin /usr/local/bin/headscale
> cd .. && rm -rf headscale
> ```

---

### 0.6 Headscale System User and Directories

Running Headscale under a dedicated unprivileged user follows the principle of least privilege.

```bash
# Create headscale system user (no interactive login)
useradd \
  --create-home \
  --home-dir /var/lib/headscale/ \
  --system \
  --user-group \
  --shell /usr/sbin/nologin \
  headscale

# Create runtime and config directories
mkdir -p /etc/headscale
mkdir -p /var/run/headscale
chown headscale:headscale /var/run/headscale
```

**Verify:**

```bash
id headscale
# Expected: uid=... gid=... groups=...(headscale)

ls -ld /var/lib/headscale /etc/headscale /var/run/headscale
# Expected: all three directories exist with correct ownership
```

---

### 0.7 Install Caddy

Caddy is not in the default Fedora repositories. Install it from the official Caddy COPR:

```bash
# Install dnf-plugins-core if not already present
dnf install -y dnf-plugins-core

# Enable the Caddy COPR repository
dnf copr enable @caddy/caddy -y

# Install Caddy
dnf install -y caddy

# Enable but do NOT start yet — config file must be written first
systemctl enable caddy
```

**Verify:**

```bash
caddy version
# Expected: v2.x.x ...

systemctl is-enabled caddy
# Expected: enabled
```

---

### 0.8 Install derper (DERP Relay)

derper is the Tailscale DERP relay binary. Fedora's system Go (installed via `dnf install golang`) ships Go 1.25.x, but derper requires Go 1.26.1+. The `GOTOOLCHAIN=auto` environment variable allows Go to download and use the correct version automatically — nothing is installed system-wide.

```bash
# Install system Go if not already present (needed as the bootstrap toolchain)
dnf install -y golang

# Install derper — GOTOOLCHAIN=auto downloads Go 1.26.1 into ~/sdk/ automatically
GOTOOLCHAIN=auto go install tailscale.com/cmd/derper@latest

# Locate and install the binary (path depends on which user ran go install)
DERPER_BIN=$(find /root /home -name derper -path "*/go/bin/derper" 2>/dev/null | head -1)
install -m 755 "$DERPER_BIN" /usr/local/bin/derper

# Fix ownership — the binary may be owned by the non-root user who ran go install
chown root:root /usr/local/bin/derper

# Restore the correct SELinux context — required on Fedora (SELinux enforcing by default).
# Binaries originating from home directories carry the wrong label (user_home_t) and
# will fail under systemd (status=203/EXEC) even though they run fine in a shell.
restorecon -v /usr/local/bin/derper
```

**Verify:**

```bash
derper --version
# Expected: 1.96.x-... (version string)
ls -laZ /usr/local/bin/derper
# Expected: -rwxr-xr-x. 1 root root ... unconfined_u:object_r:bin_t:s0 ...
```

> **Why not just `go install` directly?**
> With `GOTOOLCHAIN=local` (the default), Go refuses to build a module that requires a newer Go version. `GOTOOLCHAIN=auto` enables automatic toolchain switching. The downloaded SDK lives in `~/sdk/go1.26.x/` and is used only when needed. It does not replace the system Go.

---

### 0.9 Configure Headscale

> `DOMAIN` must be set from §1.3 before running these commands.

```bash
# Write config — uses ${DOMAIN} from environment (unquoted EOF enables expansion)
cat > /etc/headscale/config.yaml << EOF
# Headscale configuration — generated by installer

server_url: https://headscale.${DOMAIN}
listen_addr: 127.0.0.1:8080
metrics_listen_addr: 127.0.0.1:9090

# Keys — auto-generated on first run
private_key_path: /var/lib/headscale/private.key
noise:
  private_key_path: /var/lib/headscale/noise_private.key

# IP address space for the tailnet
prefixes:
  v4: 100.64.0.0/10
  v6: fd7a:115c:a1e0::/48

# DERP — use our self-hosted relay; disable the built-in server
derp:
  server:
    enabled: false
  urls: []
  paths:
    - /etc/headscale/derp.yaml
  auto_update_enabled: false

# DNS / MagicDNS
dns:
  magic_dns: true
  base_domain: tailnet.${DOMAIN}
  nameservers:
    global:
      - 1.1.1.1
      - 8.8.8.8

# Database (SQLite — sufficient for small deployments)
# NOTE: v0.28.0 uses a nested "database:" block. The old flat db_type/db_path keys are silently ignored.
database:
  type: sqlite
  sqlite:
    path: /var/lib/headscale/db.sqlite

# ACL policy (applied in Phase 5)
# NOTE: "acl_policy_path" was removed in v0.23+. Use "policy.path" instead.
policy:
  path: /etc/headscale/acl.json

# Unix socket — must be writable by the headscale user
unix_socket: /var/run/headscale/headscale.sock
unix_socket_permission: "0770"

# OIDC — Authentik integration (configured in Phase 4)
# Uncomment and fill in after Authentik OAuth2 provider is created.
# oidc:
#   issuer: "https://auth.${DOMAIN}/application/o/headscale/"
#   client_id: "headscale"
#   client_secret_path: /etc/headscale/oidc_secret
#   scope: ["openid", "profile", "email"]
#   allowed_groups:
#     - "ai-stack-operators"
#     - "ai-stack-users"

# Logging
log:
  level: info
EOF

# Create a minimal ACL policy with tag ownership declared
# Tags must be defined in tagOwners before they can be applied to nodes (Phase 1+).
# Empty array [] = tag is valid but only the headscale CLI admin can apply it (not self-claimed by clients).
# NOTE: autogroup:admin is a Tailscale cloud concept — headscale v0.28.0 does not support it.
# The wide-open acl rule is replaced with role-based rules in Phase 5.
cat > /etc/headscale/acl.json << 'EOF'
{
  "tagOwners": {
    "tag:controller": [],
    "tag:inference":  [],
    "tag:knowledge":  []
  },
  "acls": [
    {
      "action": "accept",
      "src": ["*"],
      "dst": ["*:*"]
    }
  ]
}
EOF

# Lock down permissions
chown -R headscale:headscale /etc/headscale
chmod 640 /etc/headscale/config.yaml
chmod 640 /etc/headscale/acl.json
```

**Verify:**

```bash
# Confirm domain substitution worked correctly
grep "server_url" /etc/headscale/config.yaml
# Expected: server_url: https://headscale.yourdomain.com  (with your real domain)

headscale --config /etc/headscale/config.yaml version
# Expected: prints version with no config errors
```

---

### 0.10 Install Headscale systemd Service

```bash
cat > /etc/systemd/system/headscale.service << 'EOF'
[Unit]
Description=headscale coordination server
After=network.target syslog.target

[Service]
Type=simple
User=headscale
Group=headscale
ExecStart=/usr/local/bin/headscale serve
Restart=always
RestartSec=5

# Hardening
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ReadWritePaths=/var/lib/headscale /var/run/headscale /etc/headscale
ProtectHome=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable headscale
```

---

### 0.11 Configure Caddy

> `DOMAIN` and `CONTROLLER_IP` must be set from §1.3 before running these commands.
> `CONTROLLER_IP` defaults to `100.64.0.1` — confirm after CENTAURI is enrolled in Phase 1.

```bash
# Write Caddyfile — uses ${DOMAIN} and ${CONTROLLER_IP} from environment
cat > /etc/caddy/Caddyfile << EOF
# Public AI Stack entry point — proxies to CENTAURI via WireGuard tunnel
chat.${DOMAIN} {
    reverse_proxy ${CONTROLLER_IP}:443 {
        transport http {
            # Traefik on CENTAURI uses a self-signed cert internally
            tls_insecure_skip_verify
        }
    }

    handle_errors {
        respond "AI Stack is currently offline. Services will resume when the controller comes back online." 503
    }
}

# Headscale coordination server (API + registration UI)
headscale.${DOMAIN} {
    reverse_proxy 127.0.0.1:8080
}

# DERP relay
derp.${DOMAIN} {
    reverse_proxy 127.0.0.1:3478
}
EOF

# Caddy requires tab indentation; heredocs may produce spaces — format in place
caddy fmt --overwrite /etc/caddy/Caddyfile
```

**Verify:**

```bash
# Confirm domain substitution worked
grep "${DOMAIN}" /etc/caddy/Caddyfile
# Expected: three lines with your domain (chat, headscale, derp)

caddy validate --config /etc/caddy/Caddyfile
# Expected: Valid configuration (no warnings)
```

---

### 0.12 Configure DERP Map

> `DOMAIN` must be set from §1.3 before running these commands.

```bash
cat > /etc/headscale/derp.yaml << EOF
regions:
  900:
    regionid: 900
    regioncode: "self"
    regionname: "Self-Hosted"
    nodes:
      - name: "derp-linode"
        regionid: 900
        hostname: "derp.${DOMAIN}"
        stunport: 3478
        stunonly: false
        derpport: 443
EOF

chown headscale:headscale /etc/headscale/derp.yaml
chmod 640 /etc/headscale/derp.yaml
```

**Verify:**

```bash
grep hostname /etc/headscale/derp.yaml
# Expected: hostname: derp.yourdomain.com  (with your real domain)
```

---

### 0.13 Configure DNS Records

All records point to the same Linode IP. Add them at whichever provider manages your domain's DNS.

| Hostname | Type | Value | TTL |
|---|---|---|---|
| `headscale.yourdomain.com` | A | `<linode-ip>` | 300 |
| `chat.yourdomain.com` | A | `<linode-ip>` | 300 |
| `derp.yourdomain.com` | A | `<linode-ip>` | 300 |
| `auth.yourdomain.com` | A | `<linode-ip>` | 300 |
| `grafana.yourdomain.com` | A | `<linode-ip>` | 300 (optional) |

**If using Linode DNS Manager** (SOA shows `ns1.linode.com`):
1. Linode Cloud Manager → **Domains** → click your domain
2. Click **Add an A/AAAA Record** for each hostname above
3. Set the IP to your Nanode's public IPv4 and TTL to 300
4. Save — Linode DNS typically propagates within 1–2 minutes

**If using Cloudflare:**
1. Cloudflare dashboard → your domain → **DNS → Records → Add record**
2. Type: A, Name: `headscale` (etc.), IPv4: `<linode-ip>`, TTL: Auto, Proxy: **DNS only** (grey cloud — do NOT proxy Headscale/DERP)
3. Repeat for each hostname

> To check which provider manages your DNS: `dig yourdomain.com NS +short` — if it returns `ns1.linode.com`, use Linode DNS Manager.

**Verify DNS propagation (run from your local machine or the Linode):**

```bash
dig headscale.yourdomain.com +short   # should return <linode-ip>
dig chat.yourdomain.com +short        # should return <linode-ip>
dig derp.yourdomain.com +short        # should return <linode-ip>
```

> Do not proceed to §0.14 until all records resolve correctly — Caddy's Let's Encrypt certificate issuance depends on DNS being live.

---

### 0.14 Start and Verify All Services

> `DOMAIN` must be set from §1.3 before running these commands.
> DNS records from §0.13 must resolve before starting Caddy — Caddy fetches Let's Encrypt certs on first start.

**Create a systemd unit for derper:**

```bash
mkdir -p /var/lib/derper/certs

cat > /etc/systemd/system/derper.service << EOF
[Unit]
Description=Tailscale DERP relay
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/derper \\
  --hostname=derp.${DOMAIN} \\
  --certmode=letsencrypt \\
  --certdir=/var/lib/derper/certs \\
  --a=:3478 \\
  --stun
Restart=always
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
```

**Start all services:**

```bash
# Start Headscale
systemctl enable --now headscale

# Start derper
systemctl enable --now derper

# Start Caddy last (requires DNS to be live for Let's Encrypt)
systemctl enable --now caddy
```

**Verify — check each service individually:**

```bash
systemctl status headscale --no-pager
# Expected: active (running) — no FATAL lines in output
```

```bash
systemctl status derper --no-pager
# Expected: active (running)
# Look for: "STUN server listening on [::]:3478"
```

```bash
systemctl status caddy --no-pager
# Expected: active (running)
# Note: cert issuance may take 30–60 seconds on first start
```

**End-to-end Phase 0 verification:**

```bash
curl -s https://headscale.${DOMAIN}/health
# Expected: {"status":"pass"}
```

```bash
curl -I https://chat.${DOMAIN}
# Expected: HTTP 502 or 503 — CENTAURI not yet enrolled; this is correct at this stage
```

```bash
curl -I https://derp.${DOMAIN}
# Expected: HTTP 200 with DERP server info in body
```

```bash
headscale nodes list
# Expected: empty table (no nodes enrolled yet)
```

---

## 3. Phase 1 — Controller Enrollment (CENTAURI)

> Steps alternate between machines. Each step is labelled with where it runs.

### 1.1 Install Tailscale Client on CENTAURI (Fedora)

> **Runs as:** `sudo` / wheel user on **CENTAURI** (your home controller).

```bash
# Add Tailscale repository
curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
  | sudo tee /etc/yum.repos.d/tailscale.repo

sudo dnf install -y tailscale

# Enable and start the Tailscale daemon
sudo systemctl enable --now tailscaled
```

**Verify:**

```bash
tailscale version
# Expected: version string

systemctl is-active tailscaled
# Expected: active
```

### 1.2 Generate a Pre-Auth Key for CENTAURI

> **Runs as:** `root` on the **Linode**.
> `DOMAIN` must be set (see §1.3 of Prerequisites).

```bash
# Create a headscale user for the operator (run once; skip if already exists)
headscale users create operator

# Look up the numeric user ID — v0.28.0 requires an ID, not a name
headscale users list
# Note the ID column value for "operator" (e.g. 1)

# Generate a single-use pre-auth key using the numeric ID
headscale preauthkeys create --user <ID> --expiration 24h
# Save the key value — used in the next step on CENTAURI
```

> **v0.28.0 change:** `--user` accepts a numeric user ID only, not a username string.
> Use `headscale users list` to find the ID before running `preauthkeys create`.

**Verify:**

```bash
headscale preauthkeys list
# Expected: one key listed, not yet used, not expired
```

### 1.3 Join CENTAURI to the Tailnet

> **Runs as:** `sudo` / wheel user on **CENTAURI**.
> `DOMAIN` must be set from the Prerequisites env vars.

> **One control plane at a time.** `tailscaled` maintains exactly one active control-plane connection. Enrolling in Headscale replaces any existing Tailscale (cloud) enrollment on the same node — they cannot coexist simultaneously. If CENTAURI is currently enrolled in Tailscale and you want to preserve that registration for later, back it up first (see below).

**Optional — preserve an existing Tailscale enrollment before switching:**

```bash
# On CENTAURI — save current state
tailscale status --json > ~/tailscale-backup-$(date +%Y%m%d).json
tailscale ip -4 > ~/tailscale-ip-backup.txt

# Note your current login server (usually https://controlplane.tailscale.com)
tailscale debug prefs | grep ControlURL
```

To restore to Tailscale cloud later:

```bash
sudo tailscale up --login-server https://controlplane.tailscale.com
# You will be prompted to re-authenticate via browser
# The node will re-appear in your Tailscale admin panel (same machine key, same device)
```

> The machine key is preserved on disk (`/var/lib/tailscale/tailscaled.state`). The Tailscale node entry in the cloud admin panel is merely deactivated while the node is pointed elsewhere — re-enrolling restores it.

**Enroll in Headscale:**

```bash
# Replace <preauth-key> with the key output from §1.2
# IMPORTANT: HEADSCALE_URL must include the https:// scheme.
# Tailscale's error output sometimes suggests --login-server without https:// — do not use that form.
HEADSCALE_URL="https://headscale.${DOMAIN}"
PREAUTH_KEY="<preauth-key>"

sudo tailscale up \
  --login-server ${HEADSCALE_URL} \
  --authkey ${PREAUTH_KEY} \
  --reset \
  --force-reauth
```

> **`--reset` + `--force-reauth` are both required** when the node has an existing active Tailscale authentication (e.g. previously enrolled in Tailscale cloud). `--reset` clears prior non-default flags (like `--ssh`); `--force-reauth` is required specifically because an authenticated session is already present — tailscale refuses to change `--login-server` without it. On a fresh node with no prior enrollment, neither flag is needed. Tailscale SSH (`--ssh`) is a cloud-only feature and has no effect under Headscale.
>
> **If `tailscale up` hangs silently with no output:** the most likely cause is a missing `https://` prefix on `--login-server`. Tailscale's own error-recovery suggestion sometimes omits the scheme — always use the full `https://` URL.

**Verify on CENTAURI:**

```bash
tailscale ip -4
# Expected: 100.64.x.x

tailscale status
# Expected: node listed as connected
```

**Verify on the Linode:**

```bash
headscale nodes list
# Expected: centauri row with 100.64.x.x IP and "online" status
```

> **Note the IP assigned to CENTAURI.** Update `CONTROLLER_IP` in your env vars if it differs from `100.64.0.1`, then update the Caddyfile: `sed -i "s|100.64.0.1|${CONTROLLER_IP}|g" /etc/caddy/Caddyfile && systemctl reload caddy`

### 1.4 Apply Device Tag to CENTAURI

> **Runs as:** `root` on the **Linode**.

```bash
# Get the node ID from the list
headscale nodes list

# Apply the controller tag (replace <node-id> with the ID shown above)
headscale nodes tag --identifier <node-id> --tags tag:controller
```

**Verify:**

```bash
headscale nodes list
# Expected: centauri row shows tag:controller
```

### 1.5 Verify Caddy → CENTAURI Path

> **Runs as:** any user on your **local workstation**.

```bash
curl -I https://chat.${DOMAIN}
# Expected: HTTP 200 (OpenWebUI) or the Traefik auth redirect
# HTTP 502/503 means CENTAURI is enrolled but Traefik is not yet reachable — check that the AI stack is running on CENTAURI
```

### 1.6 Set Networking Mode in config.json

> **Runs as:** yourself on your **development machine**, from the repo root directory (`llm-agent-local-2/`).

```bash
cd /path/to/llm-agent-local-2   # skip if already there

jq '.networking.mode = "headscale"' configs/config.json > /tmp/cfg.json && mv /tmp/cfg.json configs/config.json
```

**Verify:**

```bash
jq '.networking.mode' configs/config.json
# Expected: "headscale"
```

---

## 4. Phase 2 — Worker Enrollment

> For each worker: generate a pre-auth key on the Linode, enroll the worker, apply the tag. Repeat per node.
> `DOMAIN` must be set in your shell on each machine before running enrollment commands.

### 2.1 TC25 — macOS (M1)

> **Generate key:** `root` on the **Linode**.

```bash
# Look up operator user ID if needed: headscale users list
headscale preauthkeys create --user <ID> --expiration 24h
# Save the key for the next step
```

> **Enroll:** wheel user on **TC25**.

```bash
HEADSCALE_URL="https://headscale.${DOMAIN}"

brew install tailscale

sudo tailscale up \
  --login-server ${HEADSCALE_URL} \
  --authkey <preauth-key-for-tc25>
```

**Verify on TC25:**

```bash
tailscale ip -4
# Expected: 100.64.x.x
```

> **Tag:** `root` on the **Linode**.

```bash
headscale nodes list   # note tc25 node ID
headscale nodes tag --identifier <tc25-node-id> --tags tag:inference
```

**Verify heartbeat from TC25:**

```bash
bash scripts/heartbeat.sh
# Expected: HTTP 200, no TLS errors (WireGuard provides encryption — --insecure not needed)
```

### 2.2 SOL — Fedora Linux

> **Generate key:** `root` on the **Linode**.

```bash
# Look up operator user ID if needed: headscale users list
headscale preauthkeys create --user <ID> --expiration 24h
# Save the key for the next step
```

> **Enroll:** `sudo` / wheel user on **SOL**.

```bash
HEADSCALE_URL="https://headscale.${DOMAIN}"

curl -fsSL https://pkgs.tailscale.com/stable/fedora/tailscale.repo \
  | sudo tee /etc/yum.repos.d/tailscale.repo

sudo dnf install -y tailscale
sudo systemctl enable --now tailscaled

sudo tailscale up \
  --login-server ${HEADSCALE_URL} \
  --authkey <preauth-key-for-sol>
```

**Verify on SOL:**

```bash
tailscale ip -4
# Expected: 100.64.x.x
```

> **Tag:** `root` on the **Linode**.

```bash
headscale nodes list   # note sol node ID
headscale nodes tag --identifier <sol-node-id> --tags tag:inference
```

### 2.3 CENTAURI-node (Knowledge Worker, Same Host)

CENTAURI-node runs on the same physical machine as CENTAURI and already has the Tailscale daemon running from Phase 1. Only a tag needs to be applied.

> **Runs as:** `root` on the **Linode**.

```bash
headscale nodes list   # note centauri-node ID
headscale nodes tag --identifier <centauri-node-id> --tags tag:knowledge
```

**Verify all workers — from the Linode:**

```bash
headscale nodes list
# Expected: centauri (tag:controller), tc25 (tag:inference), sol (tag:inference), centauri-node (tag:knowledge)
```

**Verify mesh connectivity — from CENTAURI:**

```bash
tailscale ping tc25
# Expected: pong from 100.64.x.x in Xms

tailscale ping sol
# Expected: pong from 100.64.x.x in Xms
```

---

## 5. Phase 3 — Script Updates

All script changes are made in the repo on your development machine and deployed to nodes.

### 3.1 Add `_resolve_controller_url()` to shared helpers

In the relevant scripts, add this helper function. It reads `configs/config.json` and returns the appropriate controller URL based on networking mode:

```bash
_resolve_controller_url() {
    local mode
    mode=$(jq -r '.networking.mode' "${CONFIG_FILE:-configs/config.json}")
    case "$mode" in
        local)
            jq -r '.controller_url' "$NODE_FILE"
            ;;
        headscale|tailscale)
            local ts_name
            ts_name=$(jq -r ".networking.modes.$mode.controller_tailnet_name" "${CONFIG_FILE:-configs/config.json}")
            echo "https://${ts_name}"
            ;;
        *)
            echo "ERROR: Unknown networking mode: $mode" >&2
            return 1
            ;;
    esac
}
```

### 3.2 Update `heartbeat.sh`

- Replace hardcoded `controller_url` with `_resolve_controller_url()`
- Remove `--insecure` from all `curl` invocations

**Verify:** `bash scripts/heartbeat.sh` succeeds from all workers without TLS errors.

### 3.3 Update `configure.sh generate-join-token`

Add a step that calls `headscale preauthkeys create` and bundles the pre-auth key into the join token output.

**Verify:** The join token output includes both the KI API key and the Headscale pre-auth key.

### 3.4 Update `bootstrap.sh`

Add Tailscale client installation as an early step for both Linux (Fedora `dnf`) and macOS (`brew`).

**Verify:** Fresh bootstrap on a test node completes end-to-end and the node appears in `headscale nodes list`.

### 3.5 Update `diagnose.sh`

Add `_check_tailscale_status()` function:

```bash
_check_tailscale_status() {
    if ! command -v tailscale &>/dev/null; then
        echo "[FAIL] tailscale not installed"
        return 1
    fi
    local state
    state=$(tailscale status --json 2>/dev/null | jq -r '.BackendState')
    case "$state" in
        Running)     echo "[OK]   Tailscale: connected" ;;
        Starting)    echo "[WARN] Tailscale: starting up" ;;
        NeedsLogin)  echo "[FAIL] Tailscale: needs login — run 'tailscale up'" ;;
        *)           echo "[FAIL] Tailscale: unknown state: $state" ;;
    esac
}
```

### 3.6 Update `status.sh`

Add a tailnet connectivity row to the status output using `tailscale status --json`.

### 3.7 Update `node.sh join`

Add `tailscale up --login-server ... --authkey <key>` as a step in the join subcommand flow, so a single `node.sh join` command enrolls the node in both the KI and the WireGuard mesh.

---

## 6. Phase 4 — Authentik OIDC Integration

> Prerequisite: Authentik is running and accessible at `https://auth.yourdomain.com`.

### 4.1 Create OAuth2 Provider in Authentik

1. Log into Authentik admin UI
2. Go to **Applications → Providers → Create**
3. Select **OAuth2/OpenID Provider**
4. Configure:
   - **Name:** `headscale`
   - **Client type:** Confidential
   - **Redirect URIs:** `https://headscale.yourdomain.com/oidc/callback`
   - **Scopes:** `openid`, `profile`, `email`
5. Note the **Client ID** and **Client Secret**

### 4.2 Create Authentik Application

1. Go to **Applications → Applications → Create**
2. Link it to the `headscale` provider created above
3. Set **Launch URL** to `https://headscale.yourdomain.com`

### 4.3 Enable OIDC in Headscale config

On the Linode, store the OIDC secret securely, then update the config:

```bash
# Store the OIDC client secret (from Authentik provider) in a file
echo -n "<client-secret-from-authentik>" > /etc/headscale/oidc_secret
chown headscale:headscale /etc/headscale/oidc_secret
chmod 600 /etc/headscale/oidc_secret
```

Uncomment and fill in the `oidc:` block in `/etc/headscale/config.yaml`:

```yaml
oidc:
  issuer: "https://auth.yourdomain.com/application/o/headscale/"
  client_id: "headscale"
  client_secret_path: /etc/headscale/oidc_secret
  scope: ["openid", "profile", "email"]
  allowed_groups:
    - "ai-stack-operators"
    - "ai-stack-users"
```

```bash
systemctl restart headscale
systemctl status headscale --no-pager
```

### 4.4 Test User Self-Registration

```bash
# Generate a user-facing login URL
headscale --config /etc/headscale/config.yaml nodes register --user <new-user>

# Open the URL in a browser → redirects to Authentik → authenticate → device registered
# Verify registration:
headscale nodes list
```

---

## 7. Phase 5 — ACL Enforcement

### 5.1 Deploy the ACL Policy

Write the ACL policy file. Update `user1`, `user2`, `user3` with your actual Headscale usernames:

```bash
cat > /etc/headscale/acl.json << 'EOF'
{
  "groups": {
    "group:operators": ["user1"],
    "group:inference-users": ["user2", "user3"],
    "group:knowledge-users": ["user2"]
  },
  "tagOwners": {
    "tag:controller": ["group:operators"],
    "tag:services":   ["group:operators"],
    "tag:inference":  ["group:operators"],
    "tag:knowledge":  ["group:operators"],
    "tag:personal":   ["group:operators", "group:inference-users", "group:knowledge-users"],
    "tag:relay":      ["group:operators"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["group:operators"],
      "dst": ["*:*"],
      "comment": "Operators: full access to everything"
    },
    {
      "action": "accept",
      "src": ["group:inference-users", "tag:personal"],
      "dst": ["tag:controller:443", "tag:controller:80"],
      "comment": "Inference users: HTTPS to controller"
    },
    {
      "action": "accept",
      "src": ["group:knowledge-users", "tag:personal"],
      "dst": ["tag:controller:443", "tag:controller:80", "tag:knowledge:8100"],
      "comment": "Knowledge users: HTTPS + KI API"
    },
    {
      "action": "accept",
      "src": ["tag:inference"],
      "dst": ["tag:controller:443"],
      "comment": "Workers: heartbeat to controller"
    },
    {
      "action": "accept",
      "src": ["tag:controller"],
      "dst": ["tag:inference:11434"],
      "comment": "Controller: route inference to worker Ollama"
    },
    {
      "action": "accept",
      "src": ["tag:relay"],
      "dst": ["tag:controller:443"],
      "comment": "Linode Caddy: proxy to controller Traefik"
    }
  ]
}
EOF

chown headscale:headscale /etc/headscale/acl.json
chmod 640 /etc/headscale/acl.json
systemctl restart headscale
```

### 5.2 Verify ACL Enforcement

```bash
# Operator access — should reach all services
tailscale ping tc25      # expect pong
tailscale ping sol       # expect pong

# Worker heartbeat — should succeed over mesh
# (run from TC25 or SOL)
bash scripts/heartbeat.sh

# Worker-to-worker lateral — should be blocked (no ACL rule)
# (run from TC25, targeting SOL's tailnet IP)
curl -v http://100.64.0.3:11434    # expect connection refused / timeout
```

---

## 8. Phase 6 — Cutover and Validation

### 6.1 Remove `--insecure` Flags

```bash
# Verify no --insecure flags remain in scripts
grep -r '\-\-insecure' scripts/
# Expected: no output
```

### 6.2 Update controller_url State Files on Workers

On each worker node, update the state file to use the MagicDNS name:

```bash
# Run on each worker (TC25, SOL)
AI_STACK_CONFIG="${HOME}/.config/ai-stack/state.json"
jq '.controller_url = "https://centauri.tailnet.yourdomain.com"' "$AI_STACK_CONFIG" \
  > /tmp/state.json && mv /tmp/state.json "$AI_STACK_CONFIG"
```

### 6.3 Verify Offline Fallback

```bash
# Power off or stop Traefik on CENTAURI temporarily
# Then from your local machine:
curl -I https://chat.yourdomain.com
# Expected: HTTP 503 with the offline message body
```

### 6.4 Verify Roaming

Take TC25 to a different network (mobile hotspot, coffee shop WiFi). Within ~60 seconds:

```bash
# On TC25 — after network change
tailscale status
# Expected: connected (may briefly show "reconnecting")

bash scripts/heartbeat.sh
# Expected: HTTP 200 — heartbeat resumes without intervention
```

### 6.5 Full Diagnostic

```bash
# On CENTAURI
bash scripts/diagnose.sh --full
# Expected: all checks pass, Tailscale status shows "connected"
```

### 6.6 Run Full Test Suite

```bash
# In the repo
make test-all
# Expected: no regressions
```

---

## 9. Verification Reference

Quick-reference verification commands organized by component.

### Headscale (Linode)

```bash
headscale version
systemctl is-active headscale           # active
headscale nodes list                    # lists all enrolled nodes
headscale preauthkeys list              # lists outstanding pre-auth keys
curl -s https://headscale.yourdomain.com/health   # {"status":"pass"}
journalctl -u headscale -n 50 --no-pager
```

### Caddy (Linode)

```bash
caddy version
systemctl is-active caddy              # active
caddy validate --config /etc/caddy/Caddyfile
curl -I https://chat.yourdomain.com    # HTTP 200 (when CENTAURI enrolled) or 503 (offline)
journalctl -u caddy -n 50 --no-pager
```

### derper (Linode)

```bash
systemctl is-active derper             # active
curl -I https://derp.yourdomain.com    # HTTP 200
journalctl -u derper -n 50 --no-pager
```

### Firewall (Linode)

```bash
firewall-cmd --list-all
# Must show: services: http https, ports: 41641/udp
```

### Tailscale Client (any node)

```bash
tailscale version
tailscale status                       # shows all mesh nodes + connection state
tailscale ip -4                        # shows this node's 100.64.x.x address
tailscale ping <other-node-name>       # confirms direct WireGuard or DERP relay path
tailscale netcheck                     # diagnoses NAT type and DERP reachability
```

### DNS (from local machine)

```bash
dig headscale.yourdomain.com +short    # returns <linode-ip>
dig chat.yourdomain.com +short         # returns <linode-ip>
dig derp.yourdomain.com +short         # returns <linode-ip>
```

---

## 10. Troubleshooting

### Binary download returns 404

**Symptom:** `curl` or `wget` gets a 404 when downloading the Headscale binary.

**Cause:** The binary filename **must include the version number**. The URL pattern `headscale_linux_amd64` (without version) does not exist.

**Fix:**
```bash
HEADSCALE_VERSION="0.28.0"
curl -LO "https://github.com/juanfont/headscale/releases/download/v${HEADSCALE_VERSION}/headscale_${HEADSCALE_VERSION}_linux_amd64"
```

---

### `go install` fails: requires go >= 1.26.1 (running go 1.25.x)

**Symptom:**
```
go: tailscale.com/cmd/derper@latest: tailscale.com@v1.96.x requires go >= 1.26.1 (running go 1.25.x; GOTOOLCHAIN=local)
```

**Cause:** Fedora's `golang` package ships Go 1.25.x. The `GOTOOLCHAIN=local` default prevents automatic toolchain download.

**Fix:** Prefix the install command with `GOTOOLCHAIN=auto`:
```bash
GOTOOLCHAIN=auto go install tailscale.com/cmd/derper@latest
```
Go downloads Go 1.26.1 into `~/sdk/go1.26.x/` automatically. The system Go is not replaced.

---

### derper binary not found after `go install`

**Symptom:** `mv: cannot stat '/home/<username>/go/bin/derper': No such file or directory`

**Cause:** The binary was installed with a different `$HOME` (e.g., root's home vs. the logged-in user's home), or `go install` failed silently.

**Fix:** Use `find` to locate the binary regardless of which user ran `go install`, then install it properly:
```bash
DERPER_BIN=$(find /root /home -name derper -path "*/go/bin/derper" 2>/dev/null | head -1)
install -m 755 "$DERPER_BIN" /usr/local/bin/derper
/usr/local/bin/derper --version   # confirm executable
systemctl restart derper
```

---

### derper starts manually but fails under systemd (status=203/EXEC, SELinux)

**Symptom:** The binary runs fine from the shell but `systemctl start derper` gives `status=203/EXEC`.

**Cause:** Fedora runs SELinux in enforcing mode. A binary moved or copied from a home directory retains a `user_home_t` label. systemd's confined exec path rejects it; a regular shell does not.

**Fix:**
```bash
# Check the current label
ls -laZ /usr/local/bin/derper
# Wrong:   unconfined_u:object_r:user_home_t:s0
# Correct: unconfined_u:object_r:bin_t:s0

# Fix ownership if not root:root
chown root:root /usr/local/bin/derper

# Restore the correct SELinux label
restorecon -v /usr/local/bin/derper

# Restart
systemctl restart derper
systemctl status derper --no-pager
# Expected: active (running)
```

---

### Headscale fails to start — tag command returns "invalid or not permitted" / "Invalid Owner autogroup:admin"

**Symptom 1 — tag command rejected:**
```
Error while sending tags to headscale: rpc error: code = InvalidArgument desc = requested tags [tag:controller] are invalid or not permitted
```
**Cause:** The tag is not declared in `tagOwners` in `acl.json`. Tags must be defined before they can be applied.

**Symptom 2 — headscale crashes after adding tagOwners with `autogroup:admin`:**
```
FTL Error initializing error="...Invalid Owner \"autogroup:admin\". An alias must be one of the following types:
- user (containing an "@")
- group (starting with "group:")
- tag (starting with "tag:")
```
**Cause:** `autogroup:admin` is a Tailscale cloud concept. Headscale v0.28.0's policy parser does not recognise it.

**Fix — use empty arrays in `tagOwners`:** An empty array means the tag is valid but only the headscale CLI admin can apply it (nodes cannot self-claim the tag):
```bash
systemctl stop headscale

cat > /etc/headscale/acl.json << 'EOF'
{
  "tagOwners": {
    "tag:controller": [],
    "tag:inference":  [],
    "tag:knowledge":  []
  },
  "acls": [
    {
      "action": "accept",
      "src": ["*"],
      "dst": ["*:*"]
    }
  ]
}
EOF

systemctl start headscale
headscale nodes tag --identifier <node-id> --tags tag:controller
```

---

### Headscale fails to start — invalid database type ""

**Symptom:** `journalctl -u headscale` shows:
```
FTL invalid database type "", must be sqlite, sqlite3 or postgres
```

**Cause:** Headscale v0.28.0 moved database config from flat top-level keys (`db_type`, `db_path`) to a nested `database:` block. The old keys are silently ignored, so headscale reads the type as an empty string.

**Fix:**
```bash
systemctl stop headscale

# Remove old flat keys
sed -i '/^db_type:/d' /etc/headscale/config.yaml
sed -i '/^db_path:/d' /etc/headscale/config.yaml

# Insert correct nested block before the policy: section
sed -i '/^policy:/i database:\n  type: sqlite\n  sqlite:\n    path: /var/lib/headscale/db.sqlite\n' /etc/headscale/config.yaml

# Verify
grep -A 4 "^database:" /etc/headscale/config.yaml
# Expected:
# database:
#   type: sqlite
#   sqlite:
#     path: /var/lib/headscale/db.sqlite

systemctl start headscale
systemctl status headscale --no-pager
```

---

### Headscale fails to start — FATAL: acl_policy_path deprecated

**Symptom:** `journalctl -u headscale` shows:
```
FATAL: The "acl_policy_path" configuration key is deprecated. Please use "policy.path" instead. "acl_policy_path" has been removed.
```

**Cause:** The `acl_policy_path` top-level key was removed in Headscale v0.23+. The config in §0.9 uses the correct `policy.path` form, but if you have an older config or copy-pasted from another source, the old key may be present.

**Fix:**
```bash
# Replace the old key with the new nested form
sed -i 's/^acl_policy_path: \(.*\)/policy:\n  path: \1/' /etc/headscale/config.yaml

# Verify
grep -A1 "^policy:" /etc/headscale/config.yaml
# Expected:
# policy:
#   path: /etc/headscale/acl.json

systemctl restart headscale
systemctl status headscale --no-pager
```

---

### Headscale fails to start

**Symptom:** `systemctl status headscale` shows `failed` or exits immediately.

**Diagnose:**
```bash
journalctl -u headscale -n 100 --no-pager
headscale --config /etc/headscale/config.yaml serve   # run in foreground to see errors
```

**Common causes:**
- `/var/run/headscale/` directory does not exist or wrong ownership → `mkdir -p /var/run/headscale && chown headscale:headscale /var/run/headscale`
- YAML syntax error in `config.yaml` → validate with `python3 -c "import yaml; yaml.safe_load(open('/etc/headscale/config.yaml'))"`
- Port 8080 already in use → `ss -tlnp | grep 8080`

---

### Caddy fails to obtain Let's Encrypt certificate

**Symptom:** `journalctl -u caddy` shows ACME challenge failures.

**Diagnose:**
```bash
# Confirm port 80 and 443 are reachable from the internet
curl -v http://headscale.yourdomain.com    # must reach Caddy
# Confirm DNS resolves to the Linode IP
dig headscale.yourdomain.com +short
```

**Common causes:**
- Firewall not opened → re-run firewall-cmd steps in §0.4
- DNS not propagated yet → wait and retry; use `dig @1.1.1.1` to check Cloudflare directly
- Port 80 blocked by Linode firewall rules (check Linode Cloud Firewall if enabled separately)

---

### Node fails to join the tailnet

**Symptom:** `tailscale up` hangs silently with no output, or `headscale nodes list` shows the node as `disconnected`.

**Diagnose:**
```bash
tailscale status        # shows backend state
tailscale netcheck      # checks DERP and STUN reachability
journalctl -u tailscaled -n 50 --no-pager
```

**Common causes:**

**`tailscale up` hangs silently — missing `https://` scheme:**
The most common cause of a silent hang when switching to Headscale. Tailscale's own error-recovery output sometimes suggests `--login-server=headscale.yourdomain.com` (no scheme). Without `https://`, tailscale cannot connect to Caddy and blocks indefinitely.
```bash
# Wrong — will hang
sudo tailscale up --login-server headscale.photondatum.space ...

# Correct — always include https://
sudo tailscale up --login-server https://headscale.photondatum.space ...
```

**Certs not yet issued:**
If Caddy only just obtained Let's Encrypt certs, the first `tailscale up` attempt may hang. Wait 30–60 seconds and retry. Confirm certs are live: `curl -sv https://headscale.yourdomain.com/health`.

**Pre-auth key expired:** generate a new one: `headscale preauthkeys create --user <ID> --expiration 24h`

**Previously enrolled node requires extra flags:** add `--reset --force-reauth` when switching from another control plane.

**Tailscale daemon not running:** `systemctl start tailscaled`

**UDP 41641 blocked:** `tailscale netcheck` will report "no direct connections"; DERP relay should still work via TCP 443.

---

### Heartbeat fails from worker after mesh enrollment

**Symptom:** `heartbeat.sh` returns a TLS error or connection refused after switching to headscale mode.

**Diagnose:**
```bash
# On the worker
tailscale status          # confirm connected
tailscale ping centauri   # confirm direct or relay path to controller
curl -v https://centauri.tailnet.yourdomain.com/admin/v1/heartbeat
```

**Common causes:**
- `controller_url` state file still points to old LAN address → update to MagicDNS name (§6.2)
- `--insecure` was removed but Traefik cert isn't trusted → this is expected and correct; WireGuard provides transport encryption; the Traefik cert is only used for the internal hop
- ACL not allowing heartbeat traffic → check `tag:inference` → `tag:controller:443` rule in `acl.json`

---

### DERP relay not working (nodes can't connect at all)

**Symptom:** `tailscale netcheck` shows no DERP regions reachable. Nodes fail to communicate.

**Diagnose:**
```bash
# On the Linode
systemctl status derper --no-pager
journalctl -u derper -n 50 --no-pager
curl -I https://derp.yourdomain.com    # should return 200 with DERP info

# On a node
tailscale netcheck
# Look for: "derp.yourdomain.com: ... ms" — any latency value means it's reachable
```

**Common causes:**
- `derp.yourdomain.com` DNS not propagated yet
- derper certificate not yet issued (takes a minute on first start)
- Port 3478/UDP not open — note: DERP over TLS uses port 443 (already open), so 3478/UDP is for STUN only; DERP connectivity should still work via TCP 443

---

## 11. References

| Resource | URL |
|---|---|
| Headscale GitHub | https://github.com/juanfont/headscale |
| Headscale documentation (stable) | https://headscale.net/stable/ |
| Headscale install — official releases | https://headscale.net/stable/setup/install/official/ |
| Headscale configuration reference | https://headscale.net/stable/ref/configuration/ |
| Headscale ACL documentation | https://headscale.net/stable/ref/acls/ |
| Headscale OIDC documentation | https://headscale.net/stable/ref/oidc/ |
| Headscale DERP documentation | https://headscale.net/stable/ref/derp/ |
| Headscale v0.28.0 release notes | https://github.com/juanfont/headscale/releases/tag/v0.28.0 |
| Tailscale documentation (concepts) | https://tailscale.com/kb |
| WireGuard protocol | https://www.wireguard.com/ |
| Caddy web server | https://caddyserver.com/docs/ |
| Caddy COPR for Fedora | https://copr.fedorainfracloud.org/coprs/g/caddy/caddy/ |
| derper (Go package docs) | https://pkg.go.dev/tailscale.com/cmd/derper |
| Go GOTOOLCHAIN documentation | https://go.dev/doc/toolchain |
| Headscale-UI (optional web admin) | https://github.com/gurucomputing/headscale-ui |
| Authentik OAuth2/OIDC provider docs | https://docs.goauthentik.io/docs/add-secure-apps/providers/oauth2/ |
| Linode (Akamai) pricing | https://www.linode.com/pricing/ |
| Cloudflare Registrar | https://www.cloudflare.com/products/registrar/ |
| Let's Encrypt | https://letsencrypt.org/ |
| Architecture proposal | `docs/wip/headscale-proposal.md` |

---

*This guide is structured for sequential execution. Each phase gate depends on the previous phase completing successfully. Verification commands are provided at every step — do not skip them.*
