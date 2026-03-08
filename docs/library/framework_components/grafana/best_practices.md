# Grafana — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating Grafana as the visualization and dashboarding platform.

---

## Table of Contents

1. Deployment
2. Data Sources
3. Dashboard Design
4. Alerting
5. Reliability

## References

- Grafana Documentation: https://grafana.com/docs/grafana/latest/
- Grafana Best Practices: https://grafana.com/docs/grafana/latest/best-practices/
- Grafana Provisioning: https://grafana.com/docs/grafana/latest/administration/provisioning/

---

# 1 Deployment

- Deploy with a persistent volume for Grafana's SQLite database (dashboard definitions, users, preferences)
- Use provisioning files to configure data sources and dashboards as code — mount at `/etc/grafana/provisioning/`
- Set `GF_SECURITY_ADMIN_PASSWORD` via Podman secret; change the default admin password immediately
- Grafana is stateless for visualization — the data lives in Prometheus, Loki, and PostgreSQL
- Pin the image to a specific version; Grafana releases frequently and may introduce breaking changes

# 2 Data Sources

- Configure data sources via provisioning YAML, not through the UI
- Primary data sources for this stack:
  - **Prometheus** → metrics dashboards (inference latency, GPU utilization, service health)
  - **Loki** → log exploration and correlation
  - **PostgreSQL** → optional for direct database queries
- Use the internal Podman DNS names for data source URLs (e.g., `http://prometheus.ai-stack:9090`)
- Test each data source connection after provisioning

# 3 Dashboard Design

- Use templating variables for service names and time ranges — makes dashboards reusable
- Organize dashboards into folders: `AI Inference`, `Infrastructure`, `Security`, `Logs`
- Key dashboards to create:
  - **Inference Overview**: request rate, latency (p50/p95/p99), error rate, GPU utilization
  - **System Health**: container CPU/memory, disk I/O, network bytes
  - **Logs Dashboard**: aggregated log view with filters for service and severity
- Use consistent color schemes: green for healthy, yellow for warning, red for critical
- Limit dashboard panels to 15–20; excessive panels slow rendering

# 4 Alerting

- Grafana Alerting (unified alerting) can evaluate rules against any data source
- Define alert rules for SLOs: inference latency p99 < 2 seconds, error rate < 1%
- Use contact points to route alerts (email, Slack, webhook)
- Silence alerts during maintenance windows
- Test alert rules by manually triggering threshold conditions

# 5 Reliability

- Grafana is a visualization layer — its downtime does not affect inference or data collection
- Set `Restart=always` in the systemd quadlet
- Back up provisioning files and the Grafana SQLite database
- Use API tokens (not admin credentials) for automated dashboard management
- Health check: HTTP 200 on `/api/health`
