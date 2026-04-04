# Design Decisions

Project-scoped conventions and deliberate choices that should be applied consistently across all future work.

---

## D-001 — Layer Ordering in Tables, Charts, and Diagrams

**Date:** 2026-03-25
**Status:** Active

**Decision:** When presenting the technology stack in any visual or tabular format, layers are ordered user-first (closest to the user at top, closest to infrastructure at bottom).

**Order:**

| # | Layer | Rationale |
|---|---|---|
| 1 | Application | What the user directly interacts with |
| 2 | Edge | The gateway the user passes through (routing + auth) |
| 3 | Inference | The AI engine the applications delegate to |
| 4 | Knowledge | The RAG pipeline feeding the inference layer |
| 5 | Storage | Persistence underpinning all layers above |
| 6 | Observability | Operator-facing; last because users never directly interact with it |

**Within each layer**, order components by the one most directly exposed to the caller first (e.g., LiteLLM before Ollama/vLLM in Inference; Grafana before Prometheus/Loki/Promtail in Observability).

**Rationale:** Consistent user-centric ordering lets readers locate information quickly without re-orienting between documents. It also matches the mental model of "what calls what" when reasoning about the system.

---

## D-002 — Future: mTLS for Node Authentication

**Date:** 2026-04-04
**Status:** Deferred

**Decision:** Do not implement mTLS for node-to-controller authentication at this time. Use per-node API keys issued on join (see current implementation). Revisit mTLS when moving toward a full internal service mesh.

**Deferred because:**
- Requires a signing CA on the controller — new key material to protect and back up
- Traefik would need `clientAuth` reconfigured or TLS termination moved into FastAPI
- Every `curl` call in `heartbeat.sh`, `node.sh`, `bootstrap.sh` would need `--cert/--key/--cacert` flags and Darwin-vs-Linux cert path branches
- Cert lifecycle / renewal workflow adds ongoing operational overhead
- API keys are sufficient for this threat model (intranet, nodes behind firewall)

**When to revisit:** If the stack adopts an internal mTLS service mesh (e.g., Traefik internal routing with mutual TLS between all services), node authentication should be migrated to client certificates at that time to stay consistent with the mesh model.
