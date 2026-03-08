# Promtail — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for Promtail within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- No host port published — Promtail is internal only
- Configuration at `$AI_STACK_DIR/configs/promtail/`; positions file at `$AI_STACK_DIR/data/promtail/positions.yaml`
- Resource limits: 0.5 cores, 512 MB RAM
- Mount container log directories from the host read-only

# 2 Configuration Choices

- Use journal scraping or file discovery based on rootless Podman's log driver configuration
- Static labels: `{stack="ai-stack", node="<hostname>"}` on all log streams
- Dynamic labels: `service` extracted from container name via relabeling
- Pipeline stages: parse JSON logs where applicable, extract timestamp and severity
- Drop health check access logs to reduce noise

# 3 Integration Patterns

- Promtail → Loki (pushes all container logs)
- Promtail reads from: all AI stack container log outputs
- Grafana queries Loki for the logs Promtail ships
- Promtail is the only log source for Loki in this stack

# 4 Operational Notes

- Promtail is the most infrastructure-coupled component — its config depends on the host's log layout
- When Podman's log driver changes, Promtail scrape configs must be updated
- Monitor for Promtail lag (time between log creation and Loki ingestion)
- If new containers are added, verify Promtail discovers their logs automatically
