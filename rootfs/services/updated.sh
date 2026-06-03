#!/usr/bin/env bash
set -u

BDB_PATH="${BDB_PATH:-/var/bdb}"
export BDB_PATH

mkdir -p /var/lib/minibash/updates /var/lib/minibash/staged
echo "updated: update watcher online"
while true; do
  staged="$(/bin/bdb dump updates 2>/dev/null | tail -n +2 | awk -F '\t' '$3 == "staged" { n++ } END { print n + 0 }')"
  committed="$(/bin/bdb dump updates 2>/dev/null | tail -n +2 | awk -F '\t' '$3 == "committed" { n++ } END { print n + 0 }')"
  echo "updated: staged=${staged} committed=${committed}"
  sleep 30
done
