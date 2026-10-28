# syntax=docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
FROM postgres:18.6-trixie@sha256:979bccfde35445db618c65107d27d08c6c21339d8dc3ad4c830c6633947be0e4

# Patroni lives in its own venv, installed strictly from the hashed lock. Wheels are preferred; a few
# pure-Python deps only ship source packages, and with no compiler in the image any source package
# needing one fails the build instead of slipping in.
COPY requirements.lock /tmp/requirements.lock
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir --prefer-binary --require-hashes -r /tmp/requirements.lock \
 && rm /tmp/requirements.lock \
 && install -d -o postgres -g postgres -m 0700 /var/lib/postgresql/data

COPY --chmod=0755 hippo-manifest /usr/local/bin/hippo-manifest

ENV PATH=/opt/patroni/bin:$PATH
USER postgres
# Patroni owns the Postgres lifecycle; SIGTERM makes it shut Postgres down and release the leader key.
STOPSIGNAL SIGTERM
ENTRYPOINT []
CMD ["patroni", "/etc/patroni.yml"]
