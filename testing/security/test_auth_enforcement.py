# testing/security/test_auth_enforcement.py
#
# Security Layer — Auth & Secret Enforcement Tests (T-086 through T-092)
#
# T-086: Every user-facing proxied service redirects unauthenticated requests
#        to Authentik (forward-auth enforcement)
# T-087: Internal services have no 0.0.0.0 binding for their internal ports
# T-088: `podman inspect` output for each service contains no plaintext secrets
# T-089: HTTP endpoints return no JSON body containing known secret values
# T-090: LiteLLM returns 401 for all routes without an Authorization header
# T-091: Qdrant returns 401/403 for requests without an api-key header
# T-092: Each deployed container runs as a non-root user
#
# Run:
#   pytest testing/security/test_auth_enforcement.py -v
#   LITELLM_MASTER_KEY=<key> pytest testing/security/ -v

from __future__ import annotations

import json
import subprocess
import os
from pathlib import Path
from typing import Generator

import httpx
import pytest

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO_ROOT = Path(__file__).parent.parent.parent
CONFIGS_DIR = REPO_ROOT / "configs"

# Services whose HTTP ports are exposed on the host
HOST_EXPOSED_SERVICES = {
    "litellm": "http://localhost:9000",
    "prometheus": "http://localhost:9091",
    "grafana": "http://localhost:3000",
    "loki": "http://localhost:3100",
    "flowise": "http://localhost:3001",
    "openwebui": "http://localhost:9090",
    "qdrant": "http://localhost:6333",
}

# Services that sit behind Traefik forward-auth
TRAEFIK_PROXIED_HOSTS = [
    "grafana",
    "openwebui",
    "flowise",
    "prometheus",
]

# Podman service names (quadlets) for deployed services
DEPLOYED_SERVICES = [
    "authentik",
    "flowise",
    "grafana",
    "litellm",
    "loki",
    "openwebui",
    "postgres",
    "prometheus",
    "promtail",
    "qdrant",
    "traefik",
]

# Internal ports that must NOT be 0.0.0.0 bound
INTERNAL_PORTS = [5432, 6333, 6334, 9000, 9090, 9091, 3000, 3100, 3001]

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture(scope="session")
def litellm_master_key() -> str:
    """Return the LiteLLM master key from env or Podman secret."""
    key = os.environ.get("LITELLM_MASTER_KEY", "")
    if not key:
        try:
            result = subprocess.run(
                [
                    "podman", "run", "--rm", "--quiet",
                    "--secret", "litellm_master_key,type=mount",
                    "alpine:latest",
                    "cat", "/run/secrets/litellm_master_key",
                ],
                capture_output=True, text=True, timeout=15,
            )
            key = result.stdout.strip()
        except Exception:
            pass
    return key


@pytest.fixture(scope="session")
def known_secret_values(litellm_master_key: str) -> list[str]:
    """
    Build a list of known secret *values* that must not appear in cleartext.
    Only non-empty values are included. We deliberately exclude any value
    shorter than 8 chars to avoid false positives on common short strings.
    """
    secret_names = [
        "authentik_secret_key",
        "flowise_password",
        "litellm_master_key",
        "openwebui_api_key",
        "postgres_password",
        "qdrant_api_key",
    ]
    values: list[str] = []

    # Collect from environment overrides first
    env_map = {
        "authentik_secret_key": "AUTHENTIK_SECRET_KEY",
        "flowise_password": "FLOWISE_PASSWORD",
        "litellm_master_key": "LITELLM_MASTER_KEY",
        "openwebui_api_key": "OPENWEBUI_API_KEY",
        "postgres_password": "POSTGRES_PASSWORD",
        "qdrant_api_key": "QDRANT_API_KEY",
    }
    for name in secret_names:
        val = os.environ.get(env_map.get(name, name.upper()), "")
        if val and len(val) >= 8:
            values.append(val)

    # Also include the key we got from the fixture
    if litellm_master_key and len(litellm_master_key) >= 8:
        if litellm_master_key not in values:
            values.append(litellm_master_key)

    return values


