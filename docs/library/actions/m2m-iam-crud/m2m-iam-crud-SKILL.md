---
name: m2m-iam-crud
description: >
  Create, read, update, and delete M2M IAM service identities for the localhost
  M2M gateway profile. Covers the full operator path across Authentik client
  credentials, Podman secret handling, gateway workflow policy, and verification
  endpoints. Use when onboarding, rotating, changing, or retiring a service-to-service
  identity.
argument-hint: 'Optional: --service-id <id> --workflow-id <id> --project-id <id>'
---

# M2M IAM CRUD (Localhost MVP)

Implements practical IAM CRUD for M2M in this stack without writing secrets into tracked files.

This how-to treats an M2M identity as four coordinated artifacts:

1. Authentik client credentials identity (token issuer side)
2. Podman secret for the client credential
3. Gateway workflow policy entry (`M2M_WORKFLOW_POLICY_JSON`)
4. Optional trusted project-pair allowlist (`M2M_TRUSTED_ALLOW_PROJECT_PAIRS`)

---

## Preconditions

- Run from repo root.
- M2M gateway is configured in [configs/config.json](../../../../configs/config.json).
- You have Authentik admin access (UI or API token).
- You do not place any client secret value in tracked files.

Recommended validation before/after any CRUD action:

```bash
bash scripts/configure.sh validate
/home/3pdx7/Projects/active/llm-agent-local-2/.venv/bin/python -m pytest testing/security/test_m2m_gateway.py -q
```

---

## Canonical M2M Scope Set (MVP)

Use least privilege. Start from this minimal baseline and only add what the workflow needs.

- `m2m.jobs.start`
- `m2m.jobs.heartbeat`
- `m2m.jobs.extend`
- `m2m.context.attach`
- `m2m.infer`

Add only when required:

- `m2m.skill.execute`
- `m2m.publish.transform`
- `m2m.approval.request`
- `m2m.approval.decision` (admin/service account only)
- `m2m.jobs.extend.high` (break-glass extension scope)

---

## C: Create Identity

### C1. Create Authentik client

Create one Authentik OAuth client per calling service identity.

Required settings:

- Grant type: client credentials only
- Audience: `local-m2m-gateway`
- Access token TTL: 10 minutes (MVP default)
- Subject maps to service identity (`sub` claim)
- Workflow claim `wf` is present
- Scope claim includes only required scopes

If you need issuer/JWKS wiring and smoke introspection:

```bash
bash scripts/m2m-authentik-bootstrap.sh \
  --issuer https://auth.stack.localhost/application/o/<slug>/ \
  --jwks-url https://auth.stack.localhost/application/o/<slug>/jwks/ \
  --audience local-m2m-gateway \
  --apply-config
```

To generate a repeatable per-service Authentik provisioning template:

```bash
bash scripts/m2m-authentik-bootstrap.sh \
  --issuer https://auth.stack.localhost/application/o/<slug>/ \
  --jwks-url https://auth.stack.localhost/application/o/<slug>/jwks/ \
  --service-id svc-ingest \
  --workflow-id wf_ingest_docs \
  --token-ttl-seconds 600 \
  --emit-client-template \
  --template-output /tmp/m2m-client-svc-ingest.json
```

To send an endpoint-driven provisioning request directly to Authentik API:

```bash
AUTHENTIK_API_TOKEN='<token>' bash scripts/m2m-authentik-bootstrap.sh \
  --issuer https://auth.stack.localhost/application/o/<slug>/ \
  --jwks-url https://auth.stack.localhost/application/o/<slug>/jwks/ \
  --provision-url https://auth.stack.localhost/api/v3/<provider-endpoint> \
  --provision-method POST \
  --provision-payload-file /tmp/authentik-provider-payload.json
```

### C2. Store client secret in Podman secrets

Use secret names only in config. Keep secret values out of git-tracked files.

Suggested secret naming pattern:

- `m2m_client_secret_<service_id>`

### C3. Add workflow policy entry

Update `M2M_WORKFLOW_POLICY_JSON` for the service workflow in [configs/config.json](../../../../configs/config.json).

Example snippet:

```json
{
  "workflows": {
    "wf_ingest_docs": {
      "allowed_models": ["llama3.1:8b"],
      "allowed_tools": ["ki.search"],
      "allowed_sources": ["ki"],
      "allowed_publication_adapters": ["openwebui_v1"]
    }
  }
}
```

### C4. Apply and verify

```bash
bash scripts/configure.sh validate
bash scripts/configure.sh generate-quadlets
bash scripts/start.sh
```

Token smoke test:

