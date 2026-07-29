# Headscale — Guidance

Headscale is a self-hosted Tailscale control server. It manages the WireGuard
mesh overlay network, assigns CGNAT IPs (`100.64.0.0/10`), and serves an
embedded DERP relay for NAT traversal. It runs on the edge node (photondatum.space).

## Role in the stack

- Coordination: assigns IPs, manages node keys, distributes routes
- DERP relay: provides an always-reachable relay for nodes behind NAT
- ACL: enforces which nodes can reach which services
- Admin UI: Headplane (port 3001 on the tailnet IP)

## Critical configuration fields

Three fields must all be set when using embedded DERP — omitting any one causes
silent failure or startup crash:

```yaml
derp:
  server:
    enabled: true                          # false by default — /derp returns HTML when false
    region_id: 900
    region_code: headscale
    region_name: "Headscale"
    stun_listen_addr: 0.0.0.0:3478
    private_key_path: /var/lib/headscale/derp_server_private.key  # REQUIRED when enabled
  urls: []
  paths: []                                # REQUIRED empty — loaded derp.yaml causes region conflict
  auto_update_enabled: false
  update_frequency: 0s
```

`server_url` must be the actual domain, not a placeholder:
```yaml
server_url: https://headscale.photondatum.space
dns:
  base_domain: tailnet.photondatum.space   # Headscale uses this to build the embedded DERP hostname
```

## Verify DERP relay

```bash
curl http://127.0.0.1:8080/derp/probe     # must return: DERP ALIVE
# If it returns HTML, derp.server.enabled is false
tailscale netcheck                         # check relay reachability from any enrolled node
tailscale debug derp --region 900
```

## Enroll a node

```bash
# On the node to enroll:
tailscale up --login-server https://headscale.photondatum.space
# On the Headscale host (to approve the registration):
headscale nodes register --user <username> --key <node-key>
# Or use Headplane (http://100.64.0.5:3001) to approve via UI
```

## Common conflicts

**derper binary on UDP 3478:**
A standalone `derper` binary can occupy UDP 3478 at boot before Headscale starts.
Check: `ss -ulnp | grep :3478`
Fix: `sudo systemctl stop derper && sudo systemctl disable derper`

**Headplane port collision with Forgejo:**
Forgejo binds `0.0.0.0:3000`. Headplane cannot use port 3000 on the tailnet IP
on the same host. Configure Headplane on port 3001.

**Region ID collision:**
If `paths:` loads a `derp.yaml` that defines the same `region_id` as
`derp.server.region_id`, Headscale fails to start. Set `paths: []` and clear
`derp.yaml` to `regions: {}`.
