# Headscale — Best Practices

- Always verify DERP with `curl http://127.0.0.1:8080/derp/probe` after any restart;
  HTML response means DERP is disabled, not an error page
- Keep `paths: []` in config — loading an external `derp.yaml` adds a second region
  definition that collides with the embedded relay
- Keep `derp.yaml` cleared to `regions: {}` as a canary — if it gets populated again,
  there is a configuration drift problem
- Set `server_url` and `dns.base_domain` to the real domain before first enrollment;
  changing them after nodes are enrolled requires re-enrollment
- Use `tailscale netcheck` from enrolled nodes periodically to verify relay health
- Run Headscale restart (not reload) after any config change — Headscale does not
  support config reload
- Headplane admin UI should only be accessible on the tailnet IP, not the public IP;
  it provides full node management without additional authentication
- Rotate Headplane `cookie_secret` if the host is compromised; this invalidates all
  Headplane sessions
- Use ACL tags in `acl.json` to restrict which nodes can reach which services rather
  than relying on tailnet membership alone
