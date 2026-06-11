#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/out/BOOTX64-live.EFI}"
GRUB_CFG="$(mktemp)"
EFI_LABEL="${ALTITUDE_EFI_LABEL:-ALTITUDEEFI}"
ROOT_LABEL="${ALTITUDE_ROOT_LABEL:-altitude-native}"
KERNEL_PATH="${ALTITUDE_EFI_KERNEL:-/altitude-native/kernel}"
INITRD_PATH="${ALTITUDE_EFI_INITRD:-/altitude-native/initrd.img}"
VERSION="${ALTITUDE_VERSION:-$(cat "$ROOT/rootfs/etc/minibash/VERSION" 2>/dev/null || echo 0.1.0)}"
GRUB_MKSTANDALONE="${GRUB_MKSTANDALONE:-}"

cleanup() { rm -f "$GRUB_CFG"; }
trap cleanup EXIT

cat > "$GRUB_CFG" <<'CFG'
set default=0
set timeout=10
set timeout_style=menu
terminal_output console

menuentry "__ALTITUDE_TITLE__ - desktop" {
  search --no-floppy --label __EFI_LABEL__ --set=esp
  linux ($esp)__KERNEL_PATH__ root=LABEL=__ROOT_LABEL__ rootfstype=ext4 rw fsck.repair=yes init=/init altitude.init=systemd systemd.unit=graphical.target console=tty0 console=ttyS0,115200 panic=0 loglevel=4 minibash.tty=tty1 minibash.autologin=root minibash.keymap=fr
  initrd ($esp)__INITRD_PATH__
}

menuentry "__ALTITUDE_TITLE__ - repair console" {
  search --no-floppy --label __EFI_LABEL__ --set=esp
  linux ($esp)__KERNEL_PATH__ root=LABEL=__ROOT_LABEL__ rootfstype=ext4 rw fsck.repair=yes init=/init altitude.init=systemd systemd.unit=multi-user.target console=tty0 console=ttyS0,115200 panic=0 loglevel=7 minibash.tty=tty1 minibash.autologin=root minibash.keymap=fr
  initrd ($esp)__INITRD_PATH__
}

menuentry "__ALTITUDE_TITLE__ - serial repair" {
  search --no-floppy --label __EFI_LABEL__ --set=esp
  linux ($esp)__KERNEL_PATH__ root=LABEL=__ROOT_LABEL__ rootfstype=ext4 rw fsck.repair=yes init=/init altitude.init=systemd systemd.unit=multi-user.target console=ttyS0,115200 panic=0 loglevel=7 minibash.tty=ttyS0 minibash.autologin=root minibash.keymap=fr
  initrd ($esp)__INITRD_PATH__
}
CFG

sed -i.bak \
  -e "s|__ALTITUDE_TITLE__|Altitude Linux $VERSION|g" \
  -e "s|__EFI_LABEL__|$EFI_LABEL|g" \
  -e "s|__ROOT_LABEL__|$ROOT_LABEL|g" \
  -e "s|__KERNEL_PATH__|$KERNEL_PATH|g" \
  -e "s|__INITRD_PATH__|$INITRD_PATH|g" \
  "$GRUB_CFG"
rm -f "$GRUB_CFG.bak"

if [ -z "$GRUB_MKSTANDALONE" ]; then
  if [ -x /opt/altitude/forge/bin/grub-mkstandalone ]; then
    GRUB_MKSTANDALONE=/opt/altitude/forge/bin/grub-mkstandalone
  elif command -v grub-mkstandalone >/dev/null 2>&1; then
    GRUB_MKSTANDALONE="$(command -v grub-mkstandalone)"
  else
    echo "build-live-bootefi: missing grub-mkstandalone" >&2
    echo "build-live-bootefi: build/install the Altitude grub recipe or set GRUB_MKSTANDALONE=/path/to/grub-mkstandalone" >&2
    exit 1
  fi
fi

mkdir -p "$(dirname "$OUT")"
"$GRUB_MKSTANDALONE" \
  -O x86_64-efi \
  --modules="part_gpt fat ext2 search search_label linux normal configfile efi_gop efi_uga all_video serial terminal" \
  -o "$OUT" \
  "boot/grub/grub.cfg=$GRUB_CFG" >/dev/null

ls -lh "$OUT"