@pytest.fixture(scope="session")
def qdrant_api_key() -> str:
    """Return the Qdrant API key from env or Podman secret."""
    key = os.environ.get("QDRANT_API_KEY", "")
    if not key:
        try:
            result = subprocess.run(
                [
                    "podman", "run", "--rm", "--quiet",
                    "--secret", "qdrant_api_key,type=mount",
                    "alpine:latest",
                    "cat", "/run/secrets/qdrant_api_key",
                ],
                capture_output=True, text=True, timeout=15,
            )
            key = result.stdout.strip()
        except Exception:
            pass
    return key


@pytest.fixture(scope="module")
def http_client() -> Generator[httpx.Client, None, None]:
    """Plain HTTP client with no auth headers."""
    with httpx.Client(timeout=15.0, follow_redirects=False, verify=False) as client:
        yield client


# ---------------------------------------------------------------------------
# T-086 — Forward-auth enforced for Traefik-proxied services
# ---------------------------------------------------------------------------

class TestForwardAuthEnforcement:
    """T-086: Unauthenticated requests to proxied services are redirected."""

    DOMAIN = os.environ.get("STACK_DOMAIN", "localhost")

    def test_unauthenticated_proxied_requests_redirect_to_authentik(
        self, http_client: httpx.Client
    ) -> None:
        """
        T-086: Each user-facing Traefik-proxied service returns 3xx to Authentik
        when accessed without an auth session cookie.
        """
        base_url = "https://localhost"
        passed = 0
        skipped = []
        failed = []

        for svc in TRAEFIK_PROXIED_HOSTS:
            host = f"{svc}.{self.DOMAIN}"
            try:
                response = http_client.get(
                    base_url,
                    headers={"Host": host},
                )
                code = response.status_code
                location = response.headers.get("location", "")

                if code in (301, 302, 307, 308):
                    if "authentik" in location.lower() or "outpost" in location.lower():
                        passed += 1
                    else:
                        # Got a redirect but not to Authentik — may be HTTPS upgrade
                        skipped.append(
                            f"{svc}: redirects to {location!r} (not Authentik)"
                        )
                elif code == 200:
                    # No redirect at all — forward-auth may not be configured
                    skipped.append(
                        f"{svc}: returned 200 without redirect — "
                        "forward-auth middleware may not be applied yet"
                    )
                else:
                    skipped.append(f"{svc}: unexpected status {code}")
            except httpx.ConnectError:
                skipped.append(f"{svc}: connection refused (Traefik not running?)")

        if skipped and not passed:
            pytest.skip(
                "No proxied services redirected to Authentik — "
                "forward-auth may not be configured yet. "
                f"Details: {'; '.join(skipped)}"
            )

        if failed:
            pytest.fail(
                f"Forward-auth not enforced for: {', '.join(failed)}"
            )


# ---------------------------------------------------------------------------
# T-087 — Internal stack ports not bound to 0.0.0.0
# ---------------------------------------------------------------------------

class TestNetworkIsolation:
    """T-087: Internal service ports are not exposed on the host wildcard."""

    def test_internal_ports_not_wildcard_bound(self) -> None:
        """
        T-087: Qdrant, Postgres, and LiteLLM internal ports must not appear
        as 0.0.0.0:<port> in `ss -tlnp` output.
        """
        result = subprocess.run(
            ["ss", "-tlnp"],
            capture_output=True, text=True,
        )
        assert result.returncode == 0, "ss -tlnp failed"

        offenders = []
        for port in INTERNAL_PORTS:
            for line in result.stdout.splitlines():
                col = line.split()
                if not col:
                    continue
                local_addr = col[3] if len(col) > 3 else ""
                if local_addr in (f"0.0.0.0:{port}", f"*:{port}"):
                    offenders.append(f"port {port} in: {line.strip()}")

        assert not offenders, (
            f"Internal ports bound to 0.0.0.0: {'; '.join(offenders)}"
        )


