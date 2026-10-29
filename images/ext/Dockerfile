# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# The base comes from the `hippo-base` named build context (see docker-bake.hcl), so ext is always
# exactly the base of the same build plus extensions. BASE can also point at a base image by digest.
ARG BASE=hippo-base
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
