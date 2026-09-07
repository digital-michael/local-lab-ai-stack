from __future__ import annotations

import pathlib
from typing import Any

import httpx


class ConversionsClient:
    """Minimal HTTP client for the conversions service.

    Pure transport wrapper, modeled on services/m2m-gateway/client.py's
    M2MGatewayClient. CLI ergonomics (argument parsing, --out resolution,
    stdin/stdout handling) live in cli.py, not here — keeping "how to talk to
    the service" separate from "how a human invokes it".
    """

    def __init__(
        self,
        *,
        base_url: str,
        api_key: str = "",
        timeout_seconds: float = 60.0,
        transport: httpx.BaseTransport | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._api_key = api_key
        self._timeout_seconds = timeout_seconds
        self._transport = transport

    def _headers(self) -> dict[str, str]:
        headers: dict[str, str] = {}
        if self._api_key:
            headers["Authorization"] = f"Bearer {self._api_key}"
        return headers

    def list_formats(self) -> dict[str, Any]:
        with httpx.Client(
            base_url=self._base_url, timeout=self._timeout_seconds, transport=self._transport
        ) as client:
            response = client.get("/formats", headers=self._headers())
        response.raise_for_status()
        return response.json()

    def convert_bytes(self, data: bytes, *, filename: str, from_format: str, to_format: str) -> bytes:
        files = {"file": (filename, data)}
        form = {"from_format": from_format, "to_format": to_format}
        with httpx.Client(
            base_url=self._base_url, timeout=self._timeout_seconds, transport=self._transport
        ) as client:
            response = client.post("/v1/convert", data=form, files=files, headers=self._headers())
        response.raise_for_status()
        return response.content

    def convert_file(self, input_path: pathlib.Path, *, from_format: str, to_format: str) -> bytes:
        return self.convert_bytes(
            input_path.read_bytes(),
            filename=input_path.name,
            from_format=from_format,
            to_format=to_format,
        )
