# Caddy — Best Practices

- Always use `https://` site blocks explicitly for services that must never serve HTTP
- Set `tls { alpn http/1.1 }` for any upstream that uses WebSocket upgrades or DERP (Headscale)
- Use `header_up Host <target-hostname>` when proxying to Traefik on CENTAURI — Traefik
  routes based on the Host header; the default forwarded host would be `photondatum.space`
- Use `tls_insecure_skip_verify` only when proxying to the internal Traefik self-signed cert;
  document every occurrence to avoid normalizing the pattern
- Put `handle_errors` on CENTAURI-proxy blocks so offline CENTAURI returns a clean 503
  instead of a Caddy error page
- Never put Caddy into a container on photondatum.space — it is a native systemd service
  and hosts Let's Encrypt state that should survive container restarts
- Keep the Caddyfile in version control at `configs/reverse-proxy/caddy/Caddyfile`;
  the live file at `/etc/caddy/Caddyfile` is the deployed copy
