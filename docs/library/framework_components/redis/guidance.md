# Redis — Guidance

Redis (or the compatible drop-in Valkey) is used in the `ai-stack-iam` group
as Authentik's task queue broker and result cache. It is not used by any other
group in the current stack.

## Role in the stack

Authentik requires Redis for:
- Celery task queue (background jobs: policy refresh, outpost sync, email sending)
- Result backend (tracks task completion)
- Session cache (optional but recommended for performance)

Without Redis, Authentik starts but background tasks fail silently — outpost
sync stops working, scheduled policies do not run.

## Container in the IAM group

```
ai-stack-iam-redis    docker.io/library/redis:7
Network:              ai-stack-iam
Port bind:            127.0.0.1:6379:6379
```

## Authentik connection

Set in Authentik environment:
```env
AUTHENTIK_REDIS__HOST=ai-stack-iam-redis
AUTHENTIK_REDIS__PORT=6379
```

If a password is set on Redis, also provide:
```env
AUTHENTIK_REDIS__PASSWORD=<secret>
```

## Data persistence

Redis data is ephemeral by default (in-memory only). For this use case — Authentik
task queue — losing the Redis data on restart means in-flight tasks are lost but
state is not permanently corrupted; Authentik recovers on next poll cycle.

If you want persistence: mount a volume at `/data` and pass `--save 60 1` to Redis.
For this stack, persistence is optional for the IAM Redis instance.

## Valkey as alternative

Valkey is a community fork of Redis 7 under the BSD license (Redis 7.4+ moved to
SSPL). Valkey is API-compatible; swap the image from `redis:7` to `valkey/valkey:8`.
No other configuration changes needed.
