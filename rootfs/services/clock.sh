#!/usr/bin/env bash
# Long-running clock ticker. minit keeps it alive (restart=true).
set -u

echo "clock: ticker online"
while true; do
  up="0"
  if read -r up _ < /proc/uptime 2>/dev/null; then
    up="${up%.*}"
  fi
  echo "clock: tick (uptime ${up}s)"
  sleep 5
done
