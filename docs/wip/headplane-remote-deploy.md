# Headplane — Remote Deployment Plan (photondatum.space)

**Summary:** Deploy Headplane on the Headscale server at `photondatum.space` (Fedora 43), binding it exclusively to the tailnet interface. No public-internet exposure. Access is gated at the network layer — only enrolled tailnet members reach the port — with Headplane's own API-key login as the second factor.

**Last Updated:** 2026-04-27
**Headplane Version:** v0.6.2 (latest stable)
**Headscale Version:** v0.28.0 (already running)
**Target Host:** `photondatum.space` — Fedora 43
**Status:** Draft — not yet executed

> **Companion documents:**
> - `docs/wip/headscale-proposal.md` — mesh architecture and rationale
> - `docs/wip/headscale-install-fedora.md` — base Headscale install reference

---

## Tailscale Quick Start (for Reference)

> **Skip if already installed and enrolled.**

Tailscale provides the secure WireGuard-based network that Headplane relies on for tailnet-only access. If you need to install or enroll a new machine:

### Install Tailscale (Linux)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo systemctl enable --now tailscaled
```

### Enroll in the Tailnet

Obtain a pre-auth key from your Headscale server (see [Headscale docs](https://headscale.net/)), then run:

```bash
sudo tailscale up --login-server https://photondatum.space --auth-key <preauthkey>
```

- After enrollment, confirm your tailnet IP:
  ```bash
  tailscale ip -4
  # Should return a 100.x.x.x address
  ```
- To check status and see all nodes:
  ```bash
  tailscale status
  ```

**You must be enrolled in the same tailnet as the Headscale server to access Headplane.**

---

## Table of Contents

1. [Architecture and Security Model](#1-architecture-and-security-model)
2. [Prerequisites](#2-prerequisites)
3. [Phase 1 — Enroll the Server in Its Own Tailnet](#3-phase-1--enroll-the-server-in-its-own-tailnet)
4. [Phase 2 — Create Headscale API Key](#4-phase-2--create-headscale-api-key)
5. [Phase 3 — Deploy Headplane](#5-phase-3--deploy-headplane)
6. [Phase 4 — Firewall: Block Public Access](#6-phase-4--firewall-block-public-access)
7. [Phase 5 — Access Headplane from Local Machine](#7-phase-5--access-headplane-from-local-machine)
8. [Verification Reference](#8-verification-reference)
9. [Upgrade Path](#9-upgrade-path)
10. [Troubleshooting](#10-troubleshooting)

---

## 1. Architecture and Security Model

```
  Your local machine (enrolled tailnet node)
         │
         │  WireGuard tunnel (encrypted, tailnet only)
         ▼
  photondatum.space — Tailscale IP: 100.x.x.x
         │
         │  loopback / container network
         ├──► Headplane :3000  (bound to 100.x.x.x only)
         │         │
         │         └──► Headscale :8080 (localhost / service socket)
         │
         └──► Headscale :443  (Caddy, public — unchanged)
```

**Security layers:**

| Layer | Mechanism | What it blocks |
|---|---|---|
| Network | Headplane binds to tailnet IP, not `0.0.0.0` | Public internet cannot initiate connections |
| Firewall | `firewalld` blocks port 3000 on the public zone | Prevents direct-IP access bypasses |
| Application | Headplane API-key login on first browser visit | Second factor: must have the headscale API key |
| Transport | WireGuard encryption | All traffic to Headplane is encrypted in transit |

**What this gives you:**
- Full-feature Headplane (local Headscale access → DNS editing, config management, all routes work)
- No OIDC complexity, no reverse proxy changes on the public path
- Zero new public ports opened

**Trade-off vs. the local-only option:** Headplane runs on the remote server. If the server is unreachable (unlikely for a VPS), Headplane is also unreachable. For a management UI this is acceptable.

---

## 2. Prerequisites

### 2.1 Local machine

- Tailscale client installed and enrolled in the `photondatum.space` headscale network
- SSH access to `photondatum.space` as a user with `sudo` rights

### 2.2 Remote server (photondatum.space)

- Headscale v0.28.0 running and healthy (`systemctl status headscale`)
- Caddy running as reverse proxy for headscale (from base install)
- Podman installed (`podman --version` ≥ 4.x)
- `firewalld` active (`systemctl status firewalld`)

### 2.3 Environment variables

Set these in your local terminal before running SSH commands in this guide:

```bash
SERVER="photondatum.space"
HEADPLANE_VERSION="0.6.2"
```

---

## 3. Phase 1 — Enroll the Server in Its Own Tailnet

Headplane needs a tailnet IP to bind to. The Headscale server itself must be an enrolled node in its own network.

> **Skip this phase if the server is already enrolled** — verify with `tailscale ip` on the server. If it returns a `100.x.x.x` address, proceed to Phase 2.

### 1.1 Install the Tailscale client on the server

```bash
ssh ${SERVER}
```

```bash
# On the server — install Tailscale client (not server — this is the client binary)
curl -fsSL https://tailscale.com/install.sh | sh

