# Third-Party License Inventory
**Generated:** 2026-03-24
**Tooling:** `pip-licenses` (Python packages), manual (container images, models)

Run `make license-check` to refresh the Python-package section.

---

## Notices

- **AGPLv3 components** (Grafana, Loki, Promtail, MinIO) require that source code modifications be made available to users if the software is provided as a network service. Internal self-hosted deployment with no external user access is unaffected.
- **Meta Llama 3.x Community License** permits commercial use for products/services with fewer than 700 million monthly active users. Review required above that threshold.
- **Hosted API providers** (OpenAI, Groq, Anthropic, Mistral) are governed by their respective Terms of Service — no source-code license applies to API usage.

---

## 1. Container Images

| Service | Image | Version | License | Source |
|---|---|---|---|---|
| traefik | `docker.io/library/traefik` | v3.6.10 | MIT | https://github.com/traefik/traefik |
| postgres | `docker.io/library/postgres` | 17.9 | PostgreSQL License | https://www.postgresql.org/about/licence/ |
| qdrant | `docker.io/qdrant/qdrant` | v1.17.0 | Apache-2.0 | https://github.com/qdrant/qdrant |
| authentik | `ghcr.io/goauthentik/server` | 2026.2.1 | MIT (BSL for Enterprise features) | https://github.com/goauthentik/authentik |
| litellm | `ghcr.io/berriai/litellm` | main-v1.81.14-stable | MIT | https://github.com/BerriAI/litellm |
| vllm | `docker.io/vllm/vllm-openai` | v0.17.1 | Apache-2.0 | https://github.com/vllm-project/vllm |
| ollama | `docker.io/ollama/ollama` | 0.18.2 | MIT | https://github.com/ollama/ollama |
| flowise | `docker.io/flowiseai/flowise` | 3.0.13 | Apache-2.0 | https://github.com/FlowiseAI/Flowise |
| openwebui | `ghcr.io/open-webui/open-webui` | v0.8.10 | MIT | https://github.com/open-webui/open-webui |
| prometheus | `docker.io/prom/prometheus` | v3.10.0 | Apache-2.0 | https://github.com/prometheus/prometheus |
| grafana | `docker.io/grafana/grafana` | 12.4.0 | AGPLv3 | https://github.com/grafana/grafana |
| loki | `docker.io/grafana/loki` | 3.6.7 | AGPLv3 | https://github.com/grafana/loki |
| promtail | `docker.io/grafana/promtail` | 3.6.7 | AGPLv3 | https://github.com/grafana/loki |
| minio | `docker.io/minio/minio` | RELEASE.2025-04-22T22-12-26Z | AGPLv3 | https://github.com/minio/minio |
| knowledge-index | `localhost/knowledge-index` | 0.1.0 | Project-owned | — |

---

## 2. Python Packages — knowledge-index service

These packages are declared in `services/knowledge-index/requirements.txt` and installed inside the container image. Packages marked *(container-only)* are not present in the local dev/test venv.

| Package | License | Notes |
|---|---|---|
| fastapi | MIT | |
| uvicorn[standard] | BSD-3-Clause | |
| httpx | BSD-3-Clause | |
| pydantic | MIT | |
| mcp[server] | MIT | Anthropic MCP Python SDK |
| sqlalchemy | MIT | |
| psycopg2-binary | LGPL-2.1 | *(container-only)* |
| tavily-python | MIT | *(container-only)* web search provider |

---

## 3. Python Packages — dev/test venv

Scanned via `pip-licenses` from `.venv/`. Packages used only for testing or tooling (not shipped in the container image).