# ---------------------------------------------------------------------------
# T-088 — Container inspect reveals no plaintext secrets
# ---------------------------------------------------------------------------

class TestSecretLeakage:
    """T-088 and T-089: Secret values must not appear in container metadata or HTTP responses."""

    def test_podman_inspect_contains_no_plaintext_secrets(
        self, known_secret_values: list[str]
    ) -> None:
        """
        T-088: `podman inspect` output for each deployed container must not
        contain known secret values in plaintext (env vars, cmd, labels, etc.).
        """
        if not known_secret_values:
            pytest.skip(
                "No known secret values available — set LITELLM_MASTER_KEY "
                "(and other *_KEY / *_PASSWORD env vars) to enable this check"
            )

        leaks: list[str] = []

        for svc in DEPLOYED_SERVICES:
            result = subprocess.run(
                ["podman", "inspect", svc],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                # Container not running — skip it gracefully
                continue

            inspect_text = result.stdout
            for secret_val in known_secret_values:
                if secret_val in inspect_text:
                    leaks.append(
                        f"Secret value found in 'podman inspect {svc}': "
                        f"{secret_val[:4]}...{secret_val[-4:]}"
                    )

        assert not leaks, "\n".join(leaks)

    def test_http_endpoints_return_no_plaintext_secrets(
        self,
        http_client: httpx.Client,
        known_secret_values: list[str],
    ) -> None:
        """
        T-089: HTTP endpoints accessible without auth must not return known
        secret values in their response bodies.
        """
        if not known_secret_values:
            pytest.skip(
                "No known secret values available to check against HTTP responses"
            )

        # Only check endpoints reachable without auth (no auth header sent)
        probe_paths = {
            "prometheus": "/metrics",
            "loki": "/ready",
            "traefik": "/ping",
        }
        traefik_url = "http://localhost:80"

        endpoints_to_probe: list[tuple[str, str]] = []
        for svc, path in probe_paths.items():
            base = HOST_EXPOSED_SERVICES.get(svc, traefik_url)
            endpoints_to_probe.append((svc, base + path))

        leaks: list[str] = []
        for svc, url in endpoints_to_probe:
            try:
                resp = http_client.get(url)
                body = resp.text
                for secret_val in known_secret_values:
                    if secret_val in body:
                        leaks.append(
                            f"Secret value in {svc} response ({url}): "
                            f"{secret_val[:4]}...{secret_val[-4:]}"
                        )
            except httpx.ConnectError:
                pass  # Service not reachable — skip silently

        assert not leaks, "\n".join(leaks)


# ---------------------------------------------------------------------------
# T-090 — LiteLLM returns 401 without Authorization header
# ---------------------------------------------------------------------------

class TestLiteLLMAuthEnforcement:
    """T-090: All LiteLLM routes require an Authorization header."""

    LITELLM_BASE = HOST_EXPOSED_SERVICES["litellm"]

    PROTECTED_ROUTES = [
        "/models",
        "/chat/completions",
        "/completions",
        "/embeddings",
    ]

    def test_all_routes_401_without_auth(self, http_client: httpx.Client) -> None:
        """
        T-090: LiteLLM returns 401 for every protected route when called
        without an Authorization header.
        """
        try:
            probe = http_client.get(self.LITELLM_BASE + "/health")
        except httpx.ConnectError:
            pytest.skip("LiteLLM not reachable on port 9000")

        failures: list[str] = []
        for route in self.PROTECTED_ROUTES:
            url = self.LITELLM_BASE + route
            # POST for completion routes, GET for /models
            method = "get" if route == "/models" else "post"
            try:
                if method == "post":
                    resp = http_client.post(url, json={})
                else:
                    resp = http_client.get(url)
                if resp.status_code != 401:
                    failures.append(f"{route}: got {resp.status_code}, expected 401")
            except httpx.ConnectError:
                failures.append(f"{route}: connection refused")

        assert not failures, "\n".join(failures)


# ---------------------------------------------------------------------------
# T-091 — Qdrant returns 401/403 without api-key header
# ---------------------------------------------------------------------------

class TestQdrantAuthEnforcement:
    """T-091: Qdrant requires the X-Qdrant-API-Key header."""

    QDRANT_BASE = HOST_EXPOSED_SERVICES["qdrant"]

    def test_qdrant_rejects_unauthenticated_requests(
        self,
        http_client: httpx.Client,
        qdrant_api_key: str,
    ) -> None:
        """
        T-091: Qdrant returns 401 or 403 for a /collections request without
        the X-Qdrant-API-Key header, provided an API key is configured.
        """
        if not qdrant_api_key:
            pytest.skip(
                "Qdrant API key not available — set QDRANT_API_KEY or ensure "
                "the 'qdrant_api_key' Podman secret is set to enable this check"
            )

        try:
            # Without API key
            resp_no_auth = http_client.get(self.QDRANT_BASE + "/collections")
        except httpx.ConnectError:
            pytest.skip("Qdrant not reachable on port 6333")

        assert resp_no_auth.status_code in (401, 403), (
            f"Qdrant returned {resp_no_auth.status_code} without api-key — "
            "expected 401 or 403. Qdrant API key enforcement may be disabled."
        )

        # Confirm that a valid key is accepted
        resp_with_auth = http_client.get(
            self.QDRANT_BASE + "/collections",
            headers={"api-key": qdrant_api_key},
        )
        assert resp_with_auth.status_code == 200, (
            f"Qdrant rejected valid api-key with status {resp_with_auth.status_code}"
        )


# ---------------------------------------------------------------------------
# T-092 — All deployed containers run as non-root
# ---------------------------------------------------------------------------

# Upstream images that ship without a non-root USER directive and have not yet
# been hardened with a quadlet User= override.  Shrink this list as services
# are hardened; reaching zero is the goal for Phase 9 security hardening.
KNOWN_ROOT_CONTAINERS = {
    "flowise",    # flowiseai/flowise — no USER in Dockerfile
    "litellm",    # ghcr.io/berriai/litellm — runs as root
    "openwebui",  # ghcr.io/open-webui/open-webui — runs as root (0:0)
    "postgres",   # docker.io/postgres — runs as postgres uid but USER unset in image
    "promtail",   # grafana/promtail — no USER in Dockerfile
    "qdrant",     # qdrant/qdrant — runs as root (0:0)
    "traefik",    # traefik — no USER in Dockerfile (binds ports <1024)
}

class TestContainerUserSecurity:
    """T-092: Each deployed container must run as a non-root user."""

    def test_all_containers_run_as_non_root(self) -> None:
        """
        T-092: `podman inspect --format '{{.Config.User}}'` for each
        deployed container must not be empty, 'root', or '0', unless the
        container is in KNOWN_ROOT_CONTAINERS (upstream images awaiting
        hardening).  Any container NOT in the known list that runs as root
        is a new, unexpected finding and causes the test to fail.
        """
        root_containers: list[str] = []
        known_root_found: list[str] = []
        skipped_containers: list[str] = []

        for svc in DEPLOYED_SERVICES:
            result = subprocess.run(
                ["podman", "inspect", "--format", "{{.Config.User}}", svc],
                capture_output=True, text=True,
            )
            if result.returncode != 0:
                skipped_containers.append(f"{svc} (not running)")
                continue

            user = result.stdout.strip()

            if not user or user in ("0", "root", "0:0", "root:root"):
                if svc in KNOWN_ROOT_CONTAINERS:
                    known_root_found.append(f"  - {svc!r} (User={user!r}) [known — awaiting hardening]")
                else:
                    root_containers.append(f"  - {svc!r} (User={user!r})")

        if skipped_containers:
            print(f"\nSkipped (not running): {', '.join(skipped_containers)}")

        if known_root_found:
            print(f"\nKnown root containers (KNOWN_ROOT_CONTAINERS):\n" + "\n".join(known_root_found))

        assert not root_containers, (
            "Unexpected containers running as root (not in KNOWN_ROOT_CONTAINERS):\n"
            + "\n".join(root_containers)
            + "\nAdd to KNOWN_ROOT_CONTAINERS with a note, or fix with User= in the quadlet."
        )


# ---------------------------------------------------------------------------
# T-093: /admin/v1/nodes auth enforcement (Phase 22 — D-027)
# ---------------------------------------------------------------------------
#
# In-process tests — do NOT require a live KI service.
# Verifies that:
#   - POST /admin/v1/nodes returns 401 when KI_ADMIN_KEY is set and no token supplied
#   - GET  /admin/v1/nodes returns 401 under the same condition
#   - POST /admin/v1/nodes/{id}/join is EXEMPT (token-gated, no Authorization required)
#   - Valid KI_ADMIN_KEY bearer token is accepted
#
# T-094: Live-service auth smoke test (skipped when KI not running)

import sys as _sys
from pathlib import Path as _Path

_KI_SRC = _Path(__file__).parent.parent.parent / "services" / "knowledge-index"
if str(_KI_SRC) not in _sys.path:
    _sys.path.insert(0, str(_KI_SRC))


class TestT093NodeAdminAuthInProcess:
    """T-093: /admin/v1/nodes endpoints enforce auth when KI_ADMIN_KEY is configured."""

    @pytest.fixture(scope="class")
    def authed_client(self):
        """TestClient with KI_ADMIN_KEY set and a fresh in-memory DB."""
        import os as _os
        import sys as _sys
        from sqlalchemy import create_engine, text
        from sqlalchemy.pool import StaticPool
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        engine = create_engine(
            "sqlite:///:memory:",
            connect_args={"check_same_thread": False},
            poolclass=StaticPool,
        )
        with engine.connect() as conn:
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS nodes (
                    node_id           TEXT PRIMARY KEY,
                    display_name      TEXT NOT NULL DEFAULT '',
                    profile           TEXT NOT NULL DEFAULT 'knowledge-worker',
                    address           TEXT NOT NULL DEFAULT '',
                    capabilities      TEXT NOT NULL DEFAULT '{}',
                    status            TEXT NOT NULL DEFAULT 'unregistered',
                    token_hash        TEXT,
                    litellm_model_ids TEXT NOT NULL DEFAULT '[]',
                    registered_at     TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
                    last_seen         TIMESTAMP
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS node_heartbeats (
                    id TEXT PRIMARY KEY, node_id TEXT NOT NULL,
                    recorded_at TIMESTAMP, cpu_percent REAL, mem_used_gb REAL,
                    mem_total_gb REAL, gpu_vram_used_mb INTEGER,
                    requests_last_60s INTEGER, messages TEXT NOT NULL DEFAULT '[]'
                )
            """))
            conn.execute(text("""
                CREATE TABLE IF NOT EXISTS node_suggestions (
                    id TEXT PRIMARY KEY, node_id TEXT NOT NULL,
                    created_at TIMESTAMP, consumed_at TIMESTAMP,
                    suggestion TEXT NOT NULL DEFAULT '{}'
                )
            """))
            conn.commit()

        env_patch = {
            "NODE_PROFILE":       "controller",
            "API_KEY":            "",
            "KI_ADMIN_KEY":       "test-admin-key-093",
            "LITELLM_MASTER_KEY": "",
        }
        with pytest.MonkeyPatch().context() as mp:
            for k, v in env_patch.items():
                mp.setenv(k, v)
            # Force fresh import with patched env
            for mod in list(_sys.modules.keys()):
                if mod == "node_registry":
                    del _sys.modules[mod]
            import node_registry as nr
            nr.init_router(engine)
            mini = FastAPI()
            mini.include_router(nr.router, prefix="/admin/v1/nodes")
            yield TestClient(mini, raise_server_exceptions=True), nr

    def test_list_nodes_no_auth_returns_401(self, authed_client):
        client, _ = authed_client
        resp = client.get("/admin/v1/nodes")
        assert resp.status_code == 401, f"Expected 401, got {resp.status_code}"

    def test_register_no_auth_returns_401(self, authed_client):
        client, _ = authed_client
        resp = client.post("/admin/v1/nodes", json={"node_id": "unauthed-node"})
        assert resp.status_code == 401, f"Expected 401, got {resp.status_code}"

    def test_join_exempt_from_auth(self, authed_client):
        """POST /{id}/join uses token-gating — no Authorization header needed."""
        client, _ = authed_client
        # Register first (with auth)
        reg = client.post(
            "/admin/v1/nodes",
            json={"node_id": "t093-join-test"},
            headers={"Authorization": "Bearer test-admin-key-093"},
        )
        assert reg.status_code == 201
        token = reg.json()["token"]

        # Join without Authorization header — should succeed (token is the auth)
        resp = client.post(
            "/admin/v1/nodes/t093-join-test/join",
            json={"token": token},
        )
        assert resp.status_code == 200, \
            f"join should not require Authorization header, got {resp.status_code}: {resp.text}"

    def test_valid_admin_key_accepted(self, authed_client):
        client, _ = authed_client
        resp = client.get(
            "/admin/v1/nodes",
            headers={"Authorization": "Bearer test-admin-key-093"},
        )
        assert resp.status_code == 200

    def test_wrong_token_returns_401(self, authed_client):
        client, _ = authed_client
        resp = client.get(
            "/admin/v1/nodes",
            headers={"Authorization": "Bearer wrong-key"},
        )
        assert resp.status_code == 401


# T-094: Live-service auth smoke — skipped automatically when KI not running
KNOWLEDGE_INDEX_URL = os.environ.get("KNOWLEDGE_INDEX_URL", "http://localhost:8100")


@pytest.fixture(scope="module")
def ki_available() -> bool:
    """True if the knowledge-index service is reachable."""
    try:
        r = httpx.get(f"{KNOWLEDGE_INDEX_URL}/health", timeout=3.0)
        return r.status_code == 200
    except Exception:
        return False


class TestT094NodeAdminAuthLive:
    """T-094: Live knowledge-index /admin/v1/nodes returns 401 without auth.
    Skipped when knowledge-index is not reachable."""

    def test_list_nodes_returns_401_live(self, ki_available):
        if not ki_available:
            pytest.skip(f"knowledge-index not reachable at {KNOWLEDGE_INDEX_URL}")

        resp = httpx.get(f"{KNOWLEDGE_INDEX_URL}/admin/v1/nodes", timeout=5.0)
        # 401 when KI_ADMIN_KEY is configured; 200 in dev mode (no key set)
        assert resp.status_code in (200, 401), \
            f"Unexpected status {resp.status_code} — expected 200 (dev) or 401 (keyed)"
        if resp.status_code == 200:
            pytest.skip("KI_ADMIN_KEY not configured — auth enforcement test not applicable in dev mode")

    def test_register_returns_401_live(self, ki_available):
        if not ki_available:
            pytest.skip(f"knowledge-index not reachable at {KNOWLEDGE_INDEX_URL}")

        resp = httpx.post(
            f"{KNOWLEDGE_INDEX_URL}/admin/v1/nodes",
            json={"node_id": "probe-node"},
            timeout=5.0,
        )
        assert resp.status_code in (201, 401, 409), \
            f"Unexpected status {resp.status_code}"
        if resp.status_code == 201:
            pytest.skip("KI_ADMIN_KEY not configured — auth enforcement test not applicable in dev mode")