# Enable and start tailscaled
sudo systemctl enable --now tailscaled
```

### 1.2 Generate a pre-auth key for the server node

On the server, create a reusable pre-auth key scoped to the server user:

```bash
# On the server — headscale must already be running
sudo headscale users list
# Identify the admin/operator user (e.g. "admin" or the main user)

# Create a one-time pre-auth key for the server-as-node registration
# Replace <user> with your headscale user
sudo headscale preauthkeys create --user <user> --expiration 1h
# Copy the key output — used in 1.3
```

### 1.3 Enroll the server node

```bash
# On the server — connect to headscale using localhost (no external round-trip needed)
sudo tailscale up \
  --login-server https://photondatum.space \
  --auth-key <preauthkey-from-1.2> \
  --accept-routes \
  --hostname headscale-host
```

### 1.4 Confirm the tailnet IP

```bash
tailscale ip -4
# Expected: 100.x.x.x  — note this value as TAILNET_IP
```

Set locally for subsequent phases:

```bash
# On your local machine
TAILNET_IP="100.x.x.x"   # replace with the actual value from 1.4
```

**Verify from your local machine:**

```bash
# Your local machine must also be enrolled in the same tailnet
ping -c 3 ${TAILNET_IP}
# Expected: 3 replies, ~low latency
```

---

## 4. Phase 2 — Create Headscale API Key

Headplane authenticates to Headscale using an API key. This is the credential that also gates Headplane's web login.

```bash
ssh ${SERVER}
```

```bash
# On the server — create a long-lived API key for Headplane
sudo headscale apikeys create --expiration 365d
# Output: a long alphanumeric string — SAVE THIS, shown only once
```

Store the key securely (e.g., your local password manager). You will enter it in Headplane's login screen on first use.

---

## 5. Phase 3 — Deploy Headplane

### 5.1 Create directories

```bash
ssh ${SERVER}
```

```bash
sudo mkdir -p /etc/headplane
sudo mkdir -p /var/lib/headplane
```

### 5.2 Write the Headplane config

```bash
sudo tee /etc/headplane/config.yaml > /dev/null << 'EOF'
server:
  # Bind only to the tailnet interface — not 0.0.0.0
  host: "TAILNET_IP_PLACEHOLDER"
  port: 3000
  # base_url must match how you access it: http://<tailnet-ip>:3000
  base_url: "http://TAILNET_IP_PLACEHOLDER:3000"
  # Generate with: openssl rand -base64 24
  cookie_secret: "REPLACE_WITH_32_CHAR_SECRET"
  cookie_secure: false   # no HTTPS on this path (WireGuard handles encryption)

headscale:
  # Localhost — Headplane and Headscale are on the same server
  url: "http://127.0.0.1:8080"
  # API key created in Phase 2
  api_key: "REPLACE_WITH_API_KEY"
  # Optional: path to Headscale config for DNS/settings management (full feature mode)
  config_path: "/etc/headscale/config.yaml"

# No OIDC — API key is the auth mechanism
# No Docker integration needed — direct config file access via bind mount

integration:
  docker:
    enabled: false
  kubernetes:
    enabled: false
EOF
```

Now substitute the real tailnet IP and secrets:

```bash
# Replace TAILNET_IP_PLACEHOLDER with the actual value
sudo sed -i "s/TAILNET_IP_PLACEHOLDER/${TAILNET_IP}/g" /etc/headplane/config.yaml

