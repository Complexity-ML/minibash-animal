#!/usr/bin/env bash
set -u

BDB_PATH="${BDB_PATH:-/var/bdb}"
export BDB_PATH

mkdir -p /var/lib/altitude/packages
echo "pkgd: Altitude package integrity daemon online"
while true; do
  count="$(/bin/bdb select packages 2>/dev/null | tail -n +2 | wc -l | awk '{print $1}')"
  if /bin/pkg verify >/dev/null 2>&1; then
    echo "pkgd: packages=${count} integrity=ok"
  else
    echo "pkgd: packages=${count} integrity=failed"
  fi
  sleep 60
done
