#!/usr/bin/env bash
# Tiny periodic scheduler. Every tick it runs its jobs; here it just emits a
# heartbeat, but this is the natural place to hang real periodic work.
set -u

INTERVAL="${CRON_INTERVAL:-15}"
echo "cron: scheduler online (every ${INTERVAL}s)"
n=0
while true; do
  sleep "$INTERVAL"
  n=$((n + 1))
  now="$(date '+%H:%M:%S' 2>/dev/null || echo '??:??:??')"
  echo "cron: tick #${n} at ${now}"
done
