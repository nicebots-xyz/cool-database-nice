#!/bin/sh
# One insert every 0.2s per path; logs latency (ms) and the error text of every failure.
DIRECT="host=pg-1,pg-2,pg-3 dbname=postgres user=postgres connect_timeout=2 target_session_attrs=read-write"
VIAHA="host=tasks.pg-haproxy port=5000 dbname=postgres user=postgres connect_timeout=2"
try() {
  s=$(date +%s%N); err=$(psql "$2" -qc "insert into w values('$1',0)" 2>&1); rc=$?; e=$(( ($(date +%s%N)-s)/1000000 ))
  [ $rc -ne 0 ] && echo "$(date +%T.%N | cut -c1-12) $1 FAIL ${e}ms: $(echo "$err" | tr '\n' ' ' | cut -c1-160)"
}
while :; do try direct "$DIRECT"; try haproxy "$VIAHA"; sleep 0.2; done
