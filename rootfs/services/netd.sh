#!/usr/bin/env bash
# Network state reporter. minit does early best-effort interface setup; netd
# keeps an operator-visible trace in the service logs.
set -u

echo "netd: network reporter online"
while true; do
  host="$(cat /proc/sys/kernel/hostname 2>/dev/null || echo altitude)"
  ipv4="$(busybox ip -4 addr show eth0 2>/dev/null | awk '/inet / { print $2; exit }')"
  route="$(busybox ip route 2>/dev/null | awk '/default/ { print $3; exit }')"
  [ -n "$ipv4" ] || ipv4="none"
  [ -n "$route" ] || route="none"
  echo "netd: host=${host} eth0=${ipv4} gw=${route}"
  sleep 20
done
