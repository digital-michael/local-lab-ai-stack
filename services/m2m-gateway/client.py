from __future__ import annotations

import threading
import time
from dataclasses import dataclass
from typing import Any

import httpx


@dataclass
class _TokenState:
    access_token: str
    expires_at: float


class M2MGatewayClient:
    """Minimal client wrapper for local M2M gateway workflows.

    This wrapper handles client-credentials token minting, in-memory cache with
    near-expiry renewal, and convenience helpers for job lifecycle calls.
    """

    def __init__(
        self,
        *,
        gateway_base_url: str,
        token_url: str,
        client_id: str,
        client_secret: str,
        scope: str | None = None,
        timeout_seconds: float = 20.0,
        renew_skew_seconds: int = 30,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._gateway_base_url = gateway_base_url.rstrip("/")
        self._token_url = token_url
        self._client_id = client_id
        self._client_secret = client_secret
        self._scope = scope
        self._timeout_seconds = timeout_seconds
        self._renew_skew_seconds = max(1, renew_skew_seconds)
        self._transport = transport

        self._token: _TokenState | None = None
        self._token_lock = threading.Lock()

    def _token_is_valid(self) -> bool:
        if not self._token:
            return False
        return time.time() < (self._token.expires_at - self._renew_skew_seconds)

    def _mint_token(self) -> _TokenState:
        payload: dict[str, Any] = {"grant_type": "client_credentials"}
        if self._scope:
            payload["scope"] = self._scope

        with httpx.Client(timeout=self._timeout_seconds, transport=self._transport) as client:
            response = client.post(
                self._token_url,
                data=payload,
                auth=(self._client_id, self._client_secret),
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
        response.raise_for_status()
        token_json = response.json()

        access_token = str(token_json.get("access_token") or "")
        expires_in = int(token_json.get("expires_in") or 0)
        if not access_token or expires_in <= 0:
            raise RuntimeError("Token endpoint response missing access_token or expires_in")

        return _TokenState(access_token=access_token, expires_at=time.time() + expires_in)

    def get_access_token(self, force_renew: bool = False) -> str:
        with self._token_lock:
            if force_renew or not self._token_is_valid():
                self._token = self._mint_token()
            return self._token.access_token

    def _gateway_request(self, method: str, path: str, json_body: dict[str, Any] | None = None) -> dict[str, Any]:
        token = self.get_access_token()
        with httpx.Client(base_url=self._gateway_base_url, timeout=self._timeout_seconds, transport=self._transport) as client:
            response = client.request(
                method,
                path,
                json=json_body,
                headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
            )
        response.raise_for_status()
        return response.json()

    def start_job(self, workflow_id: str, project_id: str, policy_class: str = "strict") -> dict[str, Any]:
        return self._gateway_request(
            "POST",
            "/m2m/v1/jobs/start",
            {
                "workflow_id": workflow_id,
                "project_id": project_id,
                "policy_class": policy_class,
            },
        )

    def send_heartbeat(self, job_id: str) -> dict[str, Any]:
        return self._gateway_request("POST", f"/m2m/v1/jobs/{job_id}/heartbeat")

    def request_extension(self, job_id: str, requested_minutes: int, approval_id: str | None = None) -> dict[str, Any]:
        body: dict[str, Any] = {"requested_minutes": requested_minutes}
        if approval_id:
            body["approval_id"] = approval_id
        return self._gateway_request("POST", f"/m2m/v1/jobs/{job_id}/extend", body)

    def run_heartbeat_loop(self, job_id: str, interval_seconds: int, max_iterations: int | None = None) -> list[dict[str, Any]]:
        """Send periodic heartbeats and return collected responses.

        This is intentionally simple for MVP usage and testability.
        """
        if interval_seconds < 1:
            raise ValueError("interval_seconds must be >= 1")

        responses: list[dict[str, Any]] = []
        iterations = 0
        while True:
            responses.append(self.send_heartbeat(job_id))
            iterations += 1
            if max_iterations is not None and iterations >= max_iterations:
                break
            time.sleep(interval_seconds)
        return responses
