# Prometheus — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating Prometheus as the metrics collection and alerting engine.

---

## Table of Contents

1. Deployment
2. Scrape Configuration
3. Storage and Retention
4. Alerting
5. Reliability

## References

- Prometheus Documentation: https://prometheus.io/docs/
- Prometheus Best Practices: https://prometheus.io/docs/practices/
- Awesome Prometheus Alerts: https://samber.github.io/awesome-prometheus-alerts/

---

# 1 Deployment

- Deploy with a persistent volume for the TSDB (time-series database)
- Mount the configuration directory read-only at `/etc/prometheus`
- Use file-based service discovery or static configs for the internal AI stack services
- Set an appropriate retention period (default 15 days); increase based on disk capacity
- Pin the image version; Prometheus storage format changes are rare but impactful

# 2 Scrape Configuration

- Define one scrape job per target service; use the internal DNS name as the target
- Scrape intervals: 15–30 seconds for most services; 60 seconds for less critical metrics
- Use relabeling to add metadata labels (e.g., `service`, `node`, `environment`)
- Scrape the following endpoints:
  - LiteLLM: `http://litellm.ai-stack:4000/metrics`
  - vLLM: `http://vllm.ai-stack:8000/metrics`
  - Qdrant: `http://qdrant.ai-stack:6333/metrics`
  - PostgreSQL: via `postgres_exporter` sidecar or native metrics
  - Node metrics: via `node_exporter` on each host
- Validate scrape configs with `promtool check config` before deploying

# 3 Storage and Retention

- Default TSDB retention: 15 days; adjust with `--storage.tsdb.retention.time`
- Estimate storage: ~1-2 bytes per sample; ~10,000 active time series → ~25 MB/day
- Use local SSD for TSDB storage; avoid NFS or network storage for write performance
- For long-term storage, consider Thanos or Mimir as a future iteration
- Monitor Prometheus's own storage usage via its self-scrape metrics

# 4 Alerting

- Define alerting rules in YAML files stored in `$AI_STACK_DIR/configs/prometheus/rules/`
- Use multi-window, multi-burn-rate alerts for SLO-based alerting where possible
- Group related alerts to reduce noise
- Route alerts to appropriate channels (email, Slack, PagerDuty) via Alertmanager
- Test alert rules with `promtool test rules` before deploying

# 5 Reliability

- Prometheus is stateful; back up the TSDB directory for disaster recovery
- Set `Restart=always` in the systemd quadlet
- Prometheus has no external dependencies — it can start before other services
- Monitor Prometheus's own scrape health and rule evaluation latency
- Use the `/-/healthy` and `/-/ready` endpoints for readiness checks
