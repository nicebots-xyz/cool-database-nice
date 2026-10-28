#!/bin/sh
# usage: svcexec.sh <service> <cmd...>  — exec in the first running task of a service in the lab
svc=$1; shift
for n in 1 2 3; do
  c=$(docker exec hippo-lab$n docker ps -q --filter label=com.docker.swarm.service.name=$svc | head -1)
  [ -n "$c" ] && exec docker exec hippo-lab$n docker exec $c "$@"
done
echo "no task for $svc" >&2; exit 1
