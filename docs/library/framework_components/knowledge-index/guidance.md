# Knowledge Index Service — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for the Knowledge Index Service within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Implementation Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Internal port: **8100** (container DNS: `http://knowledge-index.ai-stack:8100`)
- No persistent data volume; library volumes mounted read-only from `$AI_STACK_DIR/libraries/`
- Resource limits: 1 CPU, 512 MB RAM
- Position 8 in the startup order: depends on PostgreSQL (position 3) and Qdrant (position 4)
- Decision: D-012 — standalone FastAPI microservice selected over Qdrant plugin, Flowise workflow, and LiteLLM integration

# 2 Implementation Choices

- **Python/FastAPI** — pragmatic MVP choice; async-native, auto-generates OpenAPI
- **REST `/v1/`** — versioned API; gRPC deferred to future iteration
- **In-memory cache** — TTL 60s default; configurable via environment variable `ROUTE_CACHE_TTL`
- **Discovery** — MVP implements localhost profile only (filesystem scan at startup + 300s interval)
- **Qdrant collection naming** — `{library-name}_{topic}` (underscore separator; hyphens not permitted in all Qdrant versions)
- **PostgreSQL schema** — `knowledge_index` schema within the shared `aistack` database

# 3 Integration Patterns

- **Flowise → Knowledge Index:** Flowise calls `POST /v1/route` to determine which library collection to query before issuing a Qdrant vector search
- **Knowledge Index → PostgreSQL:** Library metadata, topic index, document tracking stored in `knowledge_index` schema
- **Knowledge Index → Qdrant:** Vector similarity search for query routing; collections named `{library}_{topic}`
- **Library ingestion:** Triggered by `POST /v1/ingest` with library name; the service reads from the mounted library volume path

# 4 Operational Notes

- This service is **deferrable for MVP deployment** — the stack functions without it if Flowise is configured to query Qdrant directly
- Implementation deferred until after Phase 5 (deployment artifacts); tracked in checklist deferrable items
- When implementing, start with the localhost discovery profile and a single library to validate the routing pipeline end-to-end
- FastAPI dev server (`uvicorn --reload`) for development; gunicorn + uvicorn workers for production
- Log library discovery scan results at INFO level each cycle — useful for diagnosing why a library is not being routed to

# 5 MCP Integration (Phase 7)

## Endpoint

| Endpoint | Method | Purpose |
|---|---|---|
| `/mcp/sse` | GET | SSE stream — MCP clients connect here |
| `/mcp/messages` | POST | MCP message channel (used internally by SSE transport) |

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `search_knowledge` | `query: str`, `collection: str`, `top_k: int` (default 5) | JSON: `{results: [{text, score, document_id, source}]}` |
| `ingest_document` | `id: str`, `content: str`, `metadata: dict` | JSON: `{id, chunks}` |

## Client Configuration

Two real endpoints, both routed through Traefik and requiring the `knowledge_index_api_key`
Bearer token — never point a client at the raw container port (`:8100`); that bypasses
Traefik entirely and, depending on host network config, may bypass auth too.

- **LAN** (same network as CENTAURI): `https://ki.stack.localhost/mcp`
- **Remote** (off-LAN, over the internet): `https://ki.photondatum.space/mcp`

**Transport: Streamable HTTP is the one to use.** The MCP spec deprecated the old
HTTP+SSE transport (`/mcp/sse` + `/mcp/messages`, protocol `2024-11-05`) as of `2025-03-26`
in favor of Streamable HTTP (single `/mcp` endpoint). Several clients have already dropped
SSE support entirely. This service exposes both — `/mcp` (Streamable HTTP, current spec,
verified 2026-07-21 against the real `mcp` Python client and `curl`) and the legacy
`/mcp/sse` + `/mcp/messages` pair kept only for any client that hasn't migrated yet. Point
new client configs at `/mcp`.

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "knowledge-index": {
      "url": "https://ki.photondatum.space/mcp",
      "headers": { "Authorization": "Bearer <knowledge_index_api_key value>" }
    }
  }
}
```

**VS Code Copilot** (`.vscode/mcp.json`):
```json
{
  "servers": {
    "knowledge-index": {
      "type": "http",
      "url": "https://ki.stack.localhost/mcp",
      "headers": { "Authorization": "Bearer <knowledge_index_api_key value>" }
    }
  }
}
```

**Python MCP SDK** (programmatic):
```python
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

url = "https://ki.photondatum.space/mcp"  # or https://ki.stack.localhost/mcp on LAN
headers = {"Authorization": "Bearer <knowledge_index_api_key value>"}

async with streamablehttp_client(url, headers=headers) as (read, write, _):
    async with ClientSession(read, write) as session:
        await session.initialize()
        result = await session.call_tool(
            "search_knowledge",
            {"query": "my query", "collection": "default"}
        )
