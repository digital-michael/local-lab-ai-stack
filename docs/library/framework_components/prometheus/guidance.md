# Prometheus — Guidance
**Last Updated:** 2026-03-08 UTC

## Purpose
Project-specific preferences and opinionated decisions for Prometheus within this AI stack.

---

## Table of Contents

1. Deployment Preferences
2. Configuration Choices
3. Integration Patterns
4. Operational Notes

---

# 1 Deployment Preferences

- Deploy via rootless Podman systemd quadlet generated from `configs/config.json`
- Host port 9091 maps to container port 9090
- Configuration directory at `$AI_STACK_DIR/configs/prometheus/` mounted read-only
- Resource limits: 1 core, 2 GB RAM
- No external dependencies — Prometheus can start independently

# 2 Configuration Choices

- Scrape interval: 30 seconds for all AI stack services
- Retention: 15 days (default); increase if disk allows
- Static scrape targets for all internal services using Podman DNS names
- Alerting rules stored in `$AI_STACK_DIR/configs/prometheus/rules/`
- No Alertmanager initially; alerts visible in Grafana dashboards

# 3 Integration Patterns

- Prometheus → (scrapes) all AI stack services exposing `/metrics`
- Grafana → Prometheus (data source for dashboards)
- Prometheus is passive — it only polls; services push nothing to it
- Node exporter on each host for system-level metrics (future addition)

# 4 Operational Notes

- Prometheus is part of the observability stack — it's important but not mission-critical
- If Prometheus is down, inference continues; you lose visibility temporarily
- Monitor Prometheus's own resource consumption — it can be memory-hungry with many active series
- When adding new services, add corresponding scrape targets to the Prometheus config
