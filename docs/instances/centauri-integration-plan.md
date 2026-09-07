# CENTAURI — Integration Plan (photondatum.space IAM)
**Status:** Active (outstanding: tlvulcan7 invitation delivery + smoke test)
**Last Updated:** 2026-07-11

This document tracks the work needed to fully integrate CENTAURI with the photondatum.space IAM deployment and to resolve post-migration cleanup items. It also records planned roles for SOL and TC25 for future reference.

---

## Immediate — CENTAURI Cleanup

These items are blocking or degrading service now.

### 1. Stop Stale Authentik Service (BLOCKING — causes forwardAuth 500s)

**Why:** The old Authentik container left running on CENTAURI after migration to VPS is causing Traefik forwardAuth timeouts. The embedded outpost loops on `auth.stack.localhost/ws/client/` reconnects, producing 14-second hangs and 500 errors on `agent.photondatum.space`.

**Action (run as `3pdx7` on CENTAURI):**
```bash
systemctl --user stop authentik
systemctl --user disable authentik
```

**Verify:**
```bash
# Should return 302 (Authentik redirect), not 500
curl -sk -o /dev/null -w "%{http_code}" \
  -H "Host: agent.photondatum.space" https://100.64.0.4:443
```

**See:** [Authentik lessons learned §12](../library/framework_components/authentik/lessons_learned.md#12-stale-authentik-on-controller-node-causes-forwardauth-interference)

---

### 2. Fix Forgejo ROOT_URL (causes http:// redirect_uri in OIDC)

**Why:** Forgejo builds OAuth2 `redirect_uri` from its `ROOT_URL`. Without it set to `https://`, it sends `http://` URIs. Currently worked around by registering both schemes in Authentik, but the permanent fix is cleaner and eliminates the http→https redirect hop in the OIDC flow.

**Action (requires sudo on photondatum.space as `3pdx7a`):**
```bash
sudo -e /etc/forgejo/app.ini
# Add under [server]:
#   ROOT_URL = https://git.photondatum.space
sudo systemctl restart forgejo
```

**After fix:** Remove the `http://` redirect URI from the Authentik `Forgejo OIDC` provider (Authentik admin → Providers → Forgejo OIDC → Edit → Redirect URIs). Keep only:
```
https://git.photondatum.space/user/oauth2/Authentik/callback
```

**See:** [Forgejo lessons learned §2](../library/framework_components/forgejo/lessons_learned.md#2-root_url-must-be-set-to-https-or-oidc-redirect_uri-uses-http)

---

## Short-term — CENTAURI Integration Validation

Once the immediate items are resolved, verify end-to-end integration.

### 3. Verify agent.photondatum.space Works for digital-michael

1. Navigate to `https://agent.photondatum.space` in a fresh browser session
2. Should redirect to `https://auth.photondatum.space` (Authentik login)
3. Sign in with GitHub → lands in OpenWebUI as `digital-michael`
4. Confirm bundle-admin permissions are in effect (all models accessible)

### 4. Verify flowise.photondatum.space Works

1. Navigate to `https://flowise.photondatum.space`
2. Should redirect to Authentik login
3. Sign in as `digital-michael` (bundle-admin) → lands in Flowise
4. Other users (bundle-agent) should receive a policy deny page

### 5. Verify dashboard.photondatum.space Works

1. Navigate to `https://dashboard.photondatum.space`
2. Sign in as `digital-michael` → Homepage dashboard loads
3. Confirm widgets (Grafana, Qdrant, Authentik) show data, not 401s

---

## Medium-term — CENTAURI Configuration Hardening

### 6. Remove Authentik Quadlet From CENTAURI Config

The `authentik.service` quadlet file still exists on CENTAURI at
`~/.config/containers/systemd/authentik.container`. After confirming the service
is stopped and disabled, remove it to prevent accidental restarts:

```bash
rm ~/.config/containers/systemd/authentik.container
systemctl --user daemon-reload
```

Also remove from `configs/config.json` the `authentik` entry under CENTAURI's
effective config (or mark `_suspended` like vllm) to prevent `configure.sh`
from regenerating the quadlet on the next deploy.

### 7. Update `node_profile` in CENTAURI config.json

The CENTAURI `node_profile` should be verified as `controller` (not `edge`).
The `edge` profile generates only IAM group quadlets and should not be used on
CENTAURI.

```bash
jq '.node_profile' configs/config.json
# Expected: "controller"
```

### 8. Verify Tailscale SSH ACL Covers New Nodes

With `digital-michael` now a Forgejo user and potentially connecting from new
devices, verify the Headscale ACL in `/etc/headscale/acl.json` on photondatum.space
covers any new node enrollments. SOL and TC25 will need their tags updated when
they re-enroll (see Node Plans below).

---

## Node Plans — SOL and TC25

These nodes are not active in the current deployment. Record their planned roles
here so that when they are brought back online, the deployment path is clear.

### SOL (`100.64.0.2`) — Enhanced Worker / Knowledge Worker

| Property | Planned Value |
|---|---|
| Role | `enhanced-worker` or `knowledge-worker` |
| Tailnet IP | `100.64.0.2` (last seen 10 days ago) |
| Node alias | `sol` |
| Platform | Linux |
| Headscale tags | `tag:inference`, `tag:net-ecotone-000-01` |

**Planned groups:**
- `ai-stack-infer` — Ollama (GPU or CPU inference offload from CENTAURI)
- `ai-stack-know` — Knowledge Index + Qdrant (offload knowledge pipeline)
- `ai-stack-obs` — Promtail only (ships logs to CENTAURI Loki)

**Integration with photondatum.space IAM:**
- Tailnet enrollment via `https://headscale.photondatum.space`
- No Authentik on SOL — all auth delegated to photondatum.space edge node
- Traefik forwardAuth (if SOL runs Traefik) points to `https://auth.photondatum.space`

**Activation checklist (when ready):**
- [ ] Re-enroll in Headscale: `sudo tailscale up --login-server https://headscale.photondatum.space --authkey <key> --hostname sol`
- [ ] Tag node: `sudo headscale nodes tag --identifier <id> --tags tag:inference,tag:net-ecotone-000-01`
- [ ] Deploy with `node_profile=enhanced-worker` or `knowledge-worker`
- [ ] Update CENTAURI Prometheus to scrape SOL metrics endpoint

---

### TC25 (`100.64.0.3`) — macOS Workstation / Client Node

| Property | Planned Value |
|---|---|
| Role | Client / occasional inference |
| Tailnet IP | `100.64.0.3` (last seen 4 days ago) |
| Node alias | `tc25` |
| Platform | macOS |
| Headscale tags | `tag:net-ecotone-000-01` |

**Notes:**
- macOS App Store Tailscale does not support `tailscale ssh` — use plain SSH to tailnet IP
- No Podman containers expected (macOS overhead); may run Ollama natively for local inference
- Primary role: client access to CENTAURI services via tailnet and photondatum.space proxy
- Authentik login works via browser (same `digital-michael` GitHub account)

**Activation checklist (when ready):**
- [ ] Re-enroll in Headscale (use `--force-reauth` if previously enrolled)
- [ ] Tag node: `sudo headscale nodes tag --identifier <id> --tags tag:net-ecotone-000-01`
- [ ] Verify `https://agent.photondatum.space` accessible from browser on TC25
- [ ] Optionally install Ollama natively for local model inference
- [ ] Update stale known-hosts entry if host key changed since last enrollment

---

## Completed

| Item | Date | Notes |
|---|---|---|
| Authentik migrated from CENTAURI to photondatum.space VPS | 2026-07 | All IAM now on edge node |
| Traefik forwardAuth middleware updated to auth.photondatum.space | 2026-07 | `configs/traefik/dynamic/middlewares.yaml` |
| All CENTAURI image versions pinned in config.json | 2026-07-09 | Was `latest` for several services |
| vllm suspended (GPU contention with Ollama) | 2026-07-09 | `_suspended` annotation in config.json |
| Flowise exposed via flowise.photondatum.space | 2026-07-10 | Caddy + Authentik bundle-admin policy |
| RustDesk version pinned to 1.1.15 | 2026-07-10 | Was `latest` in docker-compose.yml |
| Forgejo OIDC wired (Authentik side + Forgejo side) | 2026-07-10 | `digital-michael` linked via GitHub |
| akadmin email separated from personal account | 2026-07-10 | akadmin@photondatum.space |
| Dashboard Caddy fix — `header_up Host` corrected | 2026-07-10 | Was `dashboard.stack.localhost`; now `dashboard.photondatum.space` — apply Caddyfile with sudo |
| Traefik ki-public routers added | 2026-07-10 | `ki-public-admin`, `ki-public-api`, `ki-public-mcp` — live in services.yaml |
| Authentik KI provider external_host updated | 2026-07-10 | `ki.stack.localhost` → `ki.photondatum.space` |
| Authentik MCP app meta_launch_url set | 2026-07-10 | `https://ki.photondatum.space/mcp` (MCP is a path on knowledge-index, not a separate service) |
| Authentik KI redirect_uris updated to ki.photondatum.space | 2026-07-10 | ORM `.save()` does not auto-regenerate redirect_uris; set explicitly (Lesson §15) |
| knowledge-index-lan provider created | 2026-07-10 | Restores `ki.stack.localhost` LAN auth; second ProxyProvider + Application added to embedded outpost (Lesson §16) |
| Homepage Authentik widget token updated | 2026-07-10 | Old token was from local Authentik (CENTAURI); new `homepage-widget` token created in VPS Authentik, quadlet patched in-place |
| KI browser auth — Traefik header injection | 2026-07-10 | `ki-auth.yaml` (gitignored) adds `Authorization: Bearer <knowledge_index_api_key>` after Authentik SSO passes; applied to `knowledge-index-api` (LAN) and `ki-public-admin` (public) routers |
| Grafana SSO via auth.proxy | 2026-07-10 | `grafana.ini` updated: `auth.proxy` enabled, trusts `X-authentik-username` header from Authentik outpost; login form disabled; whitelist `10.89.0.0/24` prevents spoofing |
| Flowise SSO — internal auth removed | 2026-07-10 | `FLOWISE_USERNAME` and `flowise_password` secret removed from quadlet; Authentik forwardAuth via Traefik is now the sole auth gate |
| Stale Authentik quadlet removed from CENTAURI | 2026-07-10 | `~/.config/containers/systemd/authentik.container` deleted; `m2m-gateway.container` `After/Requires=authentik.service` dependency removed; daemon-reload run |
| Forgejo ROOT_URL set to HTTPS | 2026-07-10 (re-applied 2026-07-11) | `/etc/forgejo/app.ini` `ROOT_URL = https://git.photondatum.space`; `http://` redirect URI already absent from Authentik Forgejo OIDC provider. Change was re-applied 2026-07-11 — initial apply did not persist. |
| Forgejo registration restricted | 2026-07-10 | `ALLOW_ONLY_EXTERNAL_SELF_REGISTRATION = true`, `DEFAULT_ALLOW_CREATE_ORGANIZATION = false` added to `[service]` in `/etc/forgejo/app.ini` |
| `forgejo-guest` group created | 2026-07-10 | Created in Authentik; `access-forgejo` ExpressionPolicy updated to include `ak_is_group_member(request.user, name="forgejo-guest")` |
| Homepage KI link corrected | 2026-07-10 | `services.yaml` href changed from `dashboard.stack.localhost/v1/catalog` to `ki.photondatum.space/v1/catalog` |
| OpenWebUI trusted email header SSO | 2026-07-11 | `WEBUI_AUTH_TRUSTED_EMAIL_HEADER=X-authentik-email` + `WEBUI_AUTH_TRUSTED_NAME_HEADER=X-authentik-name` added to `openwebui.container`; login form replaced by Authentik forwardAuth auto-sign-in |
| akadmin promoted to Admin in OpenWebUI | 2026-07-11 | Logged in as `michaelbiggerstaff7@gmail.com` → Workspace → Users → promoted `akadmin@photondatum.space` to Admin |
| Flowise Caddyfile host header fixed | 2026-07-11 | `flowise.photondatum.space` block was sending `Host: flowise.stack.localhost` — no Traefik router matched, Traefik 404'd. Changed to `Host: flowise.photondatum.space` in `/etc/caddy/Caddyfile`; caddy reloaded. Repo Caddyfile updated to match. |
| LiteLLM OAuth endpoints updated to VPS Authentik | 2026-07-11 | `litellm.env` had three endpoints pointing to stale `auth.stack.localhost` / `authentik.ai-stack:9000`. Updated all three to `https://auth.photondatum.space/...`; LiteLLM restarted. |
| akadmin Forgejo account created and promoted to admin | 2026-07-11 | Created with local auth source (not OIDC) using `akadmin@photondatum.space`; promoted to site administrator. Linked Authentik OIDC via User Settings → Security → Linked Accounts. |
| akadmin added to bundle-admin group | 2026-07-11 | Authentik superuser status does not grant group membership. Added akadmin to bundle-admin so all bundle-admin-gated applications (Agent, Flowise, Dashboard, KI, LiteLLM) appear in akadmin's portal and pass policy checks. |
| Homepage Authentik widget token renewed | 2026-07-11 | Old token expired (was from prior session). Deleted in Authentik; new `homepage-widget` API token created under akadmin; `homepage.container` quadlet updated; service reloaded. |
| LiteLLM external access enabled | 2026-07-11 | New OAuth2 provider + Application created in VPS Authentik (old credentials were from decommissioned CENTAURI Authentik). `litellm-public` Traefik router added for `litellm.photondatum.space`. Caddy block added. `GENERIC_CLIENT_ID`, `GENERIC_CLIENT_SECRET`, `GENERIC_REDIRECT_URI`, `PROXY_BASE_URL` updated in `litellm.env`. LiteLLM restarted. No forwardAuth on public router — LiteLLM manages its own OAuth SSO. |
| Traefik `nocache` middleware added | 2026-07-11 | `Cache-Control: no-store` on all auth-gated routers (`openwebui`, `openwebui-public`); prevents browser cache from bypassing forwardAuth on session expiry. Briefly removed during redirect loop investigation (false hypothesis); re-added once actual root cause identified. |
| Redirect loop on agent.photondatum.space and flowise.photondatum.space resolved | 2026-07-11 | Root cause: `access_token_validity` on both ProxyProviders stored as `1 day, 0:00:00` (Python timedelta repr, no `=` separator). `timedelta_from_string()` crashed on every token exchange — callback returned 302 without Set-Cookie, no session ever created. Diagnosed via Authentik event log: alternating "Application authorized" + "General system exception (127.0.0.1)" pairs. Fixed by setting `hours=24` in both Agent (OpenWebUI) and Flowise Proxy providers via admin UI. See Authentik lessons §18 caveat and §19. |
| OpenWebUI trusted email header SSO — re-applied | 2026-07-20 | Regressed since 2026-07-11: the row above recorded the vars added directly to `openwebui.container`, but `config.json` (both live `~/ai-stack/configs/config.json` and the repo's `configs/config.json.example` template) never had them, so a subsequent `generate-quadlets` run silently dropped them again — confirmed missing via `podman inspect openwebui`. Verified `akadmin` and `digital-michael` both resolve to the same Authentik email (`michaelbiggerstaff7@gmail.com`) before enabling, so no orphaned OpenWebUI account would be created. Re-added `WEBUI_AUTH_TRUSTED_EMAIL_HEADER` / `WEBUI_AUTH_TRUSTED_NAME_HEADER` to `config.json` this time (not just the quadlet) so it survives future `generate-quadlets` runs; ran `generate-quadlets` + restarted `openwebui.service`. |
| Caddy `dial_timeout` + access logging added to CENTAURI routes | 2026-07-20 | Investigating a one-off "AI Stack offline" delay report (CENTAURI awake, tailscale reachable, ~2 min of failures) found Caddy had **no access logging at all** (`log` directive absent from every site block) and no `reverse_proxy` `dial_timeout` — so the incident left no timestamped evidence on either side, and a dead/asleep CENTAURI could hang a request rather than fail fast. Added `dial_timeout 5s` and `log` to the `agent`, `dashboard`, `ki`, `flowise`, and `litellm` blocks in `/etc/caddy/Caddyfile` (validated with `caddy validate` before reload, backup taken first). Root cause of the original delay was not conclusively identified — no matching dial-failure entries found in 30 days of prior Caddy logs — but a repeat is now diagnosable. Active health checks (`health_uri`) were deliberately not added — each backend app needs a verified no-auth probe path first, and a wrong one would falsely mark a healthy CENTAURI down. |
| `docs/instances/photondatum.md` Caddyfile mirror corrected | 2026-07-20 | Despite the "Flowise Caddyfile host header fixed" row above claiming "Repo Caddyfile updated to match," this doc's embedded Caddyfile still showed `header_up Host flowise.stack.localhost` — the update never actually happened. Corrected to `flowise.photondatum.space` and refreshed the whole embedded block to match the live file (dial_timeout/log additions above, litellm block added — it was missing entirely). |
| `m2m-iam-crud` playbook — stale `auth.stack.localhost` replaced | 2026-07-20 | `configs/traefik/dynamic/services.yaml` records that the `auth.stack.localhost` Traefik router was removed when Authentik moved to the VPS, so all 8 references in `docs/library/actions/m2m-iam-crud/m2m-iam-crud-SKILL.md` (issuer/JWKS/provision/token URLs) pointed at a hostname with no route. Replaced with `auth.photondatum.space` throughout. |
| Grafana + Prometheus exposed publicly | 2026-07-20 | DNS A records added (`grafana.photondatum.space`, `prometheus.photondatum.space` → `66.228.37.60` — first attempt had a typo, `66.226.37.60`, caught and corrected). Traefik `grafana-public`/`prometheus-public` routers added to `services.yaml`. Caddy blocks added on the VPS (with `dial_timeout 5s` + `log`, matching the pattern above). Authentik Grafana/Prometheus ProxyProviders' `external_host`/`redirect_uris` updated from `*.stack.localhost` to `*.photondatum.space` via the API (PATCH required `internal_host` + `mode` explicitly in the request body even though unchanged — DRF partial-update validator reads the raw payload, not the merged instance; a bare `external_host`-only PATCH 400'd with "Internal host cannot be empty"). |
| Homepage widget secrets wired (Authentik, Qdrant, Grafana) | 2026-07-20 | `services.yaml` referenced `{{HOMEPAGE_VAR_AUTHENTIK_TOKEN}}`, `{{HOMEPAGE_VAR_QDRANT_API_KEY}}`, `{{HOMEPAGE_VAR_GRAFANA_USER}}`, `{{HOMEPAGE_VAR_GRAFANA_PASS}}` but none were ever wired into `config.json` — same regression class as the OpenWebUI SSO fix. Created Podman secrets (`homepage_authentik_token` — the existing non-expiring `homepage-widget` Authentik token, never actually used; `homepage_grafana_user`/`homepage_grafana_pass` — existing `admin`/`admin` from `grafana.ini`) and wired all four (plus the pre-existing `qdrant_api_key`) into `homepage.secrets` in both `config.json` and `config.json.example`. Verified: Authentik 403s gone, Qdrant proxy returns 200, Grafana basic auth confirmed working against `/api/org` despite `auth.proxy` being enabled. See [Homepage lessons learned §1](../library/framework_components/homepage/lessons_learned.md#1-homepage_var-placeholders-silently-resolve-empty-if-never-wired-into-configjson). |
| `configs/homepage/` tracked in the repo for the first time | 2026-07-20 | Never existed in the repo at all (unlike Traefik's dynamic config, which is tracked and synced) — `services.yaml`, `settings.yaml`, `custom.js`, `custom.css`, `bookmarks.yaml`, `docker.yaml`, `kubernetes.yaml`, `proxmox.yaml` copied in from the deployed `~/ai-stack/configs/homepage/`. Added `homepage/` to the framework_components README-agent.md table (along with `caddy/`, also previously missing despite having its own docs directory). |
| Dashboard LAN/public link toggle added (`custom.js`) | 2026-07-20 | Homepage's service tiles mixed `*.stack.localhost` and `*.photondatum.space` hrefs inconsistently. Added client-side link rewriting in `custom.js`: when the dashboard itself is viewed via `dashboard.photondatum.space`, LAN hrefs (`openwebui`, `flowise`, `litellm`, `ki`, `grafana`, `prometheus` `.stack.localhost`) are rewritten to their public equivalents; viewed locally, links stay LAN as-is. Has to be client-side — the server can't know which hostname the viewer used. See [Homepage lessons learned §2](../library/framework_components/homepage/lessons_learned.md#2-toggling-lan-vs-public-service-links-requires-client-side-customjs). |
| LAN (`*.stack.localhost`) access restored for 6 services | 2026-07-20 | Building the link toggle above surfaced that the LAN routes it points to were already broken for every service except Knowledge Index: `openwebui`, `flowise`, `dashboard`, `litellm`, and (freshly, from the Grafana/Prometheus change above) `grafana`/`prometheus` all 404'd — Authentik itself returns the 404 (`x-powered-by: authentik`), because each service's single ProxyProvider had its `external_host` migrated to the public hostname at some point with nothing preserving the LAN path. Since these backend ports are all bound to `127.0.0.1` only, the Traefik vhost was the *only* way another LAN device could reach them. Fixed by creating a second "LAN" ProxyProvider + Application for `agent`, `flowise`, `homepage`, `grafana`, and `prometheus` (mirroring the existing `knowledge-index-lan` pattern), each bound to the *same* access policy as its public counterpart, all enrolled in the Embedded Outpost. `litellm` handled differently — it has no ProxyProvider at all (public or LAN); removed the stray `authentik` middleware from its LAN Traefik router instead, matching `litellm-public`'s no-forwardAuth design (avoids a double OIDC round-trip). Flowise additionally had **no LAN Traefik router at all** — added one. Verified all 6 end-to-end (302/200 instead of 404). See [Authentik lessons learned §20](../library/framework_components/authentik/lessons_learned.md#20-migrating-a-proxyproviders-external_host-to-public-silently-kills-lan-access). |

## Outstanding — Known Gaps

### D. File Transfer Performance — photondatum.space → CENTAURI

**Why:** File uploads through the stack (Caddy → WireGuard tunnel → Traefik → service) are noticeably slow. Investigation and optimization deferred from 2026-07-11.

**Context from discussion:**

WireGuard does not compress — compression must happen above the transport layer, before data enters the tunnel. The VPS uplink is likely the primary constraint, not WireGuard overhead itself.

**Two axes to investigate:**

**A) Compression options:**

- `rsync -z` / `scp -C` — compress at transfer layer before WireGuard encryption. Effective for config files, text, logs. Negligible gain on binary model files (GGUF already compressed).
- `zstd` via `tar -I zstd | ssh ...` — faster than gzip at similar ratios; prefer for any large-file admin ops.
- `rsync --skip-compress=gguf,bin,safetensors` — avoid wasting CPU compressing already-binary formats.
- Caddy `encode gzip zstd` — compresses HTTP *responses* only, not user uploads. Limited applicability here.

**B) Structural improvements:**

- **rsync delta sync** for config/repo pushes — only transfers changed byte ranges. A 50MB file with 2KB of changes transfers in milliseconds.
- **Pull rather than push** — CENTAURI pulling from Forgejo (`git pull`) is more efficient than pushing from photondatum.space.
- **`rsync --bwlimit`** during inference hours — prevent large transfers from saturating the tunnel while Ollama is serving requests.
- **Direct tailnet for large KI ingests** — route bulk document ingestion to `100.64.0.4:8443/v1` directly instead of through Caddy, bypassing one buffering hop.
- **MTU fragmentation check** — WireGuard default MTU is 1420. If VPS upstream MTU is lower, packets fragment. Test: `ping -M do -s 1400 100.64.0.4`. If this fails, lower WireGuard interface MTU to 1280–1380 on both ends.

**First step when picking this up:**

Baseline the actual throughput: `rsync --progress --stats <test-file> 3pdx7@100.64.0.4:~/` and compare against the VPS provider's stated bandwidth cap. If throughput is near the cap, the fix is VPS tier or direct tailnet routing. If it's well below, MTU fragmentation or TCP-over-UDP overhead is the likely culprit.

---

### E. `knowledge-index-lan` Application Has No Access Policy Binding

**Why:** Found 2026-07-20 while creating the same `-lan` pattern for 5 other services (see Completed log). `knowledge-index-lan` (created 2026-07-10) has **no** `PolicyBinding` at all — unlike the 5 new `-lan` applications, which are each bound to the same access policy as their public counterpart. This means `ki.stack.localhost` is currently open to *any* authenticated Authentik user, regardless of bundle membership — inconsistent with `knowledge-index`'s public route, which requires `bundle-developer`/`bundle-admin`.

**Fix:** In Authentik admin → Applications → `Knowledge Index (LAN)` → bind the existing `access-knowledge-index` policy (order=0, enabled=true), matching the pattern used for the other five `-lan` applications.

---

**Note on Grafana and Flowise:**

- Grafana: `auto_assign_org_role = Admin` is set in `grafana.ini` — every Authentik SSO user is automatically an Admin. No action needed; akadmin will be Admin on first login.
- Flowise: no app-level auth — Authentik forwardAuth is the sole gate. akadmin already has full access through Authentik. No action needed.
