<!--
SPDX-License-Identifier: MIT
Copyright: 2026 NiceBots.xyz
-->
# hippo lab

Throwaway 3-node Docker Swarm built from docker-in-docker containers, for validating the
single-service design. Nothing here touches the host's own Docker daemon swarm state.

```sh
../tests/smoke/lib/swarm-up.sh <image>...    # (re)create hippo-lab1..3, form the swarm, preload images
../tests/smoke/lib/svcexec.sh <service> <cmd...>   # exec into a running task of a lab service
../tests/smoke/lib/swarm-down.sh             # tear down
```

The helpers live in `tests/smoke/lib/`; the smoke test (`tests/smoke/run.sh`) grew out of t3.

Lab-only quirks: `DOCKER_IGNORE_BR_NETFILTER_ERROR=1` (host lacks br_netfilter), and Swarm
VIPs don't route inside dind (IPVS) — irrelevant since the design uses `endpoint_mode: dnsrr`.

Stacks must be copied into hippo-lab1 and deployed in order (t2/t3 reuse `t1_pgnet`):

```sh
docker exec hippo-lab1 mkdir -p /t1 && for f in stack.yml haproxy.cfg; do docker exec -i hippo-lab1 sh -c "cat > /t1/$f" < t1-haproxy-dns/$f; done
docker exec -w /t1 hippo-lab1 docker stack deploy -c stack.yml t1
```

t3 needs two secrets, generated locally (never committed):
`for s in su repl; do openssl rand -hex 16 > t3-patroni/$s.secret; done`. Its writer and probe
scripts read the superuser password from `PGPASSWORD`.

t3 also needs the image first: `docker build -t hippo-lab/patroni:18 t3-patroni`, then load it into each
node (`docker save hippo-lab/patroni:18 | docker exec -i hippo-labN docker load`).

## Results (2026-10-28, Docker 29.9.2, HAProxy 3.2, etcd 3.6.5, Patroni 4.1.5, PG 18.6)

- **t1 DNS/HAProxy**: templated `hostname:` resolves on the overlay and follows IP changes.
  HAProxy `server-template` on `svc` (dnsrr) and `tasks.svc` tracks IP churn, no DNS errors.
- **t2 etcd**: one replicated service, env-configured, peer URLs = templated hostnames,
  volume `name: "etcd-data-{{.Task.Slot}}"`. Forced rolling restart: 74/74 writes OK,
  no `member update` needed. Drained node → slot stays Pending (doesn't migrate).
- **t3 Patroni**: one replicated service, Patroni YAML as a `template_driver: golang` config
  with `{{ secret }}` passwords. Forced rolling restart under 4 writes/s: 2 failovers
  (leader restarted first, worst case), ~4s write outage each, identical via libpq and HAProxy;
  315/315 acknowledged commits present on both paths, no duplicates.
- **libpq gotcha**: `host=pg target_session_attrs=read-write` with one multi-A name does NOT work —
  on a read-only server libpq skips the name's remaining addresses. Use `host=pg-1,pg-2,pg-3`.
