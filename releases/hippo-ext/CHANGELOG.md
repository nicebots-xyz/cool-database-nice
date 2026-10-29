## hippo-ext@0.1.0

### Apps connect on their own network ([#24](https://github.com/nicebots-xyz/hippo/pull/24))

Apps join the `hippo-clients` network and reach Postgres through HAProxy (`haproxy:5000` for the primary, `:5001` for the replicas). The cluster network `hippo` is no longer attachable, so apps can't reach etcd or Patroni's REST API, and Patroni only accepts state-changing REST calls (restart, failover, configuration, …) from cluster members.

Both networks are encrypted: traffic between nodes goes over IPsec, so IP protocol 50 (ESP) must be allowed between them.

### Images link to their source repository ([#13](https://github.com/nicebots-xyz/hippo/pull/13))

Both images carry the `org.opencontainers.image.source` label, so registries link them to `nicebots-xyz/hippo`.

### Initial release ([#1](https://github.com/nicebots-xyz/hippo/pull/1))

HA PostgreSQL 18 for Docker Swarm: Patroni 4.1.5 + etcd + HAProxy, deployed with a single `docker stack deploy`.

- `base` image: PostgreSQL 18 with its bundled extensions and Patroni.
- `ext` image: `base` plus pgvector, pg_cron, pg_partman, pgaudit, pg_repack, hypopg and pg_stat_kcache.
- Reference stack in `deploy/`, validated by a smoke test that rolls every Postgres member under write load without losing an acknowledged write.
- MIT licensed, with an SPDX header on every source file.

### Pin the Dockerfile frontend to an exact version ([#10](https://github.com/nicebots-xyz/hippo/pull/10))

Images are built with `docker/dockerfile:1.27.1` by digest instead of the moving `1` tag, so frontend updates arrive as versioned, cooled-down updates.

### Patroni uses the system libpq ([#16](https://github.com/nicebots-xyz/hippo/pull/16))

Patroni's driver is the pure-Python `psycopg` on Debian's `libpq5` instead of the `psycopg-binary` wheel, which bundled its own copies of libpq, OpenSSL, Kerberos and LDAP built for CentOS 7, without license metadata.

### Lock Patroni's Python dependencies with a 7-day cooldown ([#3](https://github.com/nicebots-xyz/hippo/pull/3))

The lock only takes releases at least 7 days old, matching Renovate's cooldown for PyPI updates.
Renovate keeps the lock up to date through lock file maintenance.

### The Python lock file no longer stays in an image layer ([#21](https://github.com/nicebots-xyz/hippo/pull/21))

The base image mounts `requirements.lock` for the Patroni install instead of copying it in, so the file is no longer kept in a layer of its own.

### SBOM covering everything in the images ([#17](https://github.com/nicebots-xyz/hippo/pull/17))

Images are published with SPDX SBOM and build provenance attestations. The SBOM lists every package and every component no package manager owns (gosu, the postgres entrypoint scripts, hippo's own tooling), each with its license, and releases are refused when anything in the image is missing from it. See `docs/licenses.md`.
