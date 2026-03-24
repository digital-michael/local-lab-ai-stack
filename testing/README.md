# testing/README.md
# AI Stack — Integration Test Suite

This directory contains the integration tests for the AI stack, organized by layer from fastest/cheapest to most comprehensive.

---

## Prerequisites

**BATS (Bash Automated Testing System) v1.2+**

```bash
# Fedora / RHEL
sudo dnf install bats

# Debian / Ubuntu
sudo apt install bats

# From source (latest)
git clone https://github.com/bats-core/bats-core.git
cd bats-core && sudo ./install.sh /usr/local
```

**Python 3.11+ and pytest** (required for Layer 3 and above)

```bash
pip install pytest httpx pytest-asyncio
```

**Additional tools used by tests**

| Tool | Used by | Install |
|------|---------|---------|
| `curl` | Layer 1-2 | `dnf install curl` |
| `openssl` | Layer 0 | usually pre-installed |
| `jq` | Layer 0 | `dnf install jq` |
| `pg_isready` | Layer 1 | `dnf install postgresql` |
| `podman` | Layer 0-2 | pre-installed (stack requirement) |

---

## Directory Structure

```
testing/
  README.md                    ← this file
  helpers.bash                 ← shared env variables and curl helpers (loaded by all .bats files)

  # Layer 0 — Pre-flight
  layer0_preflight.bats        ← T-001–T-008: quadlets, service states, secrets, TLS

  # Layer 1 — Smoke
  layer1_smoke.bats            ← T-009–T-020, T-021a: port-level HTTP/TCP reachability (T-021a = MinIO)

  # Layer 2 — Component Integration   (planned)
  layer2_traefik.bats          ← T-021–T-024: routing, TLS, forward-auth middleware
  layer2_postgres.bats         ← T-025–T-027: SQL connectivity, schema
  layer2_qdrant.bats           ← T-028–T-030: CRUD cycle, gRPC
  layer2_litellm.bats          ← T-029–T-031: model list, key enforcement
  layer2_authentik.bats        ← T-033–T-035: liveness, readiness, config API
  layer2_grafana.bats          ← T-036–T-039: login, datasource provisioning, health
  layer2_prometheus.bats       ← T-040–T-042: targets, query API
  layer2_loki.bats             ← T-043–T-045: push, query, retention
  layer2_promtail.bats         ← T-046–T-047: metrics, log shipping
  layer2_flowise.bats          ← T-048–T-049: chatflows API, auth

  # Layer 2b — Lifecycle / Operational   (planned)
  layer2b_lifecycle.bats       ← T-050–T-054: reconfigure, upgrade, credential rotation, restart

  # Layer 3 — Model & Reasoning   (planned, Python/pytest)
  layer3_model/
    test_model_availability.py ← T-055–T-057: no-model gate, model pull, model list
    test_baseline_reasoning.py ← T-058–T-061: echo, arithmetic, classification, JSON output
    test_rag_pipeline.py       ← T-062–T-068: ingest, chunk, retrieve, update, delete
    test_higher_order.py       ← T-069–T-072: multi-turn, routing, failover, tool-calling

  # Layer 4 — Networking Profiles   (planned)
  layer4_localhost.bats        ← T-073–T-077: network isolation, DNS, forward-auth
  layer4_lan/                  ← T-078–T-081: deferred (D-014)
  layer4_wan/                  ← T-082–T-085: deferred (D-014)

  # Security
  security/
    test_auth_enforcement.py   ← T-086–T-092: auth gates, secrets, TLS, CVE scan, container users
```

---

## Execution Order

Run layers in sequence. Each layer assumes the previous has passed.

```bash
# Full suite (skip on first failure per layer)
bats testing/layer0_preflight.bats
bats testing/layer1_smoke.bats

# Individual layer
bats testing/layer0_preflight.bats

# All BATS files in order
bats testing/layer0_preflight.bats testing/layer1_smoke.bats

# Future: all layers including Python
bats testing/layer0_preflight.bats testing/layer1_smoke.bats
pytest testing/layer3_model/ -v
```

---

## Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `AI_STACK_DIR` | `$HOME/ai-stack` | Base directory of the deployed stack |
| `LITELLM_MASTER_KEY` | _(from secret)_ | API key for Layer 3 LiteLLM tests |
| `TEST_MODEL` | See `configs/models.json` | Model identifier used for reasoning tests |

---

## Conditional Tests

**Model-dependent tests (Layer 3+)**  
Tests in `layer3_model/` and above require at least one LLM to be loaded. The test suite handles this in two steps:

1. `test_model_availability.py::test_no_model_returns_structured_error` — runs with *no* model loaded. Asserts that LiteLLM returns a 4xx structured JSON error, not a 500 or unhandled panic. This test is expected to **pass** (the correct behavior is a clean error).

2. `test_model_availability.py::test_pull_default_models` — triggers model download using the `configs/models.json` default list. Polls until models appear in `/models` or times out. All subsequent reasoning tests depend on this passing.

**Deferred services (Layer 0/1)**  
Tests for `knowledge-index`, `vllm`, and `llamacpp` are tagged `@skip` until their images are available. They are listed in `SERVICES_DEFERRED` in `helpers.bash`.

---

## Adding New Tests

1. Determine the correct layer for the test.
2. Add to the appropriate `.bats` or `.py` file.
3. Assign the next T-number from `docs/ai_stack_testing.md`.
4. Update the test count and status column in the master plan doc.
