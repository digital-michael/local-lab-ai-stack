# Redis — Security

## Network isolation

Redis must not be reachable outside the `ai-stack-iam` Podman network.
The published port (`127.0.0.1:6379`) is for host-level access only; containers
connect through the Podman network by hostname (`ai-stack-iam-redis`).

## Authentication

Redis 7+ supports `requirepass` for password authentication. For the IAM group,
Redis is only reachable from Authentik containers on the same Podman network
(private, not internet-exposed), so a password is optional but recommended for
defense in depth.

If you set a password:
1. Store it as a Podman secret: `printf '%s' '<password>' | podman secret create redis_password -`
2. Pass to Redis container: `Exec=redis-server --requirepass $(cat /run/secrets/redis_password)`
3. Pass to Authentik: `AUTHENTIK_REDIS__PASSWORD` env var from the same secret

## No public exposure

Redis must never be bound to `0.0.0.0` — it has no TLS by default and no
meaningful authentication without `requirepass`. The current configuration
(`127.0.0.1:6379`) is correct.
