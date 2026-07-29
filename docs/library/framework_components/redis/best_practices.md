# Redis — Best Practices

- Keep Redis on the `ai-stack-iam` network only — no other group needs to reach it
- Bind Redis port to `127.0.0.1` only (`PublishPort=127.0.0.1:6379:6379`); the port
  is only needed for host-level debugging, not inter-container access (containers
  connect via the Podman network alias)
- Set `--maxmemory` to cap Redis memory use on RAM-constrained hosts (e.g., `--maxmemory 128m`)
  with `--maxmemory-policy allkeys-lru` to evict least-recently-used keys when full
- Authentik's Celery worker and server both connect to Redis; start Redis before either
  Authentik container
- For the IAM group, treat Redis as stateless — do not back it up; let Authentik
  rebuild task state on restart
- Consider Valkey as a drop-in if Redis license terms are a concern in your environment
