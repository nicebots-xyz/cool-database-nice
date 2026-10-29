# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
FROM postgres:18.6-trixie@sha256:979bccfde35445db618c65107d27d08c6c21339d8dc3ad4c830c6633947be0e4

# Patroni lives in its own venv, installed strictly from the hashed lock. Wheels are preferred; a few
# pure-Python deps only ship source packages, and with no compiler in the image any source package
# needing one fails the build instead of slipping in.
RUN --mount=type=bind,source=requirements.lock,target=/tmp/requirements.lock \
    apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir --prefer-binary --require-hashes -r /tmp/requirements.lock \
 && install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/data

# Image tooling, and the declarations of everything no package manager owns: they become an SBOM fragment
# that the image's SBOM scanner merges (hippo/components.yaml).
COPY --chmod=0755 hippo/hippo-manifest /usr/local/bin/hippo-manifest
COPY hippo/sbom-fragment.py /usr/local/lib/hippo/sbom-fragment.py
COPY hippo/components.yaml /usr/local/lib/hippo/components/base.yaml
RUN mkdir -p /usr/share/hippo/sbom \
 && /opt/patroni/bin/python /usr/local/lib/hippo/sbom-fragment.py /usr/local/lib/hippo/components/base.yaml base > /usr/share/hippo/sbom/base.spdx.json \
 && rm -rf /root/.cache /root/.wget-hsts

ENV PATH=/opt/patroni/bin:$PATH
USER postgres
# Patroni owns the Postgres lifecycle; SIGTERM makes it shut Postgres down and release the leader key.
STOPSIGNAL SIGTERM
ENTRYPOINT []
CMD ["patroni", "/etc/patroni.yml"]