| Package | Version | License | URL |
|---|---|---|---|
| annotated-doc | 0.0.4 | MIT | https://github.com/fastapi/annotated-doc |
| annotated-types | 0.7.0 | MIT | https://github.com/annotated-types/annotated-types |
| anyio | 4.12.1 | MIT | https://anyio.readthedocs.io |
| argon2-cffi | 25.1.0 | MIT | https://github.com/hynek/argon2-cffi |
| argon2-cffi-bindings | 25.1.0 | MIT | https://github.com/hynek/argon2-cffi-bindings |
| attrs | 26.1.0 | MIT | https://www.attrs.org |
| certifi | 2026.2.25 | MPL-2.0 | https://github.com/certifi/python-certifi |
| cffi | 2.0.0 | MIT | https://cffi.readthedocs.io |
| click | 8.3.1 | BSD-3-Clause | https://github.com/pallets/click |
| cryptography | 46.0.5 | Apache-2.0 OR BSD-3-Clause | https://github.com/pyca/cryptography |
| fastapi | 0.135.1 | MIT | https://github.com/fastapi/fastapi |
| greenlet | 3.3.2 | MIT AND PSF-2.0 | https://greenlet.readthedocs.io |
| h11 | 0.16.0 | MIT | https://github.com/python-hyper/h11 |
| httpcore | 1.0.9 | BSD-3-Clause | https://www.encode.io/httpcore |
| httpx | 0.28.1 | BSD-3-Clause | https://github.com/encode/httpx |
| httpx-sse | 0.4.3 | MIT | https://github.com/florimondmanca/httpx-sse |
| idna | 3.11 | BSD-3-Clause | https://github.com/kjd/idna |
| iniconfig | 2.3.0 | MIT | https://github.com/pytest-dev/iniconfig |
| jsonschema | 4.26.0 | MIT | https://github.com/python-jsonschema/jsonschema |
| jsonschema-specifications | 2025.9.1 | MIT | https://github.com/python-jsonschema/jsonschema-specifications |
| mcp | 1.26.0 | MIT | https://modelcontextprotocol.io |
| minio | 7.2.20 | Apache-2.0 | https://github.com/minio/minio-py |
| packaging | 26.0 | Apache-2.0 OR BSD-2-Clause | https://github.com/pypa/packaging |
| pluggy | 1.6.0 | MIT | — |
| pycparser | 3.0 | BSD-3-Clause | https://github.com/eliben/pycparser |
| pycryptodome | 3.23.0 | BSD / Public Domain | https://www.pycryptodome.org |
| pydantic | 2.12.5 | MIT | https://github.com/pydantic/pydantic |
| pydantic-settings | 2.13.1 | MIT | https://github.com/pydantic/pydantic-settings |
| pydantic_core | 2.41.5 | MIT | https://github.com/pydantic/pydantic-core |
| PyJWT | 2.12.1 | MIT | https://github.com/jpadilla/pyjwt |
| Pygments | 2.19.2 | BSD-2-Clause | https://pygments.org |
| pytest | 9.0.2 | MIT | https://docs.pytest.org |
| pytest-asyncio | 1.3.0 | Apache-2.0 | https://github.com/pytest-dev/pytest-asyncio |
| python-dotenv | 1.2.2 | BSD-3-Clause | https://github.com/theskumar/python-dotenv |
| python-multipart | 0.0.22 | Apache-2.0 | https://github.com/Kludex/python-multipart |
| referencing | 0.37.0 | MIT | https://github.com/python-jsonschema/referencing |
| rpds-py | 0.30.0 | MIT | https://github.com/crate-py/rpds |
| SQLAlchemy | 2.0.48 | MIT | https://www.sqlalchemy.org |
| sse-starlette | 3.3.3 | BSD-3-Clause | https://github.com/sysid/sse-starlette |
| starlette | 1.0.0 | BSD-3-Clause | https://github.com/Kludex/starlette |
| typing-inspection | 0.4.2 | MIT | https://github.com/pydantic/typing-inspection |
| typing_extensions | 4.15.0 | PSF-2.0 | https://github.com/python/typing_extensions |
| urllib3 | 2.6.3 | MIT | https://github.com/urllib3/urllib3 |
| uvicorn | 0.42.0 | BSD-3-Clause | https://uvicorn.dev |

---

## 4. LLM Model Weights

| Model | Backend | License | Source |
|---|---|---|---|
| llama3.1:8b | Ollama (local) | Meta Llama 3.1 Community License | https://llama.meta.com/llama3/license/ |
| llama3.1:8b-instruct-q4_K_M | Ollama (TC25 node) | Meta Llama 3.1 Community License | https://llama.meta.com/llama3/license/ |
| llama3.2:3b-instruct-q4_K_M | Ollama (SOL node) | Meta Llama 3.2 Community License | https://llama.meta.com/llama3/license/ |
| Qwen/Qwen2.5-1.5B-Instruct | vLLM | Apache-2.0 | https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct |

**Meta Llama Community License summary:** Free for research and commercial use. Commercial products/services with ≥ 700 million monthly active users require a separate license from Meta. Model outputs may not be used to train non-Meta LLMs.

---

## 5. Hosted API Providers

These are external API services accessed via LiteLLM routing. No OSS license applies; usage is governed by each provider's Terms of Service.

| Model | Provider | Terms of Service |
|---|---|---|
| gpt-4o | OpenAI | https://openai.com/policies/terms-of-use |
| llama3-70b-8192 | Groq | https://groq.com/terms-of-service/ |
| claude-sonnet-4-5 | Anthropic | https://www.anthropic.com/legal/aup |
| mistral-large-latest | Mistral AI | https://mistral.ai/terms/ |
