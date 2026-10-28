# syntax=docker/dockerfile:1
# The base image is passed by digest, so ext is always exactly that base plus extensions.
ARG BASE
FROM ${BASE}

USER root
# apt-archive keeps every version PGDG ever published, so pinned versions never disappear.
RUN --mount=type=bind,source=extensions.yaml,target=/tmp/extensions.yaml <<'SH'
set -eu
echo "deb [ signed-by=/usr/local/share/keyrings/postgres.gpg.asc ] http://apt-archive.postgresql.org/pub/repos/apt trixie-pgdg-archive main" \
  > /etc/apt/sources.list.d/pgdg-archive.list
pkgs=$(/opt/patroni/bin/python - <<'PY'
import yaml
for ext in yaml.safe_load(open("/tmp/extensions.yaml")).values():
    print(f"{ext['package']}={ext['version']}")
PY
)
[ -n "$pkgs" ]
apt-get update
apt-get install -y --no-install-recommends $pkgs
rm -rf /var/lib/apt/lists/*
SH
USER postgres
