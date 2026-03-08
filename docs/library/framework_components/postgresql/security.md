# PostgreSQL — Security
**Last Updated:** 2026-03-08 UTC

## Purpose
Security standards and hardening guidelines for PostgreSQL in the AI stack.

---

## Table of Contents

1. Authentication
2. Network Security
3. Access Control
4. Data Protection
5. Auditing
6. Container Security

## References

- PostgreSQL Security: https://www.postgresql.org/docs/current/security.html
- CIS PostgreSQL Benchmark: https://www.cisecurity.org/benchmark/postgresql
- OWASP SQL Injection Prevention: https://cheatsheetseries.owasp.org/cheatsheets/SQL_Injection_Prevention_Cheat_Sheet.html

---

# 1 Authentication

- Use strong, randomly generated passwords for all database users; inject via Podman secrets
- Use `scram-sha-256` authentication (PostgreSQL 14+ default) — never `trust` or `md5`
- Create separate database users per application (e.g., `litellm_user`, `authentik_user`) with minimal privileges
- Disable the default `postgres` superuser for remote connections; use it only for local administration
- Do not allow password-less connections from any source

# 2 Network Security

- Bind PostgreSQL to the internal Podman network only
- Set `listen_addresses = '*'` inside the container but only publish port 5432 to the Podman bridge network
- In `pg_hba.conf`, restrict connections to known service IPs or the `ai-stack-net` subnet
- Do not expose PostgreSQL to the host network or the internet
- Use SSL for connections if data sensitivity warrants it (even on the internal network)

# 3 Access Control

- Follow the principle of least privilege: each application user gets `CONNECT`, `USAGE`, and only the specific table permissions needed
- Use schema-level permissions to isolate application data
- Revoke `CREATE` on the `public` schema from all non-admin users
- Do not grant `SUPERUSER`, `CREATEDB`, or `CREATEROLE` to application accounts
- Review and audit role memberships periodically

# 4 Data Protection

- Encrypt the PostgreSQL data volume at rest (LUKS or filesystem-level)
- Use parameterized queries exclusively in all applications — never construct SQL from string concatenation
- Apply column-level encryption for highly sensitive fields if needed
- Set appropriate `log_min_messages` — do not log query parameters that may contain secrets
- Implement data retention policies; purge old records according to schedule

# 5 Auditing

- Enable `log_connections` and `log_disconnections` for access monitoring
- Log DDL statements (`log_statement = 'ddl'`) to track schema changes
- Use `pg_stat_statements` for query audit trails
- Send PostgreSQL logs to Loki via Promtail for centralized analysis
- Monitor for unusual connection patterns or query volumes

# 6 Container Security

- Run as the `postgres` user inside the container (the official image does this by default)
- Use rootless Podman for outer isolation
- Pin the image to a specific tag or digest
- Mount the data directory as the only read-write volume
- Drop all unnecessary Linux capabilities
- Scan the image for CVEs before deployment
