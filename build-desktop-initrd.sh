#!/usr/bin/env bash
set -euo pipefail

DISTRO_DIR="${DISTRO_DIR:-/work/minibash-linux}"
OUT_DIR="${OUT_DIR:-$DISTRO_DIR/out}"
DESKTOP_ROOTFS="${DESKTOP_ROOTFS:-/tmp/minibash-linux-desktop-rootfs}"
OVERLAY_ROOT="${OVERLAY_ROOT:-/tmp/minibash-linux-desktop-overlay}"
DESKTOP_INITRD="${DESKTOP_INITRD:-$OUT_DIR/minibash-desktop.cpio.gz}"

log() {
  printf '[minibash:desktop-initrd] %s\n' "$*"
}

copy_path() {
  local src="$1"
  [ -e "$DESKTOP_ROOTFS/$src" ] || return 0
  mkdir -p "$OVERLAY_ROOT/$(dirname "$src")"
  cp -a "$DESKTOP_ROOTFS/$src" "$OVERLAY_ROOT/$src"
}

main() {
  rm -rf "$DESKTOP_ROOTFS" "$OVERLAY_ROOT"
  mkdir -p "$OUT_DIR" "$OVERLAY_ROOT"

  log "building desktop staging rootfs"
  INCLUDE_DESKTOP=1 \
    ROOTFS_WORK="$DESKTOP_ROOTFS" \
    INITRAMFS_IMG="$OUT_DIR/.desktop-staging.cpio.gz" \
    bash "$DISTRO_DIR/build.sh" >/dev/null
  rm -f "$OUT_DIR/.desktop-staging.cpio.gz"

  log "copying desktop runtime into overlay"
  for path in \
    bin/weston \
    bin/foot \
    bin/weston-terminal \
    lib/x86_64-linux-gnu \
    usr/bin/weston \
    usr/bin/weston-terminal \
    usr/bin/foot \
    usr/bin/footclient \
    bin/sway \
    bin/setpriv \
    usr/bin/sway \
    usr/bin/setpriv \
    sbin/seatd \
    usr/sbin/seatd \
    usr/share/sway \
    etc/sway \
    usr/bin/fc-cache \
    usr/lib/locale \
    etc/fonts \
    usr/share/fonts \
    usr/share/fontconfig \
    var/cache/fontconfig \
    bin/udevadm \
    usr/bin/udevadm \
    lib/systemd/systemd-udevd \
    usr/lib/systemd/systemd-udevd \
    lib/udev \
    usr/lib/udev \
    etc/udev \
    usr/lib/x86_64-linux-gnu \
    usr/share/weston \
    usr/share/terminfo \
    usr/share/applications \
    usr/share/X11 \
    usr/share/icons \
    usr/share/glvnd \
    etc/X11 \
    etc/xdg \
    etc/glvnd; do
    copy_path "$path"
  done

  mkdir -p "$OVERLAY_ROOT/etc/minibash/bdb/tables/services"
  sed \
    's#^ZGVza3RvcGQ=\tL3NlcnZpY2VzL2Rlc2t0b3BkLnNo\tZmFsc2U=\tdHJ1ZQ==\tZG93bg==#ZGVza3RvcGQ=\tL3NlcnZpY2VzL2Rlc2t0b3BkLnNo\tdHJ1ZQ==\tdHJ1ZQ==\tdXA=#' \
    "$DISTRO_DIR/rootfs/etc/minibash/bdb/tables/services/data.tsv" \
    > "$OVERLAY_ROOT/etc/minibash/bdb/tables/services/data.tsv"

  log "packing $DESKTOP_INITRD"
  (
    cd "$OVERLAY_ROOT"
    find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$DESKTOP_INITRD"
  )
  log "desktop initrd: $DESKTOP_INITRD"
}

main "$@"