# Edit the file to insert cookie_secret and api_key
sudo nano /etc/headplane/config.yaml
# Replace REPLACE_WITH_32_CHAR_SECRET with: $(openssl rand -base64 24)
# Replace REPLACE_WITH_API_KEY with the key from Phase 2
```

> **Security note:** `/etc/headplane/config.yaml` contains the API key in plain text. Restrict permissions:
> ```bash
> sudo chmod 600 /etc/headplane/config.yaml
> sudo chown root:root /etc/headplane/config.yaml
> ```

### 5.3 Create the Podman quadlet unit

```bash
sudo mkdir -p /etc/containers/systemd

sudo tee /etc/containers/systemd/headplane.container > /dev/null << EOF
[Unit]
Description=Headplane — Headscale Web UI
After=network-online.target headscale.service
Wants=network-online.target

[Container]
Image=ghcr.io/tale/headplane:${HEADPLANE_VERSION}
ContainerName=headplane
# Bind mount config and persistent data
Volume=/etc/headplane/config.yaml:/etc/headplane/config.yaml:ro,z
Volume=/var/lib/headplane:/var/lib/headplane:z
# Optional: mount Headscale config for full DNS/settings management
Volume=/etc/headscale/config.yaml:/etc/headscale/config.yaml:z
# No PublishPort — network access is via the tailnet IP bound inside the container
# The container process listens on the tailnet IP directly
Network=host

[Service]
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
```

> **Why `Network=host`:** Headplane is bound to the tailnet IP (`100.x.x.x`), which only exists on the host network. `Network=host` lets the container bind to that interface directly. The firewall (Phase 4) is the enforcement boundary, not container network isolation.

### 5.4 Start Headplane

```bash
# Reload systemd to pick up the new quadlet
sudo systemctl daemon-reload

# Start and enable
sudo systemctl enable --now headplane

# Verify it started cleanly
sudo systemctl status headplane
sudo journalctl -u headplane -n 30
```

**Verify the process is listening on the tailnet IP only:**

```bash
sudo ss -tlnp | grep 3000
# Expected: 0.0.0.0:3000 is NOT present
# Expected: 100.x.x.x:3000  IS present
```

---

## 6. Phase 4 — Firewall: Block Public Access

The Caddy/Headscale public interface is on the default `public` zone. Port 3000 must be blocked there and allowed only from the tailnet subnet.

### 6.1 Confirm current zone for the public interface

```bash
sudo firewall-cmd --get-active-zones
# The public-facing interface (eth0 or similar) should show as 'public'
```

### 6.2 Block port 3000 on the public zone

Port 3000 is not open by default, but make this explicit:

```bash
sudo firewall-cmd --zone=public --remove-port=3000/tcp --permanent 2>/dev/null || true
sudo firewall-cmd --reload
```

### 6.3 Verify port 3000 is NOT reachable from the public internet

```bash
# From your local machine — NOT on the tailnet, using the public IP
# This should time out or be refused
curl --connect-timeout 5 http://photondatum.space:3000/admin
# Expected: Connection refused or timeout
```

> If you don't have a machine off the tailnet to test from, skip this check — the binding to `100.x.x.x` (not `0.0.0.0`) provides the same guarantee at the OS level.

### 6.4 Confirm tailnet access is not blocked

`tailscale0` (or `utun`/`wg0` depending on kernel) is the WireGuard interface. Traffic arriving on it to port 3000 should pass through — Headplane is listening on that IP and the firewall allows traffic on the tailnet interface zone (usually `trusted` or `internal`):

```bash
sudo firewall-cmd --get-zone-of-interface=tailscale0
# If it shows 'public', move it to 'trusted':
sudo firewall-cmd --zone=trusted --add-interface=tailscale0 --permanent
sudo firewall-cmd --reload
```

---

## 7. Phase 5 — Access Headplane from Local Machine

### 7.1 Confirm your local machine is enrolled in the tailnet

```bash
# On your local machine
tailscale ip -4
# Should return a 100.x.x.x address
tailscale status | grep headscale-host
# Should show the server node as online
```

### 7.2 Open Headplane in a browser

Navigate to:

```
http://<TAILNET_IP>:3000/admin
```

Replace `<TAILNET_IP>` with the `100.x.x.x` value from Phase 1.4.

### 7.3 Log in with the API key

On the Headplane login screen:

1. **Headscale URL:** `https://photondatum.space` (the public URL — Headplane's backend uses `127.0.0.1:8080`, but the browser form needs the public-facing URL for CORS)
2. **API Key:** paste the key created in Phase 2

