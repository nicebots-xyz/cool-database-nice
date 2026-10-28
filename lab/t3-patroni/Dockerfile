FROM postgres:18
RUN apt-get update \
 && apt-get install -y --no-install-recommends python3 python3-venv \
 && rm -rf /var/lib/apt/lists/* \
 && python3 -m venv /opt/patroni \
 && /opt/patroni/bin/pip install --no-cache-dir 'patroni[etcd3,psycopg3]' psycopg-binary \
 && mkdir -p /var/lib/postgresql/data && chown postgres:postgres /var/lib/postgresql/data && chmod 700 /var/lib/postgresql/data
ENV PATH=/opt/patroni/bin:$PATH
USER postgres
ENTRYPOINT []
CMD ["patroni", "/etc/patroni.yml"]
