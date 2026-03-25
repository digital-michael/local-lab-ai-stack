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
