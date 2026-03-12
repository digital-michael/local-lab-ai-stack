.PHONY: help test test-bats test-pytest \
        test-preflight test-smoke \
        test-authentik test-flowise test-grafana test-litellm test-loki \
        test-postgres test-prometheus test-promtail test-qdrant test-traefik \
        test-lifecycle test-localhost \
        test-model test-baseline test-higher-order test-availability test-rag test-security

BATS := bats
PYTEST := python -m pytest

# ── Help ─────────────────────────────────────────────────────────────────────

help:
	@echo ""
	@echo "Usage: make <target>"
	@echo ""
	@echo "Full suites"
	@echo "  test              Run all BATS layers, wait for service readiness, then all pytest"
	@echo "  test-bats         All BATS layers (0, 1, 2, 2b, 4)"
	@echo "  test-pytest       All pytest (layer3 model + security)"
	@echo "  wait-services     Wait for LiteLLM readiness; restart cascade-stopped deferred services"
	@echo ""
	@echo "BATS targets — infrastructure & service health"
	@echo "  test-preflight    Layer 0: host env, quadlet files, secrets, network, TLS"
	@echo "  test-smoke        Layer 1: every service returns a healthy HTTP status"
	@echo "  test-authentik    Layer 2: Authentik /api and /health endpoints"
	@echo "  test-flowise      Layer 2: Flowise account auth and 401 rejection"
	@echo "  test-grafana      Layer 2: Grafana API health"
	@echo "  test-litellm      Layer 2: LiteLLM /models auth and 401 rejection"
	@echo "  test-loki         Layer 2: Loki ready and push/query"
	@echo "  test-postgres     Layer 2: Postgres connectivity"
	@echo "  test-prometheus   Layer 2: Prometheus metrics and targets"
	@echo "  test-promtail     Layer 2: Promtail ready"
	@echo "  test-qdrant       Layer 2: Qdrant REST health, CRUD cycle, gRPC port"
	@echo "  test-traefik      Layer 2: Traefik HTTP→HTTPS redirect, API"
	@echo "  test-lifecycle    Layer 2b: service restart behaviour"
	@echo "  test-localhost    Layer 4: cross-container networking, TLS cert, proxy redirect"
	@echo ""
	@echo "pytest targets — model behaviour & security"
	@echo "  test-model        All layer3_model pytest tests"
	@echo "  test-baseline     Baseline reasoning (echo, arithmetic, classification, JSON)"
	@echo "  test-higher-order Multi-turn context, model routing, failover, tool-calling"
	@echo "  test-availability Model list, pull, structured error on missing model"
	@echo "  test-rag          RAG pipeline: ingest, Qdrant storage, retrieval, Flowise chatflow"
	@echo "  test-security     Auth enforcement: forwardAuth, port binding, secret leakage"
	@echo ""
	@echo "Layer coverage summary"
	@echo "  BATS layer0   Host preflight — quadlet files, secrets, network, TLS"
	@echo "  BATS layer1   HTTP smoke — every service returns a healthy status code"
	@echo "  BATS layer2   Per-component API contracts (Qdrant CRUD, LiteLLM auth, etc.)"
	@echo "  BATS layer2b  Service lifecycle (restart behaviour); restarts ALL deployed services"
	@echo "  BATS layer4   Cross-container networking, TLS cert, Traefik proxy"
	@echo "  pytest layer3 Model behaviour — reasoning, routing, tool-calling, RAG pipeline"
	@echo "  pytest sec    Auth enforcement — forwardAuth redirect, port binding, secrets"
	@echo "  NOTE: 'make test' inserts wait-services between BATS and pytest to allow"
	@echo "        services restarted by layer2b to fully recover before pytest runs."
	@echo ""



# All BATS + pytest (with a readiness wait between them)
test: test-bats wait-services test-pytest

