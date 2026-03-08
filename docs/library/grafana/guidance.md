# Grafana — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for Grafana within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Host port 3001 maps to container port 3000
- Data volume at `$AI_STACK_DIR/data/grafana`; provisioning at `$AI_STACK_DIR/configs/grafana/provisioning`
- Resource limits: 1 core, 1 GB RAM
- Depends on Prometheus and Loki being available

# 2 Configuration Choices

- Data sources provisioned as code (YAML files), not through UI
- Two primary data sources: Prometheus (metrics), Loki (logs)
- Dashboards stored as JSON, provisioned from `$AI_STACK_DIR/configs/grafana/dashboards/`
- Default org name: `AI Stack`
- Anonymous access disabled; SSO via Authentik when enabled, basic auth otherwise

# 3 Integration Patterns

- Grafana → Prometheus (query metrics via PromQL)
- Grafana → Loki (query logs via LogQL)
- Grafana → Authentik (OAuth login, deferrable)
- Users → Grafana (access dashboards, explore metrics and logs)

# 4 Operational Notes

- Grafana is the primary user-facing observability tool
- When adding new services, create scrape targets in Prometheus and add corresponding Grafana dashboard panels
- Export dashboard JSON to git after significant changes
- Grafana plugin ecosystem is large; install plugins sparingly to minimize attack surface
