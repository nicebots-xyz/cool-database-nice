#!/bin/sh
# Inserts one row every 0.25s through two paths (libpq multi-host, HAProxy) and prints a line per
# failure. Once /tmp/stop exists it prints the totals that run.sh checks against the table, and exits.
DIRECT="host=pg-1,pg-2,pg-3 dbname=postgres user=postgres connect_timeout=2 target_session_attrs=read-write"
VIAHA="host=tasks.haproxy port=5000 dbname=postgres user=postgres connect_timeout=2"
until psql "$DIRECT" -qc "create table if not exists smoke(path text, n int)" 2>/dev/null; do sleep 1; done
i=0; okd=0; okh=0; fd=0; fh=0
while [ ! -e /tmp/stop ]; do
  i=$((i+1))
  if psql "$DIRECT" -qc "insert into smoke values('direct',$i)" 2>/dev/null; then okd=$((okd+1)); else fd=$((fd+1)); echo "FAIL direct #$i"; fi
  if psql "$VIAHA" -qc "insert into smoke values('haproxy',$i)" 2>/dev/null; then okh=$((okh+1)); else fh=$((fh+1)); echo "FAIL haproxy #$i"; fi
  [ $((i % 20)) = 0 ] && echo "PROGRESS $i"
  sleep 0.25
done
echo "TOTAL direct_ok=$okd direct_fail=$fd haproxy_ok=$okh haproxy_fail=$fh"
