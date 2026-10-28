---
packages:
  hippo: minor
---

## Initial release

HA PostgreSQL 18 for Docker Swarm: Patroni 4.1.5 + etcd + HAProxy, deployed with a single `docker stack deploy`.

- `base` image: PostgreSQL 18 with its bundled extensions and Patroni.
- `ext` image: `base` plus pgvector, pg_cron, pg_partman, pgaudit, pg_repack, hypopg and pg_stat_kcache.
- Reference stack in `deploy/`, validated by a smoke test that rolls every Postgres member under write load without losing an acknowledged write.
- MIT licensed, with an SPDX header on every source file.
