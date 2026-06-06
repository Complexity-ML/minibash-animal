#!/usr/bin/env bash
# kmod -- reconcile the bdb `modules` table into the running kernel.
#
# The database is the source of truth for which kernel modules the system loads:
# this service modprobes every autoload module (with its params) and writes the
# real result back as status (loaded|failed). Must run EARLY -- before netmgr --
# because the crypto modules (ccm/aes) are required for WiFi to install its key.
#
# Edit the set live with e.g.:
#   bdb update modules --where name=ccm autoload=true
#   bdb insert modules name=foo params="bar=1" stage=net autoload=true status=unloaded description="..."
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export BDB_PATH="${BDB_PATH:-/var/bdb}"
BDB=/bin/bdb
exec >>/var/log/kmod.log 2>&1
log() { echo "kmod: $* ($(date 2>/dev/null))"; }

# make sure the tables exist (idempotent seed)
[ -x /etc/minibash/bdb/seed.sh ] && /etc/minibash/bdb/seed.sh 2>/dev/null

if ! $BDB tables 2>/dev/null | grep -qx modules; then
  log "no 'modules' table -- nothing to load"; exit 0
fi

# `bdb dump` prints a TAB header then one row per module.
# columns: name  params  stage  autoload  status  description
# NB: TAB is an IFS-whitespace char, so `IFS=$'\t' read` COLLAPSES empty fields
# (e.g. an empty `params`) and mis-aligns the columns. Parse with `cut -f`, which
# preserves empty fields.
$BDB dump modules 2>/dev/null | tail -n +2 | while IFS= read -r line; do
  [ -n "$line" ] || continue
  name=$(printf '%s' "$line" | cut -f1)
  params=$(printf '%s' "$line" | cut -f2)
  stage=$(printf '%s' "$line" | cut -f3)
  autoload=$(printf '%s' "$line" | cut -f4)
  [ "$autoload" = true ] || [ "$autoload" = 1 ] || continue
  # shellcheck disable=SC2086  -- params are intentionally word-split
  if modprobe "$name" $params 2>/dev/null; then
    $BDB update modules --where "name=$name" status=loaded >/dev/null 2>&1
    log "loaded  $name ${params:+($params)} [$stage]"
  else
    $BDB update modules --where "name=$name" status=failed >/dev/null 2>&1
    log "FAILED  $name [$stage]"
  fi
done

log "reconcile done"