```

**Legacy HTTP+SSE** (only if a client hasn't migrated to Streamable HTTP): swap the URL for
`.../mcp/sse` and use `mcp.client.sse.sse_client` instead of `streamablehttp_client`. Same
Bearer header.

### Transport security

Per the MCP spec's Streamable HTTP security guidance, both `/mcp` and the legacy endpoints
validate the `Host` header (DNS-rebinding protection) against an allowlist in
`services/knowledge-index/app.py` (`_MCP_ALLOWED_HOSTS`). If you add a new hostname this
service is reachable under (new Traefik router, new public domain, etc.), add it to that
list or clients using the new hostname will get `421 Invalid Host header`.

## Environment Variables

| Variable | Purpose | Default |
|---|---|---|
| `API_KEY` | Bearer token for `/mcp/sse` and `/mcp/messages` | `` (auth disabled) |

## Traefik Routing

Four routers are defined in `configs/traefik/dynamic/services.yaml` for the public hostname
(`ki.photondatum.space`) and three for the LAN hostname (`ki.stack.localhost`):

| Router | Host | Path prefix | Authentik middleware | Notes |
| --- | --- | --- | --- | --- |
| `ki-public-root` | `ki.photondatum.space` | `/` | no | Redirects to `/admin` via `redirect-to-admin` |
| `ki-public-admin` | `ki.photondatum.space` | `/admin` | **yes** | SSO login required; app still needs API key (known gap) |
| `ki-public-api` | `ki.photondatum.space` | `/v1` | no | Machine-to-machine; clients supply Bearer token directly |
| `ki-public-mcp` | `ki.photondatum.space` | `/mcp` | no | MCP clients supply Bearer token directly |
| `knowledge-index-admin` | `ki.stack.localhost` | `/admin` | no | API key auth at app layer |
| `knowledge-index-mcp` | `ki.stack.localhost` | `/mcp` | no | API key auth at app layer |
| `knowledge-index-api` | `ki.stack.localhost` | `/v1` | **yes** | SSO login required on LAN; app still needs API key (known gap) |

Tailnet routers (`Host('100.64.0.4')`) bypass Authentik entirely — used by workers and internal services.

**Known gap:** Authentik forwardAuth on `/admin` and LAN `/v1` authenticates *identity* but does not
inject `Authorization: Bearer <knowledge_index_api_key>` into the proxied request. The app therefore
returns 401 even after a successful Authentik login. Planned fix: Traefik `headers` middleware to
inject the API key for browser-facing routes.

---

# 6 How to Add a New MCP Tool

Follow these steps every time a new tool is added to the knowledge-index MCP layer.

## Step 1 — Define the tool in `_list_tools()`

Add a `Tool` entry to the list returned by `_list_tools()` in `app.py`.
Every field is mandatory:

```python
Tool(
    name="my_tool",
    description="One sentence the LLM client sees when deciding whether to call this tool.",
    inputSchema={
        "type": "object",
        "properties": {
            "param_a": {"type": "string", "description": "What this param does"},
            "param_b": {"type": "integer", "description": "...", "default": 10},
        },
        "required": ["param_a"],   # omit optional params
    },
),
```

Rules:
- `name` must be a valid Python identifier; use `snake_case`
- `description` is shown to the LLM — be precise about what the tool does and returns
- Every `required` param must also have a `description`; optional params should have a `default`

## Step 2 — Handle the tool in `_call_tool()`

Add an `elif name == "my_tool":` branch. Pattern to follow:

```python
elif name == "my_tool":
    param_a = str(arguments["param_a"])           # always cast — LLM calls may send wrong types
    param_b = int(arguments.get("param_b", 10))

    def _do_work() -> dict:
        # All blocking I/O goes here (httpx, file ops, etc.)
        # Reuse existing helpers: _embed(), _qdrant, _ollama, _ingest_chunks()
        return {"result": "..."}

    result = await asyncio.to_thread(_do_work)
    return [TextContent(type="text", text=json.dumps(result))]
```

Rules:
- **Never block the event loop** — wrap all synchronous I/O in `asyncio.to_thread()`
- **Reuse existing helpers** — do not duplicate `_embed()`, `_qdrant`, or `_ollama` logic
- **Always return `list[TextContent]`** with `json.dumps(result)` as the text
- **Cast all arguments explicitly** — MCP clients (especially LLM-driven ones) may send strings where ints are expected
- Raise `ValueError` for unknown tool names (already handled by the final `else` branch)

## Step 3 — Update `config.json`

Add the new tool name to the `mcp.tools` array in the `knowledge-index` service block:

```json
"mcp": {
  "tools": ["search_knowledge", "ingest_document", "my_tool"]
}
```

This field is informational metadata only — it does not affect runtime behaviour.

## Step 4 — Write a test

Add a test to `testing/layer3_model/test_mcp_tools.py`. Reuse the shared
`mcp_session_data` fixture if the tool can share the same session; otherwise
add a new `scope="module"` fixture that opens a fresh session.

Minimum test:
```python
def test_my_tool(mcp_session_data):
    import json as _json
    # or open a new session if needed
    raw = mcp_session_data["my_tool_result"]
    data = _json.loads(raw)
    assert "result" in data
```

## Step 5 — Update this guidance doc

Add a row to the Tools table in the **MCP Integration** section above:

```
| `my_tool` | `param_a: str`, `param_b: int` | JSON: `{result: ...}` |
```

## Checklist

- [ ] `Tool(name=..., description=..., inputSchema=...)` added to `_list_tools()`
- [ ] `elif name == "my_tool":` branch added to `_call_tool()`
- [ ] Blocking I/O wrapped in `asyncio.to_thread()`
- [ ] Arguments cast to expected types
- [ ] Returns `list[TextContent]` with JSON string
- [ ] `config.json` `mcp.tools` array updated
- [ ] Test added to `test_mcp_tools.py`
- [ ] Tools table in this doc updated
- [ ] Container image rebuilt (`podman build`) and service restarted
