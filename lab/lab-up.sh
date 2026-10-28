#!/bin/sh
# Throwaway 3-node dind Swarm for hippo experiments.
set -e
S=$(cd "$(dirname "$0")" && pwd)
IMAGES="haproxy:3.2-alpine quay.io/coreos/etcd:v3.6.5 traefik/whoami:latest alpine:3.22 ${EXTRA_IMAGES:-}"
TAR=${LAB_TAR:-${TMPDIR:-/tmp}/hippo-lab-images.tar}
for i in $IMAGES; do docker image inspect "$i" >/dev/null 2>&1 || docker pull -q "$i" >/dev/null; done
docker save $IMAGES -o "$TAR"
docker rm -f hippo-lab1 hippo-lab2 hippo-lab3 >/dev/null 2>&1 || true
docker network inspect hippo-lab >/dev/null 2>&1 || docker network create hippo-lab >/dev/null
for n in 1 2 3; do
  docker run -d --privileged --name hippo-lab$n --hostname lab$n --network hippo-lab \
    -e DOCKER_IGNORE_BR_NETFILTER_ERROR=1 docker:29-dind dockerd --host=unix:///var/run/docker.sock >/dev/null
done
for n in 1 2 3; do until docker exec hippo-lab$n docker info >/dev/null 2>&1; do sleep 1; done; done
for n in 1 2 3; do docker exec -i hippo-lab$n docker load < "$TAR" >/dev/null; done
IP1=$(docker inspect -f '{{(index .NetworkSettings.Networks "hippo-lab").IPAddress}}' hippo-lab1)
docker exec hippo-lab1 docker swarm init --advertise-addr "$IP1" >/dev/null
T=$(docker exec hippo-lab1 docker swarm join-token -q manager)
for n in 2 3; do docker exec hippo-lab$n docker swarm join --token "$T" "$IP1:2377" >/dev/null; done
docker exec hippo-lab1 sh -c 'for n in $(docker node ls -q); do docker node update --label-add hippo.pg=true $n >/dev/null; done; docker node ls'
