# AI Stack — Integration Testing Plan
**Last Updated:** 2026-03-08 UTC

## Purpose

This document is the authoritative test plan for the AI stack. It defines every planned test, organized by execution layer, with toolchain decisions, model management strategy, and traceability to the architecture and implementation docs.

An LLM agent should read this file to understand what is tested, what is deferred, and how to extend the test suite. All 92 test items are listed here. Test implementation files live in `./testing/`.

---

## Table of Contents

1. [Test Philosophy](#1-test-philosophy)
2. [Toolchain](#2-toolchain)
3. [Execution Order](#3-execution-order)
4. [Model Management Strategy](#4-model-management-strategy)
5. [Layer 0 — Pre-flight](#5-layer-0--pre-flight)
6. [Layer 1 — Smoke](#6-layer-1--smoke)
7. [Layer 2 — Component Integration](#7-layer-2--component-integration)
8. [Layer 2b — Lifecycle and Operational](#8-layer-2b--lifecycle-and-operational)
9. [Layer 3a — Model Availability and Loading](#9-layer-3a--model-availability-and-loading)
10. [Layer 3b — Baseline Reasoning](#10-layer-3b--baseline-reasoning)
11. [Layer 3c — RAG Pipeline](#11-layer-3c--rag-pipeline)
12. [Layer 3d — Higher-Order Reasoning](#12-layer-3d--higher-order-reasoning)
13. [Layer 4 — Networking Profiles](#13-layer-4--networking-profiles)
14. [Security Tests](#14-security-tests)
15. [Deferred Tests](#15-deferred-tests)

---

## 1 Test Philosophy

Tests are layered from fastest/cheapest to slowest/most expensive:

- **Layer 0** gates everything else. If pre-flight fails, no functional test is meaningful.
- **Layer 1** is a rapid go/no-go signal. It runs in under 30 seconds with zero auth.
- **Layer 2** validates each component's internal plumbing in isolation.
- **Layer 2b** validates operational correctness: can the stack be reconfigured, upgraded, and credential-rotated without data loss or downtime?
- **Layer 3** validates the AI data plane: model loading, reasoning quality, and RAG correctness.
- **Layer 4** validates network boundary assumptions per deployment profile.
- **Security** tests cut across all layers and must run before any production deployment.

Tests in later layers may be skipped if an earlier layer fails. The suite is designed so skipped tests are surfaced clearly with a reason, not silently omitted.

---

## 2 Toolchain

| Layer | Tool | Rationale |
|-------|------|-----------|
| 0–2, 2b, 4 | **BATS** (bats-core v1.2+) | Shell-native, zero extra runtime, mirrors existing scripts, readable by both humans and LLM agents |
| 3a–3d, Security | **pytest + httpx** | Structured assertions on JSON, async HTTP, parametrised test cases, rich skip/xfail semantics — necessary for multi-step reasoning and RAG tests |
| Security scanning | **trivy** or **grype** | CVE scanning of deployed container image layers |

Install:
```bash
# BATS
sudo dnf install bats        # or: git clone bats-core + ./install.sh

# pytest stack
pip install pytest httpx pytest-asyncio
```

---

## 3 Execution Order

```
Layer 0  →  Layer 1  →  Layer 2  →  Layer 2b  →  Layer 3a  →  Layer 3b  →  Layer 3c  →  Layer 3d  →  Layer 4  →  Security
```

Minimum viable run for a post-deploy sanity check:
```bash
bats testing/layer0_preflight.bats testing/layer1_smoke.bats
```

Full suite (once all layers are implemented):
```bash
bats testing/layer0_preflight.bats \
     testing/layer1_smoke.bats \
     testing/layer2_*.bats \
     testing/layer2b_lifecycle.bats \
     testing/layer4_localhost.bats
pytest testing/layer3_model/ testing/security/ -v
```

---

## 4 Model Management Strategy

### 4.1 Default Models List

A `configs/models.json` file (to be created in Phase 8c) declares the models pulled at deploy time:

```json
{
  "default_models": [
    {
      "id": "llamacpp/phi-3-mini-4k-instruct-q4",
      "backend": "llamacpp",
      "url": "https://huggingface.co/microsoft/Phi-3-mini-4k-instruct-gguf/resolve/main/Phi-3-mini-4k-instruct-q4.gguf",
      "path": "$AI_STACK_DIR/models/phi-3-mini-4k-instruct-q4.gguf"
    }
  ]
}
```

`scripts/deploy-stack.sh` will call a `pull-models.sh` script to download all listed models before starting GPU-dependent services.

### 4.2 No-Model Gate (T-055)

Before Layer 3b runs, **T-055** fires with no model loaded. It sends a `POST /chat/completions` request and asserts:
- HTTP 4xx returned (not 5xx — no panics, no unhandled exceptions)
- Response body is valid JSON with an `error` field
- LiteLLM process does not exit or restart

This test is expected to **pass** — clean error handling is the correct behaviour. It is not a "skip" — it runs unconditionally.

### 4.3 Model Pull Test (T-056)

T-056 triggers model download via `pull-models.sh` (or direct API call to llama.cpp if it supports dynamic load). It then polls `GET /models` with a 5-minute timeout until the model appears. If the model is already present (idempotent re-run), T-056 passes immediately.

### 4.4 Model Routing in Tests

All Layer 3b+ tests use the `TEST_MODEL` environment variable (defaulting to the first model in `configs/models.json`) to specify which model to test against. Tests set `"model": "$TEST_MODEL"` in any completion request.

---

## 5 Layer 0 — Pre-flight

**File:** `testing/layer0_preflight.bats`  
**Run time:** < 5 seconds  
**Gate:** Must pass 100% before any other layer runs.

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-001 | Quadlet `.container` files exist for all 14 services | All 14 files present in `~/.config/containers/systemd/` | Active |
| T-002 | All deployed services are active | `systemctl --user is-active` returns 0 for all 11 deployed services | Active |
| T-003 | No deployed service is in failed state | `ActiveState != failed` for all 11 deployed services | Active |
| T-004 | All 6 required Podman secrets exist | `podman secret inspect` returns 0 for each secret name | Active |
| T-005 | `ai-stack` Podman network exists | `podman network inspect ai-stack` returns 0 | Active |
| T-006 | TLS cert and key files present | Both `cert.pem` and `key.pem` exist at `$AI_STACK_DIR/configs/tls/` | Active |
| T-007 | TLS certificate is not expired | `openssl x509 -checkend 0` returns 0 | Active |
| T-008 | `configure.sh` re-run is idempotent | Script exits 0; quadlet file count unchanged | Active |

---

## 6 Layer 1 — Smoke

**File:** `testing/layer1_smoke.bats`  
**Run time:** < 30 seconds  
**Gate:** Confirms each service is responding before functional tests begin.

| ID | Description | Endpoint | Pass Criterion | Status |
|----|-------------|----------|----------------|--------|
| T-009 | Traefik HTTP → HTTPS redirect | `http://localhost/` | HTTP 301 | Active |
| T-010 | Traefik API version | `http://localhost:8080/api/version` | 200, body contains `Version` | Active |
| T-011 | Traefik ping | `http://localhost:8080/ping` | 200, body `OK` | Active |
| T-012 | Prometheus healthy | `http://localhost:9091/-/healthy` | HTTP 200 | Active |
| T-013 | Grafana health | `http://localhost:3000/api/health` | 200, body `"database":"ok"` | Active |
| T-014 | Loki ready | `http://localhost:3100/ready` | 200, body `ready` | Active |
| T-015 | Qdrant REST root | `http://localhost:6333/` | 200, body contains `version` | Active |
| T-016 | LiteLLM health | `http://localhost:9000/health` | HTTP 200 | Active |
| T-017 | OpenWebUI root | `http://localhost:9090/` | HTTP 200 | Active |
| T-018 | Flowise root | `http://localhost:3001/` | HTTP 200 | Active |
| T-019 | Authentik via Traefik | `https://authentik.localhost/` | 200 or 302; skip if route not configured | Active (conditional) |
| T-020 | Postgres TCP port | `localhost:5432` | `pg_isready` returns 0 or TCP connect succeeds | Active |

---

## 7 Layer 2 — Component Integration

**Files:** `testing/layer2_<component>.bats`  
**Run time:** 2–5 minutes  
**Gate:** Validates internal plumbing of each component individually.

### Traefik (layer2_traefik.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-021 | Router list shows all expected routes | `GET /api/http/routers` contains entries for openwebui, grafana, flowise, authentik | Planned |
| T-022 | HTTP→HTTPS redirect carries correct Location header | 301 response Location begins with `https://` | Planned |
| T-023 | TLS cert on :443 has correct SAN | `openssl s_client` output contains `*.localhost` | Planned |
| T-024 | Forward-auth middleware attached to proxied routers | `/api/http/routers` shows `middlewares` containing `authentik` for each user-facing route | Planned |

### Postgres (layer2_postgres.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-025 | TCP connect and `SELECT 1` | `psql` query returns `1` | Planned |
| T-026 | `authentik` database exists | `\l` output contains `authentik` | Planned |
| T-027 | Password auth with provisioned secret | Connection with secret value succeeds; wrong password returns auth error | Planned |

### Qdrant (layer2_qdrant.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-028 | `GET /collections` returns 200 | Response is valid JSON array | Planned |
| T-029 | Full CRUD cycle | Create collection → insert vector → query nearest → delete → collection gone | Planned |
| T-030 | gRPC port 6334 accepts connection | TCP connect to 6334 succeeds | Planned |

### LiteLLM (layer2_litellm.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-031 | `GET /models` returns structured response | 200, body is valid JSON | Planned |
| T-032 | Unauthenticated request returns 401 | `POST /chat/completions` without `Authorization` header returns 401 | Planned |

### Authentik (layer2_authentik.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-033 | Config API returns 200 | `GET /api/v3/root/config/` returns 200 with JSON | Planned |
| T-034 | Liveness probe | `GET /-/health/live/` returns 200 | Planned |
| T-035 | Readiness probe (migrations complete) | `GET /-/health/ready/` returns 200 | Planned |

### Grafana (layer2_grafana.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-036 | Login API returns session token | `POST /api/login` with admin credentials returns token | Planned |
| T-037 | Provisioned datasources exist | `GET /api/datasources` returns entries for Prometheus and Loki | Planned |
| T-038 | Prometheus datasource health | `GET /api/datasources/1/health` returns `{"status":"OK"}` | Planned |
| T-039 | Loki datasource health | `GET /api/datasources/2/health` returns `{"status":"OK"}` | Planned |

### Prometheus (layer2_prometheus.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-040 | Scrape targets listed | `GET /api/v1/targets` returns all configured targets | Planned |
| T-041 | All targets healthy | All targets in response have `health: "up"` (known-bad flagged explicitly) | Planned |
| T-042 | Query API functional | `GET /api/v1/query?query=up` returns result vector | Planned |

### Loki (layer2_loki.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-043 | Push test log entry | `POST /loki/api/v1/push` returns 204 | Planned |
| T-044 | Query returns pushed entry | `GET /loki/api/v1/query_range` with matching labels returns the pushed line | Planned |
| T-045 | Retention config readable | `GET /config` output contains `retention_period: 168h` | Planned |

### Promtail (layer2_promtail.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-046 | Metrics endpoint responds | `GET http://promtail.ai-stack:9080/metrics` (via `podman exec`) returns Prometheus metrics | Planned |
| T-047 | Log line appears in Loki | Write a line to a watched path; verify it appears in `query_range` within 30s | Planned |

### Flowise (layer2_flowise.bats)

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-048 | Chatflows API returns array | `GET /api/v1/chatflows` returns 200 JSON array | Planned |
| T-049 | Unauthenticated request rejected | Request without credentials returns 401 | Planned |

---

## 8 Layer 2b — Lifecycle and Operational

**File:** `testing/layer2b_lifecycle.bats`  
**Run time:** 5–15 minutes (service restarts required)  
**Gate:** Validates that operational procedures work correctly.

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-050 | Reconfigure: config.json update propagates | Change a non-critical field in config.json, re-run `configure.sh`, `systemctl --user daemon-reload`, confirm quadlet reflects new value | Planned |
| T-051 | Component upgrade: pull new image, service restarts healthy | `podman pull <image>:<newtag>`, update config.json tag, redeploy service, Layer 1 smoke passes for that service | Planned |
| T-052 | Credential rotation: new secret accepted, old rejected | Update Podman secret value, restart dependent service, verify auth with new value succeeds and old value fails | Planned |
| T-053 | Individual service restart: returns to healthy | `systemctl --user restart <svc>`, verify Layer 1 smoke passes within 60s | Planned |
| T-054 | Full cold-boot: all services stop then start in order | Stop all services, start in dependency order, full Layer 1 passes | Planned |

---

## 9 Layer 3a — Model Availability and Loading

**File:** `testing/layer3_model/test_model_availability.py`  
**Run time:** 1–10 minutes (model download may be slow)  
**Gate:** Required before any reasoning tests run.

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-055 | No-model gate: structured error returned | `POST /chat/completions` with no backends → 4xx JSON with `error` field; LiteLLM does not crash | Planned |
| T-056 | Default model pull | Run `pull-models.sh`; model appears in `GET /models` within timeout | Planned |
| T-057 | Model list non-empty after pull | `GET /models` returns at least one model entry matching `configs/models.json` | Planned |

---

## 10 Layer 3b — Baseline Reasoning

**File:** `testing/layer3_model/test_baseline_reasoning.py`  
**Run time:** 1–3 minutes  
**Requires:** T-055–T-057 passing; `TEST_MODEL` set or defaulted.

| ID | Description | Prompt | Pass Criterion | Status |
|----|-------------|--------|----------------|--------|
| T-058 | Echo / identity | `"Repeat the word 'canary' exactly once."` | Response contains `canary` (case-insensitive) | Planned |
| T-059 | Arithmetic | `"What is 17 + 25? Respond with just the number."` | Response body contains `42` | Planned |
| T-060 | Classification | `"Is the following positive or negative: 'I love this.' Reply with exactly one word."` | Response is `positive` (case-insensitive) | Planned |
| T-061 | JSON output | `"Return a JSON object with one key 'status' set to 'ok'. Return only valid JSON."` | Response is valid JSON; `.status == "ok"` | Planned |

---

## 11 Layer 3c — RAG Pipeline

**File:** `testing/layer3_model/test_rag_pipeline.py`  
**Run time:** 3–10 minutes  
**Requires:** T-055–T-057 passing; knowledge-index image built and knowledge-index service active.

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-062 | Document ingest | POST test document to knowledge-index API → 200, document ID returned | Planned |
| T-063 | Chunk storage in Qdrant | After ingest, Qdrant collection count increases by ≥ 1 | Planned |
| T-064 | Retrieval via knowledge-index API | Query with a question whose answer is in the ingested doc → relevant chunk returned with metadata | Planned |
| T-065 | RAG metadata plumbing | Retrieval response includes `source` attribute referencing the original document | Planned |
| T-066 | End-to-end via Flowise chatflow | Flowise chatflow → knowledge-index → Qdrant → LiteLLM → response contains source citation | Pass |
| T-067 | Document update | Re-ingest modified document; query returns updated chunk, not old chunk | Planned |
| T-068 | Document delete | Delete document from index; subsequent query no longer returns that chunk | Planned |

---

## 12 Layer 3d — Higher-Order Reasoning

**File:** `testing/layer3_model/test_higher_order.py`  
**Run time:** 3–10 minutes  
**Requires:** T-055–T-057 passing.

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-069 | Multi-turn context retention | Turn 1: introduce a name. Turn 2: ask for it. Response contains the name. | Planned |
| T-070 | Model routing: llamacpp | Request with `model: llamacpp/<id>` is routed to llama.cpp, not vLLM | Planned |
| T-071 | Failover: vLLM disabled | Stop `vllm.service`; request without explicit model routing succeeds via llama.cpp fallback | Planned |
| T-072 | Tool-calling / function-calling | Send function-calling request → response contains `tool_calls` array with correct structure | Planned |

---

## 13 Layer 4 — Networking Profiles

### 4a — localhost profile (Active)

**File:** `testing/layer4_localhost.bats`

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-073 | Services bound to loopback only | `ss -tlnp` or `podman port` shows host address `127.0.0.1`, not `0.0.0.0` | Planned |
| T-074 | Container-to-container DNS resolves | `podman exec traefik curl -sf http://litellm.ai-stack:4000/health` returns 200 | Planned |
| T-075 | Cross-container reachability | At least 3 inter-service curl checks pass from within the network | Planned |
| T-076 | TLS cert is self-signed | `openssl s_client -connect localhost:443` shows Issuer matching our local CA, not a public CA | Planned |
| T-077 | Forward-auth blocks unauthenticated access | Request to proxied service without session cookie → redirect to Authentik login | Planned |

### 4b — local (LAN) profile (Deferred — D-014)

| ID | Description | Status |
|----|-------------|--------|
| T-078 | mDNS advertisement visible on LAN | Deferred |
| T-079 | Knowledge volume checksum validates | Deferred |
| T-080 | Traefik bound to LAN interface | Deferred |
| T-081 | Second node SSO via Authentik | Deferred |

### 4c — WAN profile (Deferred — D-014)

| ID | Description | Status |
|----|-------------|--------|
| T-082 | Valid public TLS cert | Deferred |
| T-083 | OIDC token accepted from remote IP | Deferred |
| T-084 | Knowledge volume signature verified | Deferred |
| T-085 | Rate limiting / WAF active on edge | Deferred |

---

## 14 Security Tests

**File:** `testing/security/test_auth_enforcement.py`  
**Run time:** 5–15 minutes  
**Requires:** Layer 2 passing. Must pass before any production deployment.

| ID | Description | Pass Criterion | Status |
|----|-------------|----------------|--------|
| T-086 | Forward-auth blocks all proxied services without session | Each user-facing proxied service returns 302 → Authentik when no auth cookie present | Planned |
| T-087 | Internal services not reachable from host | Qdrant :6333, Postgres :5432, LiteLLM :9000 bound to `127.0.0.1` only; not accessible from another host | Planned |
| T-088 | Secrets never appear in container environment | `podman inspect` output for each service contains no plaintext values matching known secret values | Planned |
| T-089 | No sensitive data over cleartext HTTP | HTTP endpoints return no JSON/HTML containing API keys, passwords, or token material | Planned |
| T-090 | LiteLLM master key enforced | All API routes return 401 without `Authorization` header | Planned |
| T-091 | Qdrant API key enforced | Requests to Qdrant without `api-key` header return 401 (when API key is configured) | Planned |
| T-092 | Containers do not run as root | `podman inspect --format '{{.Config.User}}'` for each deployed service returns a non-root user or UID | Planned |

**Security scanning (outside numbered suite):**
- `trivy image <image>` or `grype <image>` for all 11 deployed images — no CRITICAL CVEs in deployed layers. Run as a pre-upgrade gate when updating image tags.

---

## 15 Deferred Tests

| ID(s) | Reason | Tracked By |
|-------|--------|-----------|
| T-070–T-071 | Requires vLLM active (GPU) | Phase 8c |
| T-062–T-068 | Requires knowledge-index custom image | Phase 8d |
| T-078–T-085 | LAN/WAN networking profiles | D-014 |
| T-056 (pull) | Requires `configs/models.json` and `pull-models.sh` | Phase 8c |

---

*See `testing/README.md` for installation and execution instructions.*  
*See `docs/ai_stack_blueprint/ai_stack_architecture.md` for component topology.*