# Wait for LiteLLM readiness and restart deferred services that may have been
# cascade-stopped by lifecycle tests (knowledge-index requires ollama).
wait-services:
	@echo "Waiting for LiteLLM readiness..."
	@for i in $$(seq 1 30); do \
	    if curl -sf http://localhost:9000/health/readiness >/dev/null 2>&1; then \
	        echo "LiteLLM is ready."; break; \
	    fi; \
	    echo "  ($${i}/30) not ready yet, waiting 5s..."; \
	    sleep 5; \
	done
	@echo "Waiting for Flowise readiness..."
	@for i in $$(seq 1 12); do \
	    if curl -sf http://localhost:3001/api/v1/ping >/dev/null 2>&1; then \
	        echo "Flowise is ready."; break; \
	    fi; \
	    echo "  ($${i}/12) Flowise not ready yet, waiting 5s..."; \
	    sleep 5; \
	done
	@echo "Starting deferred services if inactive..."
	@systemctl --user is-active knowledge-index.service >/dev/null 2>&1 || \
	    systemctl --user start knowledge-index.service 2>/dev/null || true
	@for i in $$(seq 1 20); do \
	    if curl -sf http://localhost:8100/health >/dev/null 2>&1; then \
	        echo "knowledge-index is ready."; break; \
	    fi; \
	    if ! systemctl --user is-active knowledge-index.service >/dev/null 2>&1; then \
	        echo "knowledge-index is not active (DEFERRED service) — skipping."; break; \
	    fi; \
	    echo "  ($${i}/20) knowledge-index starting, waiting 3s..."; \
	    sleep 3; \
	done

# All BATS layers
test-bats:
	$(BATS) testing/layer0_preflight.bats \
	        testing/layer1_smoke.bats \
	        testing/layer2_authentik.bats testing/layer2_flowise.bats \
	        testing/layer2_grafana.bats testing/layer2_litellm.bats \
	        testing/layer2_loki.bats testing/layer2_postgres.bats \
	        testing/layer2_prometheus.bats testing/layer2_promtail.bats \
	        testing/layer2_qdrant.bats testing/layer2_traefik.bats \
	        testing/layer2b_lifecycle.bats \
	        testing/layer4_localhost.bats

# All pytest (layer3 + security)
test-pytest:
	$(PYTEST) -v

# ── BATS targets ─────────────────────────────────────────────────────────────

# Layer 0 — host pre-flight checks
test-preflight:
	$(BATS) testing/layer0_preflight.bats

# Layer 1 — service smoke tests
test-smoke:
	$(BATS) testing/layer1_smoke.bats

# Layer 2 — per-component integration
test-authentik:
	$(BATS) testing/layer2_authentik.bats

test-flowise:
	$(BATS) testing/layer2_flowise.bats

test-grafana:
	$(BATS) testing/layer2_grafana.bats

test-litellm:
	$(BATS) testing/layer2_litellm.bats

test-loki:
	$(BATS) testing/layer2_loki.bats

test-postgres:
	$(BATS) testing/layer2_postgres.bats

test-prometheus:
	$(BATS) testing/layer2_prometheus.bats

test-promtail:
	$(BATS) testing/layer2_promtail.bats

test-qdrant:
	$(BATS) testing/layer2_qdrant.bats

test-traefik:
	$(BATS) testing/layer2_traefik.bats

# Layer 2b — service lifecycle
test-lifecycle:
	$(BATS) testing/layer2b_lifecycle.bats

# Layer 4 — localhost / end-to-end
test-localhost:
	$(BATS) testing/layer4_localhost.bats

# ── pytest targets ───────────────────────────────────────────────────────────

# All layer3_model tests
test-model:
	$(PYTEST) -v testing/layer3_model/

# Baseline reasoning
test-baseline:
	$(PYTEST) -v testing/layer3_model/test_baseline_reasoning.py

# Higher-order model behaviour (multi-turn, routing, failover, tool-calling)
test-higher-order:
	$(PYTEST) -v testing/layer3_model/test_higher_order.py

# Model availability (list, pull, error handling)
test-availability:
	$(PYTEST) -v testing/layer3_model/test_model_availability.py

# RAG pipeline (knowledge-index ingest, retrieval, Flowise end-to-end)
test-rag:
	$(PYTEST) -v testing/layer3_model/test_rag_pipeline.py

# Security & auth enforcement
test-security:
	$(PYTEST) -v testing/security/
