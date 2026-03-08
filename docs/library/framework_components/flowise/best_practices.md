# Flowise — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating Flowise as the workflow orchestration layer for LLM agent pipelines.

---

## Table of Contents

1. Deployment
2. Workflow Design
3. Performance
4. Reliability
5. Upgrades

## References

- Flowise Documentation: https://docs.flowiseai.com
- Flowise GitHub: https://github.com/FlowiseAI/Flowise

---

# 1 Deployment

- Run in a container with a persistent volume for workflow definitions and execution state
- Use environment variables for all credentials; never hardcode API keys in flow definitions
- Connect to external services (LiteLLM, Qdrant) via internal DNS names on the Podman network
- Set `FLOWISE_USERNAME` and `FLOWISE_PASSWORD` for the admin UI; inject via Podman secrets
- Place behind a reverse proxy for TLS termination; Flowise's built-in server is HTTP only

# 2 Workflow Design

- Keep workflows modular — one workflow per use case rather than monolithic chains
- Use LiteLLM as the model endpoint rather than configuring individual model providers in each flow
- Version control workflow exports (JSON) alongside the codebase
- Parameterize workflows using environment variables or API inputs rather than hardcoded values
- Document each workflow's purpose, inputs, outputs, and expected behavior

# 3 Performance

- Flowise workflows are I/O-bound (waiting on LLM inference and retrieval) — CPU limits can be modest
- Set connection timeouts for downstream services to avoid hanging workflows
- Monitor workflow execution duration and failure rates
- Consider separating high-traffic workflows into dedicated Flowise instances if load grows

# 4 Reliability

- Back up the Flowise data directory regularly; it contains all workflow definitions
- Set `Restart=always` in the systemd quadlet
- Test workflows after Flowise upgrades — serialization format may change between versions
- Monitor for uncaught errors in workflow execution logs

# 5 Upgrades

- Export all workflows before upgrading
- Test imported workflows in a staging instance after upgrade
- Pin to a specific image tag; Flowise has a fast release cycle
- Review migration guides for database schema changes
