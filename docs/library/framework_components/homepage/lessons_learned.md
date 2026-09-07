# Homepage — Lessons Learned

**Last Updated:** 2026-07-20

## Purpose

Empirical findings from operating Homepage (`gethomepage/homepage`) in this stack. Records behaviour that diverged from documentation, assumptions, or prior expectations.

---

## Table of Contents

1. [`{{HOMEPAGE_VAR_*}}` Placeholders Silently Resolve Empty If Never Wired Into `config.json`](#1-homepage_var-placeholders-silently-resolve-empty-if-never-wired-into-configjson)
2. [Toggling LAN vs Public Service Links Requires Client-Side `custom.js`](#2-toggling-lan-vs-public-service-links-requires-client-side-customjs)

---

## 1 `{{HOMEPAGE_VAR_*}}` Placeholders Silently Resolve Empty If Never Wired Into `config.json`

**Version:** Homepage `latest` (gethomepage/homepage)
**Discovered:** 2026-07-20, dashboard showing errors on Authentik, Qdrant, and Grafana widgets

### What Happened

`configs/homepage/services.yaml` referenced `{{HOMEPAGE_VAR_AUTHENTIK_TOKEN}}`,
`{{HOMEPAGE_VAR_QDRANT_API_KEY}}`, `{{HOMEPAGE_VAR_GRAFANA_USER}}`, and
`{{HOMEPAGE_VAR_GRAFANA_PASS}}` for their respective widgets. All three widgets
showed errors on the dashboard. `podman inspect homepage` showed **zero**
`HOMEPAGE_VAR_*` environment variables on the running container — `config.json`'s
`homepage` service block had an empty `secrets` array. Homepage doesn't error
loudly when a template variable is undefined; it just sends an empty/missing
value, which then fails at the widget's target service (403 from Authentik with
no token, no `api-key` header reaching Qdrant, no credentials reaching Grafana).

This is the same regression class as the OpenWebUI trusted-header SSO fix
earlier the same day: a fix gets applied somewhere (a token gets created, a
credential exists) but never gets wired into `config.json`'s `secrets` block, so
it's invisible to `generate-quadlets` and silently absent from the container.

### Fix

Create a Podman secret for each value and wire it into the service's `secrets`
list in `config.json` (both the live file and the repo's `config.json.example`
template), with `target` matching the exact `HOMEPAGE_VAR_*` name used in
`services.yaml`:

```json
"secrets": [
  { "name": "homepage_authentik_token", "target": "HOMEPAGE_VAR_AUTHENTIK_TOKEN" },
  { "name": "qdrant_api_key", "target": "HOMEPAGE_VAR_QDRANT_API_KEY" },
  { "name": "homepage_grafana_user", "target": "HOMEPAGE_VAR_GRAFANA_USER" },
  { "name": "homepage_grafana_pass", "target": "HOMEPAGE_VAR_GRAFANA_PASS" }
]
```

Then `bash scripts/configure.sh generate-quadlets` and restart `homepage.service`.
Verify with `podman exec homepage env | grep HOMEPAGE_VAR` — the real values
should appear, not the literal `{{...}}` placeholder.

### Rule

> Any `{{HOMEPAGE_VAR_X}}` in `services.yaml` (or any other Homepage config
> file) is a claim that `config.json`'s `homepage.secrets` supplies a Podman
> secret targeting `HOMEPAGE_VAR_X`. Grep `podman exec homepage env` to confirm
> the variable actually resolves — a missing wire-up fails silently at the
> downstream service, not at Homepage itself, which makes it easy to misdiagnose
> as a problem with Authentik/Qdrant/Grafana rather than with Homepage's config.

---

## 2 Toggling LAN vs Public Service Links Requires Client-Side `custom.js`

**Version:** Homepage `latest`
**Discovered:** 2026-07-20, LAN (`*.stack.localhost`) vs public (`*.photondatum.space`) service tile links

### What Happened

Service tiles in `services.yaml` had a mix of `*.stack.localhost` and
`*.photondatum.space` hrefs, depending on when each was added. The goal: when
viewing the dashboard locally (`dashboard.stack.localhost` / `localhost`), tile
links should point at the LAN hostnames; when viewing remotely via
`dashboard.photondatum.space`, they should point at the public hostnames —
whichever the viewer can actually reach.

Homepage renders `services.yaml` server-side into static HTML — the server has
no way to know, at render time, which hostname the *viewer* used to reach the
page. There's no per-request templating hook for this in `services.yaml` itself.

### Fix

`custom.js` is loaded and executed client-side by Homepage's own bundle
(confirmed: it's served at `/api/config/custom.js` but is *not* referenced as a
static `<script src>` tag in the server-rendered HTML — Homepage's frontend
fetches and injects it after hydration). Since the browser always knows its own
`window.location.hostname`, the rewrite has to happen there:

```js
var PUBLIC_DASHBOARD_HOSTS = ["dashboard.photondatum.space"];
var HOST_MAP = { "grafana.stack.localhost": "grafana.photondatum.space", /* ... */ };

function rewriteLinks() {
  if (PUBLIC_DASHBOARD_HOSTS.indexOf(window.location.hostname) === -1) return;
  document.querySelectorAll("a[href]").forEach(function (a) {
    var url = new URL(a.href, window.location.href);
    if (HOST_MAP[url.hostname]) { url.hostname = HOST_MAP[url.hostname]; a.href = url.toString(); }
  });
}
```

A `MutationObserver` on `document.body` re-runs the rewrite as Homepage's React
app re-renders tiles, since the initial pass alone misses anything mounted after
hydration. See `configs/homepage/custom.js` for the full implementation.

Only services with a genuine live public route were added to `HOST_MAP`
(`agent`, `flowise`, `litellm`, `ki`, `grafana`, `prometheus`). Services with no
public Caddy/Traefik route (Traefik dashboard, Ollama, Qdrant UI, MinIO console)
were deliberately left LAN-only — adding them to the map would produce a
public-looking link that 404s.

### Rule

> Homepage config files are static and server-rendered once; there is no
> server-side way to branch on the viewer's origin. Any "different link
> depending on how you got here" requirement belongs in `custom.js`, keyed off
> `window.location.hostname`, not in `services.yaml`.
