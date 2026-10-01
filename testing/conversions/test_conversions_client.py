from __future__ import annotations

import importlib.util
import pathlib
import sys

import httpx


def _load_client_module():
    project_root = pathlib.Path(__file__).resolve().parents[2]
    client_path = project_root / "services" / "conversions" / "client.py"
    module_name = "test_conversions_client_module"
    spec = importlib.util.spec_from_file_location(module_name, client_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


def test_convert_bytes_sends_multipart_and_bearer_token():
    module = _load_client_module()

    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["path"] = request.url.path
        seen["authorization"] = request.headers.get("authorization", "")
        seen["content_type"] = request.headers.get("content-type", "")
        return httpx.Response(200, content=b"%PDF-fake", headers={"content-type": "application/pdf"})

    client = module.ConversionsClient(
        base_url="http://127.0.0.1:8300",
        api_key="secret-token",
        transport=httpx.MockTransport(handler),
    )

    result = client.convert_bytes(
        b"# hello", filename="doc.md", from_format="md", to_format="pdf"
    )

    assert result == b"%PDF-fake"
    assert seen["path"] == "/v1/convert"
    assert seen["authorization"] == "Bearer secret-token"
    assert seen["content_type"].startswith("multipart/form-data")


def test_convert_bytes_omits_auth_header_when_no_api_key():
    module = _load_client_module()

    seen: dict = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["authorization"] = request.headers.get("authorization", "")
        return httpx.Response(200, content=b"ok")

    client = module.ConversionsClient(
        base_url="http://127.0.0.1:8300",
        transport=httpx.MockTransport(handler),
    )
    client.convert_bytes(b"x", filename="x.md", from_format="md", to_format="pdf")

    assert seen["authorization"] == ""


def test_list_formats_parses_json_response():
    module = _load_client_module()

    def handler(request: httpx.Request) -> httpx.Response:
        assert request.url.path == "/formats"
        return httpx.Response(200, json={"implemented": [{"from": "md", "to": "pdf"}]})

    client = module.ConversionsClient(
        base_url="http://127.0.0.1:8300",
        transport=httpx.MockTransport(handler),
    )
    result = client.list_formats()

    assert result == {"implemented": [{"from": "md", "to": "pdf"}]}


def test_convert_bytes_raises_on_http_error():
    module = _load_client_module()

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(501, json={"detail": "not implemented"})

    client = module.ConversionsClient(
        base_url="http://127.0.0.1:8300",
        transport=httpx.MockTransport(handler),
    )

    try:
        client.convert_bytes(b"x", filename="x.xlsx", from_format="xlsx", to_format="pdf")
        assert False, "expected HTTPStatusError"
    except httpx.HTTPStatusError as exc:
        assert exc.response.status_code == 501
