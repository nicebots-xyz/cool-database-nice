#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright: 2026 NiceBots.xyz
# Smoke test: deploys deploy/stack.yml on a throwaway 3-node dind swarm with the given hippo image,
# forces a rolling update of every Postgres member under write load, and checks that:
#   - the templated member hostnames resolve,
#   - an app on hippo-clients reaches the primary through HAProxy, and no member of the cluster directly,
#   - only members can call Patroni's state-changing REST endpoints,
#   - the cluster converges back to 1 leader + 2 streaming replicas,
#   - every write acknowledged to the client (libpq multi-host and HAProxy) is in the table, once,
#     and the table holds nothing that was not attempted. A write whose attempt failed may or may not
#     have committed (the connection can drop after the commit, before the acknowledgement).
# usage: run.sh <hippo-image>     KEEP=1 leaves the swarm running afterwards.
set -eu
IMAGE=${1:?usage: run.sh <hippo-image>}
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
LIB=$HERE/lib
node() { docker exec hippo-lab1 "$@"; }
node_in() { docker exec -i hippo-lab1 "$@"; }  # same, forwarding stdin
svc() { "$LIB/svcexec.sh" "$@"; }
log() { echo "[smoke] $*"; }
diagnostics() {
  docker exec hippo-lab1 docker service ls 2>/dev/null || return 0
  for s in hippo_etcd hippo_pg; do
    echo "--- $s tasks"; docker exec hippo-lab1 docker service ps "$s" --no-trunc --format '{{.Name}} {{.Node}} {{.CurrentState}} {{.Error}}' 2>/dev/null | head -9
    echo "--- $s logs"; docker exec hippo-lab1 docker service logs --raw --tail 15 "$s" 2>&1 | cut -c1-300
  done
  echo "--- patronictl list"; "$LIB/svcexec.sh" hippo_pg patronictl -c /etc/patroni.yml list 2>&1
}
fail() { echo "[smoke] FAIL: $*" >&2; diagnostics >&2; exit 1; }
quiet() { # runs a command, showing its output only if it fails
  out=$("$@" 2>&1) || { echo "$out" >&2; fail "command failed: $*"; }
}
[ "${KEEP:-0}" = 1 ] || trap '"$LIB/swarm-down.sh"' EXIT

# Converged = 1 running leader and 2 streaming replicas.
converged() {
  svc hippo_pg patronictl -c /etc/patroni.yml list -f json 2>/dev/null | python3 -c '
import json, sys
m = json.load(sys.stdin)
ok = sum(x["Role"] == "Leader" and x["State"] == "running" for x in m) == 1 \
     and sum(x["Role"] == "Replica" and x["State"] == "streaming" for x in m) == 2
sys.exit(0 if ok else 1)'
}
wait_for() { # <seconds> <description> <command...>; the command may be a shell function
  deadline=$(( $(date +%s) + $1 )); d=$2; shift 2
  until "$@" >/dev/null 2>&1; do
    [ "$(date +%s)" -lt "$deadline" ] || fail "timed out waiting for $d"
    sleep 3
  done
}

STACK_IMAGES=$(grep -E '^\s+image: [^$]' "$ROOT/deploy/stack.yml" | awk '{print $2}')
log "starting swarm with" $IMAGE $STACK_IMAGES
"$LIB/swarm-up.sh" "$IMAGE" $STACK_IMAGES

log "deploying deploy/stack.yml"
node mkdir -p /deploy
for f in stack.yml patroni.yml.tmpl haproxy.cfg; do node_in sh -c "cat > /deploy/$f" < "$ROOT/deploy/$f"; done
SUPERUSER_PW=$(openssl rand -hex 16)
printf '%s' "$SUPERUSER_PW" | node_in docker secret create hippo_superuser_password_v1 - >/dev/null
openssl rand -hex 16 | tr -d '\n' | node_in docker secret create hippo_replication_password_v1 - >/dev/null
quiet node sh -c "cd /deploy && HIPPO_IMAGE=$IMAGE docker stack deploy --detach=true -c stack.yml hippo"

wait_for 300 "the cluster to converge" converged
log "cluster converged"