> If CORS errors appear, add `allowed_origins` to Headscale's `config.yaml`:
> ```yaml
> # In /etc/headscale/config.yaml on the server
> # Add or update:
> policy:
>   # ... existing policy config ...
> # Under the server section:
> cors:
>   allowed_origins:
>     - "http://<TAILNET_IP>:3000"
> ```
> Then `sudo systemctl restart headscale`.

### 7.4 Verify full-feature mode is active

After login, confirm the "DNS" and "Settings" tabs appear in the Headplane navbar. Their presence confirms that `config_path` is readable and full-feature mode is active.

---

## 8. Verification Reference

Run these checks after completing all phases:

```bash
# === On the server (via SSH) ===

# 1. Headplane process is running
sudo systemctl is-active headplane
# Expected: active

# 2. Listening only on tailnet IP, not 0.0.0.0
sudo ss -tlnp | grep 3000
# Expected: 100.x.x.x:3000

# 3. Port 3000 not open on public zone
sudo firewall-cmd --zone=public --list-ports | grep 3000
# Expected: (empty)

# 4. Tailscale interface in trusted zone
sudo firewall-cmd --zone=trusted --list-interfaces
# Expected: tailscale0 (or equivalent) is listed

# 5. Headscale is reachable from Headplane (loopback)
curl -s -o /dev/null -w "%{http_code}" http://127.0.0.1:8080/health
# Expected: 200

# === From your local machine ===

# 6. Headplane responds over tailnet
curl -s -o /dev/null -w "%{http_code}" http://${TAILNET_IP}:3000/admin
# Expected: 200 or 302 (redirect to login)

# 7. Headplane NOT reachable on public IP + port
curl --connect-timeout 5 http://photondatum.space:3000/admin
# Expected: curl: (7) Failed to connect or (28) Timeout
```

---

## 9. Upgrade Path

To upgrade Headplane to a newer version:

```bash
ssh ${SERVER}

# Pull the new image
sudo podman pull ghcr.io/tale/headplane:<new-version>

# Update the quadlet image tag
sudo sed -i "s|headplane:.*|headplane:<new-version>|" \
  /etc/containers/systemd/headplane.container

# Restart
sudo systemctl daemon-reload
sudo systemctl restart headplane
```

Check the [Headplane changelog](https://headplane.net/CHANGELOG) before upgrading — the config schema has changed between major versions.

---

## 10. Troubleshooting

### Headplane starts but login fails with "connection refused"

The Headplane backend cannot reach Headscale at `http://127.0.0.1:8080`. Verify:

```bash
# Is Headscale running?
sudo systemctl status headscale

# Is it listening on port 8080?
sudo ss -tlnp | grep 8080
```

Headscale may be listening on its Unix socket rather than TCP. Check `/etc/headscale/config.yaml`:

```yaml
# Headscale should have either:
listen_addr: "127.0.0.1:8080"
# OR a unix socket. If socket, update headplane config.yaml:
# headscale.url: "unix:///var/run/headscale/headscale.sock"
```

### Browser shows CORS error

Headplane's frontend (running in your browser at `http://100.x.x.x:3000`) is making API calls to `https://photondatum.space`. The browser enforces CORS — add the tailnet URL to Headscale's allowed origins as shown in §7.3.

### Headplane is accessible from the public internet (unexpected)

The container is likely using `Network=host` but `host` in the config.yaml is still `0.0.0.0`. Re-check `/etc/headplane/config.yaml` and confirm `server.host` is set to `100.x.x.x`, not `0.0.0.0`. Restart the container after fixing.

### tailscale0 interface not visible on Fedora 43

Fedora 43 may name the WireGuard interface differently. Find it:

```bash
ip link show | grep -E 'tailscale|wg'
# Use whatever interface name appears in the firewalld zone assignment (§6.4)
```

### API key expires

Create a new key with `sudo headscale apikeys create --expiration 365d`, then update `/etc/headplane/config.yaml` and restart the container.
