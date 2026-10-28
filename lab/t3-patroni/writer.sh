#!/bin/sh
# SPDX-License-Identifier: MIT
# Copyright: 2026 NiceBots.xyz
# Inserts a row every 0.25s via two paths; logs every failure, totals on SIGTERM.
DIRECT="host=pg-1,pg-2,pg-3 dbname=postgres user=postgres connect_timeout=2 target_session_attrs=read-write"
VIAHA="host=tasks.pg-haproxy port=5000 dbname=postgres user=postgres connect_timeout=2"
psql "$DIRECT" -qc "create table if not exists w(path text, n int, at timestamptz default now())"
i=0; okd=0; okh=0; fd=0; fh=0
trap 'echo "TOTAL attempts=$i direct_ok=$okd direct_fail=$fd haproxy_ok=$okh haproxy_fail=$fh"; exit 0' TERM INT
while :; do
  i=$((i+1))
  if psql "$DIRECT" -qc "insert into w values('direct',$i)" 2>/dev/null; then okd=$((okd+1)); else fd=$((fd+1)); echo "$(date +%T.%N | cut -c1-12) direct FAIL #$i"; fi
  if psql "$VIAHA"  -qc "insert into w values('haproxy',$i)" 2>/dev/null; then okh=$((okh+1)); else fh=$((fh+1)); echo "$(date +%T.%N | cut -c1-12) haproxy FAIL #$i"; fi
  [ $((i % 40)) = 0 ] && echo "$(date +%T) progress attempts=$i direct_ok=$okd haproxy_ok=$okh"
  sleep 0.25
done