# Swarm publishes a task's names once it is healthy, which can trail convergence by a healthcheck interval.
resolves() { svc hippo_pg getent hosts "$1"; }
for h in pg-1 pg-2 pg-3 etcd-1 etcd-2 etcd-3; do
  wait_for 60 "member hostname $h to resolve" resolves "$h"
done
log "member hostnames resolve"

# A container on the client network, like an app.
client() { node docker run --rm --network hippo-clients -e PGPASSWORD="$SUPERUSER_PW" "$IMAGE" "$@"; }
wait_for 60 "an app on hippo-clients to reach the primary through HAProxy" \
  client psql "host=tasks.haproxy port=5000 dbname=postgres user=postgres connect_timeout=5" -Atc "select 1"
for h in pg-1 etcd-1; do
  if client getent hosts "$h" >/dev/null 2>&1; then fail "$h resolves on hippo-clients"; fi
done
log "apps on hippo-clients reach Postgres through HAProxy only"

log "starting writer"
node_in sh -c 'cat > /deploy/writer.sh' < "$HERE/writer.sh"
node docker config create smoke_writer /deploy/writer.sh >/dev/null
quiet node docker service create -d -q --name smoke_writer --network hippo --restart-condition none \
  -e PGPASSWORD="$SUPERUSER_PW" --config source=smoke_writer,target=/writer.sh,mode=0555 \
  --entrypoint sh "$IMAGE" /writer.sh
wait_for 60 "the writer to make progress" sh -c 'docker exec hippo-lab1 docker service logs --raw smoke_writer 2>/dev/null | grep -q PROGRESS'

log "forcing a rolling update of every Postgres member"
quiet node docker service update --force --quiet hippo_pg
wait_for 300 "the cluster to converge after the rolling update" converged
log "cluster converged after rolling update"

# Checked after the update, when every member has a new address.
quiet svc hippo_pg patronictl -c /etc/patroni.yml reload hippo --force
svc smoke_writer python3 -c '
import urllib.error, urllib.request
try:
    urllib.request.urlopen(urllib.request.Request("http://pg-1:8008/reload", method="POST"), timeout=5)
except urllib.error.HTTPError as e:
    raise SystemExit(e.code != 403)
raise SystemExit(1)' || fail "a non-member called Patroni's POST /reload without being refused"
log "only members can change the cluster through Patroni's REST API"

svc smoke_writer touch /tmp/stop
wait_for 30 "the writer totals" sh -c 'docker exec hippo-lab1 docker service logs --raw smoke_writer 2>/dev/null | grep -q TOTAL'
TOTAL=$(node docker service logs --raw smoke_writer 2>/dev/null | grep TOTAL | head -1)
HISTORY=$(svc hippo_pg patronictl -c /etc/patroni.yml history -f json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
log "writer: $TOTAL; failovers: $HISTORY"

for p in direct haproxy; do
  acked=$(svc smoke_writer sh -c "cat /tmp/acked-$p 2>/dev/null" | tr '\n' ' ')
  failed=$(svc smoke_writer sh -c "cat /tmp/failed-$p 2>/dev/null" | tr '\n' ' ')
  rows=$(svc hippo_pg psql -h /var/run/postgresql -U postgres -Atc "select n from smoke where path = '$p'" | tr '\n' ' ')
  verdict=$(python3 - "$acked" "$failed" "$rows" <<'PY'
import sys
acked, failed, rows = (s.split() for s in sys.argv[1:4])
problems = []
if len(rows) != len(set(rows)):
    problems.append(f"{len(rows) - len(set(rows))} duplicated rows")
if lost := set(acked) - set(rows):
    problems.append(f"{len(lost)} acknowledged writes missing")
if invented := set(rows) - set(acked) - set(failed):
    problems.append(f"{len(invented)} rows never written")
if not acked:
    problems.append("no successful writes")
ambiguous = len(set(failed) & set(rows))
print("; ".join(problems) or f"ok: {len(acked)} acknowledged, all present; {ambiguous} failed attempts had committed")
PY
)
  log "$p: $verdict"
  case $verdict in ok:*) ;; *) fail "$p: $verdict" ;; esac
done
log "PASS: no acknowledged write lost, no duplicates, nothing invented"
