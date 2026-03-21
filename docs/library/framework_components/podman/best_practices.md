# Podman — Best Practices
**Last Updated:** 2026-03-08 UTC

## Purpose
Best practices for deploying and managing containers with Podman in rootless mode.

---

## Table of Contents

1. Rootless Deployment
2. Image Management
3. Systemd Quadlets
4. Networking
5. Storage and Volumes
6. Resource Management

## References

- Podman Documentation: https://docs.podman.io/en/latest/
- Podman Quadlet: https://docs.podman.io/en/latest/markdown/podman-systemd.unit.5.html
- Rootless Podman: https://github.com/containers/podman/blob/main/docs/tutorials/rootless_tutorial.md

---

# 1 Rootless Deployment

- Always prefer rootless Podman over rootful; it provides user-namespace isolation without root privileges
- Ensure `loginctl enable-linger <user>` is set so service user's services persist after logout
- Verify UID/GID subordinate ranges in `/etc/subuid` and `/etc/subgid` (minimum 65536 entries)
- Use `podman unshare` to debug permission issues inside the user namespace
- Rootless containers cannot bind to privileged ports (<1024) — map to higher ports and use a reverse proxy

# 2 Image Management

- Pin images to a specific tag or SHA256 digest; never use `:latest` in production
- Pull images from trusted registries; prefer official Docker Hub or vendor registries
- Scan images with `podman image inspect` or external tools (Trivy, Grype) before deployment
- Prune unused images periodically: `podman image prune --all --force`
- Use multi-stage builds for custom images to minimize attack surface

# 3 Systemd Quadlets

- Quadlets are the preferred way to manage Podman containers as systemd services
- Place quadlet files in `$HOME/.config/containers/systemd/` for rootless
- File types: `.container` (containers), `.network` (networks), `.volume` (volumes)
- Use `[Install] WantedBy=default.target` for automatic startup — this is processed by the quadlet generator, not by `systemctl enable`
- **Never use `systemctl --user enable` on quadlet-generated units** — they live in the transient generator directory and cannot be symlinked. Use `systemctl --user start <service>` after `daemon-reload`
- Reload after changes: `systemctl --user daemon-reload`
- Check generated unit files: `systemctl --user cat <service>`
- Use `After=` and `Requires=` directives for service dependency ordering

# 4 Networking

- Create a dedicated Podman network for the stack: `podman network create ai-stack-net`
- Use DNS names (container names) for inter-container communication
- Publish host ports only for services that need external access
- Network mode `bridge` is the default and appropriate for most cases
- Inspect network connectivity: `podman exec <container> curl http://<target>:<port>/health`

# 5 Storage and Volumes

- Use named volumes or bind mounts for persistent data
- Named volumes: managed by Podman, stored under `$HOME/.local/share/containers/storage/volumes/`
- Bind mounts: explicit host paths, easier to back up and manage
- Set appropriate `:Z` or `:z` SELinux labels on bind mounts if SELinux is enforcing
- Back up volume data before upgrades or migrations

# 6 Resource Management

- Set `--cpus` and `--memory` limits on every container to prevent resource starvation
- Use `podman stats` to monitor real-time resource consumption
- For GPU workloads, use CDI (Container Device Interface): `--device nvidia.com/gpu=all`
- Monitor cgroup usage for rootless containers under the user's systemd scope
- Use `podman top` to inspect running processes inside containers
