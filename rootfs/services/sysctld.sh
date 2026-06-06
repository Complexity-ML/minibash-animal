#!/usr/bin/env bash
# sysctld -- reconcile the bdb `sysctl` table into the live kernel.
#
# Hybrid Linux: /etc/sysctl.conf becomes ROWS. Each row is a kernel tunable;
# sysctld applies it (sysctl -w) and writes back applied/failed. Tune the kernel
# from the database:
#   bdb update sysctl --where key=net.ipv4.ip_forward value=1
#   bdb insert sysctl key=vm.swappiness value=1 status=unset description="..."
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export BDB_PATH="${BDB_PATH:-/var/bdb}"
BDB=/bin/bdb
exec >>/var/log/sysctld.log 2>&1
log() { echo "sysctld: $* ($(date 2>/dev/null))"; }

[ -x /etc/minibash/bdb/seed.sh ] && /etc/minibash/bdb/seed.sh 2>/dev/null
$BDB tables 2>/dev/null | grep -qx sysctl || { log "no 'sysctl' table"; exit 0; }

# Parse with cut (not IFS=$'\t' read): TAB is IFS-whitespace, so `read` would
# collapse empty fields. cols: key  value  status  description
$BDB dump sysctl 2>/dev/null | tail -n +2 | while IFS= read -r line; do
  [ -n "$line" ] || continue
  key=$(printf '%s' "$line" | cut -f1)
  val=$(printf '%s' "$line" | cut -f2)
  [ -n "$key" ] || continue
  if sysctl -w "$key=$val" >/dev/null 2>&1; then
    $BDB update sysctl --where "key=$key" status=applied >/dev/null 2>&1
    log "applied $key=$val"
  else
    $BDB update sysctl --where "key=$key" status=failed >/dev/null 2>&1
    log "FAILED  $key=$val"
  fi
done
log "reconcile done"
