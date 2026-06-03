#!/usr/bin/env bash
set -euo pipefail

DISTRO_DIR="${DISTRO_DIR:-/work/minibash-linux}"
OUT_DIR="${OUT_DIR:-$DISTRO_DIR/out}"
PAYLOAD_DIR="${PAYLOAD_DIR:-/tmp/minibash-desktop-payload}"
DESKTOP_ROOTFS="${DESKTOP_ROOTFS:-/tmp/minibash-linux-desktop-rootfs}"
PAYLOAD_TAR="${PAYLOAD_TAR:-$OUT_DIR/minibash-desktop-root.tar.gz}"
PAYLOAD_MANIFEST="${PAYLOAD_MANIFEST:-$OUT_DIR/minibash-desktop-MANIFEST}"

log() {
  printf '[minibash:desktop] %s\n' "$*"
}

main() {
  rm -rf "$DESKTOP_ROOTFS" "$PAYLOAD_DIR"
  mkdir -p "$OUT_DIR" "$PAYLOAD_DIR"

  log "building desktop rootfs staging area"
  INCLUDE_DESKTOP=1 \
    ROOTFS_WORK="$DESKTOP_ROOTFS" \
    INITRAMFS_IMG="$OUT_DIR/.desktop-payload-initramfs.cpio.gz" \
    bash "$DISTRO_DIR/build.sh" >/dev/null
  rm -f "$OUT_DIR/.desktop-payload-initramfs.cpio.gz"

  log "packing desktop runtime payload"
  (
    cd "$DESKTOP_ROOTFS"
    tar -czf "$PAYLOAD_TAR" \
      bin/weston \
      bin/foot \
      bin/weston-terminal \
      usr/bin/weston \
      usr/bin/weston-* \
      usr/bin/foot \
      usr/bin/footclient \
      usr/lib/x86_64-linux-gnu \
      usr/share/weston \
      usr/share/terminfo \
      usr/share/applications \
      usr/share/icons \
      usr/share/glvnd \
      etc/xdg \
      etc/glvnd
  )

  {
    echo "name=minibash-desktop-runtime"
    echo "version=$(cat "$DISTRO_DIR/rootfs/etc/minibash/VERSION" 2>/dev/null || echo unknown)"
    echo "created=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    sha256sum "$PAYLOAD_TAR"
  } > "$PAYLOAD_MANIFEST"

  log "payload: $PAYLOAD_TAR"
  log "manifest: $PAYLOAD_MANIFEST"
}

main "$@"
