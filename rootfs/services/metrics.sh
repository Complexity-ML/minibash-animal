#!/usr/bin/env bash
# Long-running system metrics collector. minit keeps it alive (restart=true);
# its output is shipped into the bdb `logs` table by minit's log shipper.
set -u

echo "metrics: collector online"
while true; do
  up="0"
  if read -r up _ < /proc/uptime 2>/dev/null; then up="${up%.*}"; fi

  memtotal="?"; memavail="?"
  while read -r key val _; do
    case "$key" in
      MemTotal:)     memtotal="$val" ;;
      MemAvailable:) memavail="$val" ;;
    esac
  done < /proc/meminfo 2>/dev/null

  procs=0
  for p in /proc/[0-9]*; do procs=$((procs + 1)); done

  echo "metrics: uptime=${up}s mem_avail=${memavail}kB/${memtotal}kB procs=${procs}"
  sleep 10
done
