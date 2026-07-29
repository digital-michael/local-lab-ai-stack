# AI Stack — Architecture Overview

**Last Updated:** 2026-07-05
**Tag:** `pre-alpha`

This document is the current-state index for the local-lab-ai-stack. It captures
the group-based deployment model agreed upon during the pre-alpha design phase.
For per-component detail, see the role playbooks and library component docs linked below.

---

## Deployment Model

The stack is split into three **roles**. Each role is a collection of named
**deployment groups**. Each group maps to a Podman network, a set of containers,
and a systemd target.

```
Edge Role          →  always-on VPS (photondatum.space)
Controller Role    →  residential compute node (CENTAURI)
Worker Role        →  any inference-capable machine (TC25, SOL, ...)
```

Roles depend on each other in a fixed order:

```
Edge → Controller → Worker
```

Edge must be up for external SSO and mesh enrollment. Controller must be up for
workers to have anywhere to register. Workers are optional and additive.

---

## Deployment Groups

### Edge Role groups

| Group | Network | SystemD target | Services |
| --- | --- | --- | --- |
| `ai-stack-iam` | `ai-stack-iam` | `ai-stack-iam.target` | authentik, authentik-worker, postgres (IAM), redis |
| `ai-stack-mesh` | `host` | `ai-stack-mesh.target` | headscale, headplane + tailscale (systemd) |
| `ai-stack-edge` | `host` | `ai-stack-edge.target` | caddy + forgejo (native systemd, external) |

### Controller Role groups

| Group | Network | SystemD target | Services |
| --- | --- | --- | --- |
| `ai-stack-route` | `host` + all groups | `ai-stack-route.target` | traefik |
| `ai-stack-infer` | `ai-stack-infer` | `ai-stack-infer.target` | litellm, ollama, vllm (opt), turbo (one-shot) |
| `ai-stack-know` | `ai-stack-know` | `ai-stack-know.target` | knowledge-index, qdrant |
| `ai-stack-app` | `ai-stack-app` | `ai-stack-app.target` | openwebui, flowise, homepage |
| `ai-stack-store` | `ai-stack-store` | `ai-stack-store.target` | postgres (app) |
| `ai-stack-obs` | `ai-stack-obs` | `ai-stack-obs.target` | prometheus, grafana, loki, promtail |

### Worker Role groups (subset of infer)

| Group | Network | Services |
| --- | --- | --- |
| `ai-stack-infer` | `host` | ollama (+ vllm if GPU) |

---

## Naming Convention

```
Network:    ai-stack-{group}                     e.g. ai-stack-iam
Container:  ai-stack-{group}-{service}           e.g. ai-stack-iam-authentik
Volume:     ai-stack-{group}-{service}-data      e.g. ai-stack-iam-postgres-data
Quadlet:    ai-stack-{group}-{service}.container
Target:     ai-stack-{group}.target
```

Labels on every container:

```ini
Label=ai-stack.group=iam
Label=ai-stack.service=authentik
Label=com.docker.compose.project=ai-stack
```

Query all containers in a group: `podman ps --filter label=ai-stack.group=iam`

---

## Network Isolation

**Isolated mode (default — CENTAURI):** each group has its own Podman network.
Traefik joins all group networks to reach backends. Cross-group containers
declare multiple `Network=` entries in their quadlet.

**Combined mode (photondatum.space):** all containers share a single `ai-stack`
network. Lower overhead; suitable for RAM-constrained hosts.

Instance overlays specify which mode applies per deployment target.

---

## Storage Split

IAM storage and application storage are intentionally separate instances:

| Store | Group | Host | Serves |
| --- | --- | --- | --- |
| `ai-stack-iam-postgres` | `ai-stack-iam` | photondatum.space | Authentik only |
| `ai-stack-iam-redis` | `ai-stack-iam` | photondatum.space | Authentik task queue |
| `ai-stack-store-postgres` | `ai-stack-store` | CENTAURI | OpenWebUI, Flowise |
| `ai-stack-know-qdrant` | `ai-stack-know` | CENTAURI | Knowledge index (exclusive) |

No PostgreSQL instance is shared across these boundaries.

---

## External / Non-Containerized Services

| Service | Host | Manager | Reason not containerized |
| --- | --- | --- | --- |
| Caddy | photondatum.space | systemd | Holds Let's Encrypt state; native preferred |
| Headscale | photondatum.space | systemd | Native install on this host |
| Headplane | photondatum.space | systemd | Native install on this host |
| Forgejo | photondatum.space | systemd | External to ai-stack; auth via Authentik OIDC |
| Tailscale | every node | systemd | Requires host kernel networking (WireGuard) |

---

## Dependency Chain (startup order across roles)

```
1. ai-stack-iam-postgres + ai-stack-iam-redis     (edge — parallel)
2. ai-stack-iam-authentik
3. ai-stack-iam-authentik-worker
4. ai-stack-mesh-headscale + ai-stack-edge-caddy  (edge — parallel, no iam dep)

5. ai-stack-store-postgres + ai-stack-know-qdrant  (controller — parallel)
   ai-stack-obs-loki + ai-stack-obs-prometheus     (controller — parallel)
   ai-stack-infer-ollama                           (controller)

6. ai-stack-infer-litellm                          (after ollama)
   ai-stack-obs-grafana                            (after loki + prometheus)

7. ai-stack-know-index                             (after qdrant + litellm)
   ai-stack-app-openwebui + flowise + homepage     (after store-postgres + litellm)

8. ai-stack-route-traefik                          (any time; routes fail gracefully)
   ai-stack-obs-promtail                           (any time)
```

---

## Key Documents

| Document | Purpose |
| --- | --- |
| [docs/roles/edge-role.md](roles/edge-role.md) | Edge role — groups, dependencies, scripts, checklist |
| [docs/roles/controller-role.md](roles/controller-role.md) | Controller role — groups, dependencies, scripts, checklist |
| [docs/roles/worker-role.md](roles/worker-role.md) | Worker role — registration, dependencies, scripts, checklist |
| [docs/instances/photondatum.md](instances/photondatum.md) | photondatum.space instance overlay (edge-role) |
| [docs/instances/centauri.md](instances/centauri.md) | CENTAURI instance overlay (controller-role) |
| [docs/getting-started.md](getting-started.md) | First-install walkthrough |
| [docs/ai_stack_blueprint/ai_stack_architecture.md](ai_stack_blueprint/ai_stack_architecture.md) | Detailed component architecture (pre-alpha; reflects pre-group design) |

---

## Open Work (post pre-alpha)

| Item | Blocks |
| --- | --- |
| Authentik migration to edge VPS | External SSO for all services; `openwebui-public` Authentik bypass removal |
| Remove stale Traefik router `openwebui-public-com` | Cleanup — references `chat.photondatum.com` (not owned) |
| Garage replaces MinIO | Object storage for knowledge pipeline |
| Social login source config in Authentik | Google, GitHub, Microsoft, GitLab, BitBucket, Atlassian, Apple |
| VPS RAM upgrade (1 GB → 2 GB) | Required before deploying `ai-stack-iam` to photondatum.space |
| Expose remaining CENTAURI services externally | Caddy routes + DNS for flowise, grafana, etc. on `*.photondatum.space` |
| TurboQuant — wire when implementation available | `ai-stack-infer-turbo` slot reserved in controller-role |
