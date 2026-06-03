#!/usr/bin/env bash
# Periodic health auditor. It does not restart services itself; minit owns
# lifecycle. This service only reports BDD/proc consistency for humans.
set -u

BDB_PATH="${BDB_PATH:-/var/bdb}"
export BDB_PATH

echo "healthd: auditor online"
while true; do
  stale=0
  total=0
  /bin/bdb dump services | tail -n +2 | while IFS="$(printf '\t')" read -r name command autostart restart desired status pid description; do
    [ -n "${name:-}" ] || continue
    total=$((total + 1))
    if [ "$status" = "running" ] && { [ "$pid" = "0" ] || [ ! -d "/proc/$pid" ]; }; then
      stale=$((stale + 1))
      echo "healthd: stale service name=${name} pid=${pid}"
    fi
  done
  echo "healthd: audit complete"
  sleep 30
done
