# Roles

Role documents define the abstract deployment blueprint for a class of node.
Each role specifies which deployment groups it owns, what it depends on, which
scripts support it, and what an instance overlay must provide to make it concrete.

Roles are not host-specific. The per-host customizations (IP addresses, domain
names, network mode, resource limits) live in [docs/instances/](../instances/).

---

## Architecture Diagram

```mermaid
flowchart TB
    subgraph EDGE["Edge Role — photondatum.space (always-on VPS)"]
        subgraph IAM["ai-stack-iam"]
            A_PG[(postgres-iam)]
            A_REDIS[(redis)]
            AUTHENTIK[authentik]
        end
        subgraph MESH["ai-stack-mesh"]
            HEADSCALE[headscale + DERP]
            HEADPLANE[headplane]
        end
        subgraph EDGEG["ai-stack-edge"]
            CADDY[caddy]
        end
    end

    subgraph CTRL["Controller Role — CENTAURI (residential workstation)"]
        subgraph ROUTE["ai-stack-route"]
            TRAEFIK[traefik]
        end
        subgraph INFER["ai-stack-infer"]
            LITELLM[litellm]
            OLLAMA_C[ollama]
        end
        subgraph KNOW["ai-stack-know"]
            KI[knowledge-index]
            QDRANT[(qdrant)]
        end
        subgraph APP["ai-stack-app"]
            OWUI[openwebui]
            FLOWISE[flowise]
            HOMEPAGE[homepage]
        end
        subgraph STORE["ai-stack-store"]
            APP_PG[(postgres-app)]
        end
        subgraph OBS["ai-stack-obs"]
            GRAFANA[grafana]
            LOKI[loki]
            PROM[prometheus]
        end
    end

    subgraph WORKER["Worker Role — TC25 / SOL (inference nodes)"]
        OLLAMA_W[ollama]
    end

    %% Within ai-stack-iam
    A_PG --> AUTHENTIK
    A_REDIS --> AUTHENTIK

    %% Within ai-stack-edge
    CADDY -->|forward_auth| AUTHENTIK

    %% Within ai-stack-infer
    LITELLM --> OLLAMA_C

    %% Within ai-stack-know
    KI --> QDRANT
    KI -->|embeddings| LITELLM

    %% Within controller
    TRAEFIK --> OWUI & FLOWISE & GRAFANA & HOMEPAGE
    OWUI & FLOWISE --> LITELLM
    OWUI & FLOWISE --> APP_PG
    LOKI & PROM --> GRAFANA

    %% Cross-role: edge → controller
    AUTHENTIK -->|"SSO / forwardAuth"| TRAEFIK
    CADDY -->|"proxy *.photondatum.space"| TRAEFIK
    HEADSCALE -. tailnet .-> CTRL

    %% Cross-role: controller → worker
    HEADSCALE -. tailnet .-> WORKER
    LITELLM -->|"inference routing"| OLLAMA_W
```

**Solid arrows** — application-level request or data flow.
**Dotted arrows** — network-layer connectivity (Headscale tailnet provides the
transport; it does not route application traffic directly).

---

## Role Documents

### [edge-role.md](edge-role.md)

Always-on, publicly reachable host. Owns identity (`ai-stack-iam`), mesh
coordination (`ai-stack-mesh`), and public ingress (`ai-stack-edge`). Runs
Authentik as the SSO authority for the entire stack, Headscale for the WireGuard
overlay network, and Caddy as the public TLS-terminating reverse proxy. All other
roles depend on this one being up for external access and mesh enrollment to work.

**Deployment target:** VPS (photondatum.space)
**Groups:** `ai-stack-iam`, `ai-stack-mesh`, `ai-stack-edge`

---

### [controller-role.md](controller-role.md)

Primary compute node. Orchestrates AI inference, runs the knowledge pipeline,
hosts user-facing applications, and aggregates observability data from all nodes.
All AI workloads route through this role. Requires the edge role for external SSO
but remains functional on the LAN when the edge role is offline.

**Deployment target:** Residential workstation (CENTAURI)
**Groups:** `ai-stack-route`, `ai-stack-infer`, `ai-stack-know`, `ai-stack-app`, `ai-stack-store`, `ai-stack-obs`

---

### [worker-role.md](worker-role.md)

Inference extension node. Runs Ollama (and optionally vLLM) and registers with
the controller's heartbeat system. LiteLLM on the controller routes model requests
to registered workers automatically. Workers are additive — the stack functions
without them, they just add inference capacity or GPU access. Requires both the
edge role (for mesh enrollment) and the controller role (for registration).

**Deployment target:** Any inference-capable machine (TC25, SOL, or future nodes)
**Groups:** `ai-stack-infer` (subset — runtimes only, no gateway)
