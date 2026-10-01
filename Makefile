.PHONY: help test test-bats test-pytest \
        test-preflight test-smoke \
        test-authentik test-flowise test-grafana test-litellm test-loki \
        test-postgres test-prometheus test-promtail test-qdrant test-traefik \
        test-lifecycle test-localhost \
        test-model test-baseline test-higher-order test-availability test-security \
        license-check

BATS := bats
PYTEST := $(shell test -f .venv/bin/python && echo .venv/bin/python || echo python) -m pytest

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
# Exits on first BATS failure. Use 'test-all' to continue through known infra failures.
test: test-bats wait-services test-pytest

# Full test run that continues through BATS failures (e.g. pre-existing T-019/T-023/T-047).
# Always runs wait-services then pytest even if BATS has failures.
test-all:
	-$(MAKE) test-bats
	$(MAKE) wait-services
	$(MAKE) test-pytest

# Wait for LiteLLM and Flowise readiness.
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

# Higher-order model behaviour (multi-turn, routing, failover, tool-calling)
test-higher-order:
	$(PYTEST) -v testing/layer3_model/test_higher_order.py

# Model availability (list, pull, error handling)
test-availability:
	$(PYTEST) -v testing/layer3_model/test_model_availability.py

# Security & auth enforcement
test-security:
	$(PYTEST) -v testing/security/

# ── License check ────────────────────────────────────────────────────────────

# Scan the dev/test venv and emit a markdown table to docs/licenses/venv-snapshot.md.
# Requires pip-licenses: pip install pip-licenses
license-check:
	@echo "Scanning .venv with pip-licenses..."
	@.venv/bin/pip-licenses --format=markdown --with-urls \
	    --output-file=docs/licenses/venv-snapshot.md 2>/dev/null && \
	    echo "Written: docs/licenses/venv-snapshot.md" || \
	    (echo "pip-licenses not found — run: pip install pip-licenses" && exit 1)