```bash
export M2M_TEST_TOKEN='<access-token>'
bash scripts/m2m-authentik-bootstrap.sh \
  --issuer https://auth.stack.localhost/application/o/<slug>/ \
  --jwks-url https://auth.stack.localhost/application/o/<slug>/jwks/ \
  --audience local-m2m-gateway
```

Python workflow snippet (client wrapper):

```python
import importlib.util
from pathlib import Path

client_path = Path("services/m2m-gateway/client.py")
spec = importlib.util.spec_from_file_location("m2m_client", client_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

client = mod.M2MGatewayClient(
    gateway_base_url="http://127.0.0.1:8787",
    token_url="https://auth.stack.localhost/application/o/<slug>/token/",
    client_id="svc-ingest",
    client_secret="<from-podman-secret>",
    scope="m2m.jobs.start m2m.jobs.heartbeat m2m.jobs.extend m2m.context.attach m2m.infer",
)

job = client.start_job(workflow_id="wf_ingest_docs", project_id="proj-a", policy_class="sustained")
job_id = job["job_id"]
client.send_heartbeat(job_id)

ext = client.request_extension(job_id, requested_minutes=180)
if ext.get("requires_human_approval"):
    # Acquire approval_id from /m2m/v1/approval/request path, then retry.
    pass
```

---

## R: Read / Inspect Identity State

### R1. Read config state

```bash
jq '.services["m2m-gateway"].environment | {
  M2M_JWT_AUDIENCE,
  M2M_JWT_ISSUER,
  M2M_JWKS_URL,
  M2M_TRUSTED_INTEROP_ENABLED,
  M2M_TRUSTED_ALLOW_PROJECT_PAIRS,
  M2M_WORKFLOW_POLICY_JSON
}' configs/config.json
```

### R2. Read runtime health, metrics, and retained audit events

```bash
curl -s http://127.0.0.1:8787/health | jq .
curl -s http://127.0.0.1:8787/ready | jq .
curl -s http://127.0.0.1:8787/m2m/v1/metrics | jq .
curl -s 'http://127.0.0.1:8787/m2m/v1/audit/events?limit=50' | jq .
```

### R3. Read token claim behavior

```bash
curl -s -X POST \
  -H "Authorization: Bearer <access-token>" \
  http://127.0.0.1:8787/m2m/v1/token/introspect | jq .
```

---

## U: Update Identity

Common update operations:

1. Scope reduction or expansion in Authentik client
2. Secret rotation
3. Workflow policy changes (models/tools/sources/adapters)
4. Trusted pair changes for cross-platform KI sharing

### U1. Rotate secret

- Create new secret value in Authentik client.
- Update corresponding Podman secret value.
- Restart only affected service(s).
- Validate with introspection and one workflow call.

### U2. Update workflow policy safely

- Edit `M2M_WORKFLOW_POLICY_JSON` in [configs/config.json](../../../../configs/config.json).
- Keep `allowed_sources` explicit to preserve default-deny posture.
- Restrict `allowed_publication_adapters` per workflow.

Then:

```bash
bash scripts/configure.sh validate
/home/3pdx7/Projects/active/llm-agent-local-2/.venv/bin/python -m pytest testing/security/test_m2m_gateway.py -q
```

### U3. Update trusted interop policy

For approved project pairs only:

- Set `M2M_TRUSTED_INTEROP_ENABLED` to `true`.
- Set `M2M_TRUSTED_ALLOW_PROJECT_PAIRS` to comma-separated pairs: `projectA:projectB,projectC:projectD`.

Keep MinIO/Open WebUI project-bound sources private unless explicitly promoted through governed process.

---

## D: Delete / Decommission Identity

### D1. Revoke at issuer

- Disable/delete Authentik client.
- Revoke any active sessions/tokens for the client if supported.

### D2. Remove local secret

- Delete `m2m_client_secret_<service_id>` from Podman secrets.

### D3. Remove policy entry and pair mappings

- Delete the workflow entry from `M2M_WORKFLOW_POLICY_JSON`.
- Remove any related pair in `M2M_TRUSTED_ALLOW_PROJECT_PAIRS`.

### D4. Verify deny-by-default

- Introspection with old token should fail.
- Calls to start/attach/infer should deny.
- Audit event stream should include deny records.

---

## Evidence Checklist Per CRUD Change

- `configure.sh validate` passes
- security test suite passes (current baseline: 18 tests)
- token introspect reflects expected `sub`, `wf`, and scope set
- audit events show expected allow/deny transitions
- no secret values written to tracked files

---

## Known MVP Gaps (As Of 2026-04-21)

Not fully complete yet:

- Remaining closure item is deployed-runtime evidence for BL-011 in target environment.

This guide is therefore operational for current MVP state, but it does not imply full closure of BL-011.
