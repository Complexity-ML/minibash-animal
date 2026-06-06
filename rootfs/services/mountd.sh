#!/usr/bin/env bash
# mountd -- reconcile the bdb `mounts` table into real Linux mounts.
#
# Hybrid Linux in action: /etc/fstab becomes ROWS. Each row declares a desired
# mount; mountd mounts/umounts to converge, then writes the real status back.
# Change a row -> the filesystem (un)mounts itself:
#   bdb update mounts --where dst=/mnt/data desired=unmounted
#   bdb insert mounts dst=/mnt/usb src=/dev/sdb1 fstype=ext4 opts=rw desired=mounted status=unmounted
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export BDB_PATH="${BDB_PATH:-/var/bdb}"
BDB=/bin/bdb
exec >>/var/log/mountd.log 2>&1
log() { echo "mountd: $* ($(date 2>/dev/null))"; }

[ -x /etc/minibash/bdb/seed.sh ] && /etc/minibash/bdb/seed.sh 2>/dev/null
$BDB tables 2>/dev/null | grep -qx mounts || { log "no 'mounts' table"; exit 0; }

is_mounted() { awk -v d="$1" '$2==d{f=1} END{exit !f}' /proc/mounts; }

# bdb dump mounts: TAB header then rows. cols: dst src fstype opts desired status
# Parse with cut (not `IFS=$'\t' read`) so empty fields (e.g. no opts) don't
# collapse and shift the columns -- TAB is IFS-whitespace.
$BDB dump mounts 2>/dev/null | tail -n +2 | while IFS= read -r line; do
  [ -n "$line" ] || continue
  dst=$(printf '%s' "$line" | cut -f1)
  src=$(printf '%s' "$line" | cut -f2)
  fstype=$(printf '%s' "$line" | cut -f3)
  opts=$(printf '%s' "$line" | cut -f4)
  desired=$(printf '%s' "$line" | cut -f5)
  case "$desired" in
    mounted)
      if is_mounted "$dst"; then
        $BDB update mounts --where "dst=$dst" status=mounted >/dev/null 2>&1
      else
        mkdir -p "$dst"
        if mount -t "$fstype" ${opts:+-o "$opts"} "$src" "$dst" 2>/dev/null; then
          $BDB update mounts --where "dst=$dst" status=mounted >/dev/null 2>&1
          log "mounted $src -> $dst ($fstype${opts:+,$opts})"
        else
          $BDB update mounts --where "dst=$dst" status=error >/dev/null 2>&1
          log "FAILED mount $src -> $dst"
        fi
      fi ;;
    unmounted)
      if is_mounted "$dst"; then
        umount "$dst" 2>/dev/null && log "umounted $dst" || log "umount busy: $dst"
      fi
      $BDB update mounts --where "dst=$dst" status=unmounted >/dev/null 2>&1 ;;
    *) log "dst=$dst: desired inconnu '$desired'" ;;
  esac
done
log "reconcile done"
