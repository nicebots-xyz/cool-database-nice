#!/bin/sh
# Smoke test: deploys deploy/stack.yml on a throwaway 3-node dind swarm with the given hippo image,
# forces a rolling update of every Postgres member under write load, and checks that:
#   - the templated member hostnames resolve,
#   - the cluster converges back to 1 leader + 2 streaming replicas,
#   - every write acknowledged to the client (libpq multi-host and HAProxy) is in the table, once.
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

for h in pg-1 pg-2 pg-3 etcd-1 etcd-2 etcd-3; do
  svc hippo_pg getent hosts "$h" >/dev/null || fail "member hostname $h does not resolve"
done
log "member hostnames resolve"

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

svc smoke_writer touch /tmp/stop
wait_for 30 "the writer totals" sh -c 'docker exec hippo-lab1 docker service logs --raw smoke_writer 2>/dev/null | grep -q TOTAL'
TOTAL=$(node docker service logs --raw smoke_writer 2>/dev/null | grep TOTAL | head -1)
ROWS=$(svc hippo_pg psql -h /var/run/postgresql -U postgres -Atc \
  "select string_agg(path || '=' || count || '/' || uniq, ' ' order by path) from (select path, count(*), count(distinct n) uniq from smoke group by path) s")
HISTORY=$(svc hippo_pg patronictl -c /etc/patroni.yml history -f json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')
log "writer: $TOTAL"
log "table:  $ROWS (rows/distinct per path); failovers: $HISTORY"

for p in direct haproxy; do
  ok=$(echo "$TOTAL" | sed -n "s/.*${p}_ok=\([0-9]*\).*/\1/p")
  rows=$(echo "$ROWS" | sed -n "s/.*${p}=\([0-9]*\)\/\([0-9]*\).*/\1 \2/p")
  [ "$rows" = "$ok $ok" ] || fail "$p: $ok acknowledged writes, table has rows/distinct = $rows"
  [ "$ok" -gt 0 ] || fail "$p: no successful writes"
done
log "PASS: every acknowledged write is present exactly once"
