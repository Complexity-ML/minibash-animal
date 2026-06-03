#!/usr/bin/env bash
set -u

export PATH=/bin:/usr/bin:/sbin:/usr/sbin:/services
export BDB_PATH=/var/bdb
export MINIBASH_ETC=/etc/minibash

log() {
  printf '[minibash:init] %s\n' "$*"
}

setup_console() {
  if [ -c /dev/console ]; then
    exec </dev/console >/dev/console 2>&1 || true
  fi
}

mount_fs() {
  mkdir -p /proc /sys /dev /run /tmp /var/log /var/bdb
  mount -t proc proc /proc 2>/dev/null || true
  mount -t sysfs sysfs /sys 2>/dev/null || true
  mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
  mount -t tmpfs tmpfs /run 2>/dev/null || true
}

seed_database() {
  if [ ! -d "$BDB_PATH/tables/services" ]; then
    log "seeding service database"
    mkdir -p "$BDB_PATH"
    cp -R "$MINIBASH_ETC/bdb/." "$BDB_PATH/"
  fi
}

main() {
  setup_console
  log "booting minibash linux"
  mount_fs
  seed_database

  /bin/bdbboot || true
  /bin/bashsvc init || true
  /bin/bashsvc start-autostart || true

  log "ready"
  while true; do
    bash -i || true
    log "shell exited; reopening"
    sleep 1
  done
}

main "$@"
