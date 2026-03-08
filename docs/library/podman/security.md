# Podman — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for Podman container runtime.

---

## Table of Contents

1. Rootless Security Model
2. Image Security
3. Container Isolation
4. Secrets Management
5. Network Security
6. Host Security

## References

- Podman Security: https://docs.podman.io/en/latest/markdown/podman.1.html
- Container Security Guide (Red Hat): https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/9/html/building_running_and_managing_containers/assembly_signing-container-images_building-running-and-managing-containers
- CIS Benchmark for Container Runtimes: https://www.cisecurity.org/benchmark/docker

---

# 1 Rootless Security Model

- Rootless Podman runs entirely in user namespace — container root (UID 0) maps to unprivileged host UID
- Even if a container escape occurs, the attacker has only the privileges of the service user
- Avoid running as actual root (`sudo podman`) unless there is no alternative (e.g., kernel module requirements)
- Verify user namespace mapping: `podman unshare cat /proc/self/uid_map`
- The service user should be a dedicated non-login account with no sudo access

# 2 Image Security

- Pin images to SHA256 digests for maximum reproducibility and supply-chain integrity
- Scan images for CVEs before deployment using Trivy, Grype, or similar tools
- Pull from trusted registries only; configure `/etc/containers/registries.conf` to block unqualified pulls
- Verify image signatures when available
- Rebuild or update images promptly when CVEs are published for base layers

# 3 Container Isolation

- Drop all capabilities and add only those explicitly needed: `--cap-drop=ALL --cap-add=<needed>`
- Use `--read-only` for the root filesystem when possible; mount writable volumes only where needed
- Set `--security-opt=no-new-privileges` to prevent privilege escalation inside containers
- Use seccomp profiles to restrict system calls (Podman applies a default profile)
- Set `--pids-limit` to prevent fork bombs

# 4 Secrets Management

- Use `podman secret create` to store sensitive values; reference via `--secret` in container definitions
- Never pass secrets as environment variables in plain text in scripts or quadlet files
- Secrets are stored encrypted at rest by Podman
- Rotate secrets by creating new versions and restarting containers
- Audit which containers have access to which secrets

# 5 Network Security

- Use the internal Podman bridge network for inter-container communication
- Publish host ports only for services that require external access
- Do not publish database ports (PostgreSQL 5432, Qdrant 6333) to the host unless debugging
- Use firewall rules (firewalld/iptables) to restrict access to published ports
- Disable inter-container communication for containers that don't need it (future: network policies)

# 6 Host Security

- Keep Podman updated to the latest stable release (v5.7+)
- Enable SELinux or AppArmor for additional mandatory access control
- Monitor container activity with `podman events` and ship events to the logging stack
- Set appropriate cgroup limits to prevent any container from monopolizing host resources
- Audit the host for rootful Podman usage — it should not exist in this deployment
