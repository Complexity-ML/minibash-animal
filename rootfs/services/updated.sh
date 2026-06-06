#!/usr/bin/env bash
set -u

BDB_PATH="${BDB_PATH:-/var/bdb}"
export BDB_PATH

mkdir -p /var/lib/altitude/updates /var/lib/altitude/staged
echo "updated: Altitude signed update watcher online"
while true; do
  if output="$(/bin/pkg check-updates 2>&1)"; then
    available="$(printf '%s\n' "$output" | grep -c -- ' -> ' || true)"
    echo "updated: repository=verified available=${available}"
  else
    echo "updated: repository=failed"
  fi
  sleep 300
done
