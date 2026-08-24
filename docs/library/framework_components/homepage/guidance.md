# Homepage — Guidance
**Last Updated:** 2026-07-20

## Purpose

Project-specific preferences and decisions for Homepage (`gethomepage/homepage`), the operator dashboard at `dashboard.stack.localhost` (LAN) / `dashboard.photondatum.space` (public, bundle-admin via Authentik forwardAuth).

---

## Config location

`configs/homepage/` is tracked in this repo (`services.yaml`, `settings.yaml`,
`custom.js`, `custom.css`, `bookmarks.yaml`, `docker.yaml`, `kubernetes.yaml`,
`proxmox.yaml`) and mounted read-only into the container from
`$AI_STACK_DIR/configs/homepage`. Homepage serves these files live — no restart
needed after editing `services.yaml`, `custom.js`, or `custom.css`. `logs/` is
runtime-only and gitignored (`*.log`).

## Widget secrets

Every `{{HOMEPAGE_VAR_X}}` used in `services.yaml` must have a matching Podman
secret wired into `config.json`'s `homepage.secrets` list with `target: "X"` —
in **both** the live `config.json` and the repo's `config.json.example`
template. Editing the quadlet directly instead of `config.json` will silently
regress on the next `generate-quadlets` run. See
[lessons learned §1](lessons_learned.md#1-homepage_var-placeholders-silently-resolve-empty-if-never-wired-into-configjson).

## LAN vs public service links

`services.yaml` hrefs default to the LAN hostname (`*.stack.localhost`) for any
service that has one — that's the primary, always-reachable path when Homepage
itself is viewed on the LAN. `custom.js` rewrites those to the public
(`*.photondatum.space`) equivalent client-side, but only when the dashboard is
being viewed via `dashboard.photondatum.space`. Only add a service to
`custom.js`'s `HOST_MAP` once it has a genuine live public route (DNS + Caddy +
Traefik `*-public` router + Authentik `external_host`) — see
[lessons learned §2](lessons_learned.md#2-toggling-lan-vs-public-service-links-requires-client-side-customjs).
Services with no public route (Traefik dashboard, Ollama, Qdrant UI, MinIO
console) stay LAN-only; do not add them to the map.

## Known gap

`best_practices.md` and `security.md` don't exist yet for this component —
only `guidance.md` and `lessons_learned.md`, which cover what's actually been
built and learned so far. Add the other two if/when there's a concrete need
(e.g. hardening the dashboard's public exposure) rather than generic filler.
