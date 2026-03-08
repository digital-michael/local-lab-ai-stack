# Promtail — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and operating Promtail as the log shipping agent.

---

## Table of Contents

1. Deployment
2. Scrape Configuration
3. Pipeline Stages
4. Performance
5. Reliability

## References

- Promtail Documentation: https://grafana.com/docs/loki/latest/send-data/promtail/
- Promtail Configuration: https://grafana.com/docs/loki/latest/send-data/promtail/configuration/
- Promtail Pipelines: https://grafana.com/docs/loki/latest/send-data/promtail/pipelines/

---

# 1 Deployment

- Deploy Promtail on each host where containers produce logs
- Mount the host's container log directory (e.g., `/var/log/containers/` or Podman's log path) read-only
- Mount Promtail's position file on a persistent volume to survive restarts without re-reading old logs
- Pin the image version to match the Loki version for compatibility
- Run as a sidecar or host-level service — one instance per node, not per container

# 2 Scrape Configuration

- Define scrape configs that target Podman container logs
- For rootless Podman, logs typically reside under `$XDG_RUNTIME_DIR/containers/` or use `podman logs` paths
- Use file-based discovery or journal scraping (`journal` source) to capture container logs
- Add static labels for each job: `{service="<name>", stack="ai-stack"}`
- Use relabeling to extract the container name and set it as a `container` label

# 3 Pipeline Stages

- Use `json` or `regex` stages to parse structured log lines
- Extract severity/level fields and promote to labels: `{level="error"}`
- Use `timestamp` stage to extract the log timestamp from the line (avoid Promtail's default receive time)
- Use `output` stage to set the log line to a clean format after processing
- Apply `drop` stages to filter out noisy, low-value logs (health check access logs, etc.)

# 4 Performance

- Promtail is lightweight; 0.5 cores and 256 MB RAM is typically sufficient
- Set `batch_wait` and `batch_size` to balance latency and throughput (defaults are usually fine)
- Avoid scraping extremely high-volume log sources without rate limiting
- Monitor Promtail's own metrics (`/metrics` endpoint) for ingestion rate, lag, and dropped entries

# 5 Reliability

- Promtail tracks its read position in a positions file — ensure this file is on a persistent volume
- If Loki is unreachable, Promtail buffers logs and retries; configure retry limits to avoid unbounded memory growth
- Set `Restart=always` in the systemd quadlet
- Promtail has no dependencies other than Loki; it can start before Loki and will retry connections
- Health check: HTTP 200 on `/ready`
