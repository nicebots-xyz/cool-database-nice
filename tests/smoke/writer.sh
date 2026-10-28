#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright: 2026 NiceBots.xyz
# Inserts one row every 0.25s through two paths (libpq multi-host, HAProxy) and records the id of every
# acknowledged and every failed insert in /tmp/<acked|failed>-<path>. Once /tmp/stop exists it prints the
# totals and idles, so run.sh can read the id files and compare them with the table.
DIRECT="host=pg-1,pg-2,pg-3 dbname=postgres user=postgres connect_timeout=2 target_session_attrs=read-write"
VIAHA="host=tasks.haproxy port=5000 dbname=postgres user=postgres connect_timeout=2"
until psql "$DIRECT" -qc "create table if not exists smoke(path text, n int)" 2>/dev/null; do sleep 1; done
i=0; okd=0; okh=0; fd=0; fh=0
while [ ! -e /tmp/stop ]; do
  i=$((i+1))
  if psql "$DIRECT" -qc "insert into smoke values('direct',$i)" 2>/dev/null; then okd=$((okd+1)); echo $i >> /tmp/acked-direct; else fd=$((fd+1)); echo $i >> /tmp/failed-direct; fi
  if psql "$VIAHA" -qc "insert into smoke values('haproxy',$i)" 2>/dev/null; then okh=$((okh+1)); echo $i >> /tmp/acked-haproxy; else fh=$((fh+1)); echo $i >> /tmp/failed-haproxy; fi
  [ $((i % 20)) = 0 ] && echo "PROGRESS $i"
  sleep 0.25
done
echo "TOTAL direct_ok=$okd direct_fail=$fd haproxy_ok=$okh haproxy_fail=$fh"
exec sleep infinity
