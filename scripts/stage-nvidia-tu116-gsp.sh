#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="${1:-$ROOT/rootfs/usr/lib/firmware}"
WORK="${ALTITUDE_NVIDIA_GSP_WORK:-$ROOT/out/nvidia-gsp-work}"
VERSION="${ALTITUDE_NVIDIA_DRIVER_VERSION:-570.144}"
RUN="NVIDIA-Linux-x86_64-$VERSION.run"
URL="${ALTITUDE_NVIDIA_DRIVER_URL:-https://us.download.nvidia.com/XFree86/Linux-x86_64/$VERSION/$RUN}"
BOOTLOADER_SRC="${ALTITUDE_NVIDIA_TU_BOOTLOADER:-$ROOT/out/linux-firmware/nvidia/tu102/gsp/bootloader-$VERSION.bin}"

mkdir -p "$WORK" "$DEST/nvidia/tu116/gsp"

if [ ! -s "$WORK/$RUN" ]; then
  curl -L -o "$WORK/$RUN" "$URL"
fi

rm -rf "$WORK/extract"
sh "$WORK/$RUN" --extract-only --target "$WORK/extract" >/dev/null

if [ ! -s "$WORK/extract/firmware/gsp_tu10x.bin" ]; then
  echo "missing extracted firmware/gsp_tu10x.bin" >&2
  exit 1
fi

if [ ! -s "$BOOTLOADER_SRC" ]; then
  cat >&2 <<EOF
missing Turing GSP bootloader: $BOOTLOADER_SRC

Provide it from linux-firmware, for example:
  git clone --sparse https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git "$ROOT/out/linux-firmware"
  git -C "$ROOT/out/linux-firmware" sparse-checkout set nvidia/tu102/gsp
EOF
  exit 1
fi

install -m 0644 "$WORK/extract/firmware/gsp_tu10x.bin" \
  "$DEST/nvidia/tu116/gsp/gsp-$VERSION.bin"
install -m 0644 "$BOOTLOADER_SRC" \
  "$DEST/nvidia/tu116/gsp/bootloader-$VERSION.bin"

sha256sum \
  "$DEST/nvidia/tu116/gsp/gsp-$VERSION.bin" \
  "$DEST/nvidia/tu116/gsp/bootloader-$VERSION.bin"
