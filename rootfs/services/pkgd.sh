#!/usr/bin/env bash
set -u

BDB_PATH="${BDB_PATH:-/var/bdb}"
export BDB_PATH

mkdir -p /var/lib/minibash/packages /opt/pkg
echo "pkgd: package daemon online"
while true; do
  count="$(/bin/bdb dump packages 2>/dev/null | tail -n +2 | wc -l | awk '{print $1}')"
  echo "pkgd: packages=${count}"
  sleep 30
done
