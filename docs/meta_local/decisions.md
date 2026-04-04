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

---

## D-003 — Refactor Layer 2 Inference Tests to pytest (Tech Debt)

**Date:** 2026-04-04
**Status:** Deferred — P2

**Decision:** Replace `testing/layer2_remote_nodes.bats` (T-090–T-094) with a pytest file `testing/layer2_inference/` that parametrizes over all `inference`-capable nodes from `configs/nodes/*.json`.

**Problem with current state:**
- `layer2_remote_nodes.bats` discovers nodes by hardcoded `name` fields (`macbook-m1`, `alienware`). Any deployment with different node names silently skips all tests rather than failing.
- Test count is fixed at 2 workers (5 tests). A third node gets no coverage; a single-node deployment has 3 permanent skips.
- Controller-local inference (SERVICES GPU/CPU) has no layer-2 coverage at all.
- BATS has no parametrize equivalent — generating per-node test cases dynamically is not idiomatic.

**Target state:**
- New `testing/layer2_inference/` pytest suite mirroring layer5's conftest pattern.
- Parametrize over `configs/nodes/*.json` filtered to `capabilities` containing `"inference"`.
- Controller nodes (profile=controller) included, probing `localhost:11434`.
- Test IDs derived from `node_id` field (stable, portable).
- BATS file removed or reduced to a TCP-only reachability ping (no model/completion logic).

**Why deferred:**
- Current tests pass on this deployment; core inference functionality verified manually.
- Refactor is low-urgency until a third node or new deployment forces the issue.

**When to promote:** Adding a third inference node, onboarding a new deployment, or any failing skip-storm on a peer system.
