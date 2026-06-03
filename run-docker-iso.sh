#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"
docker run --rm --platform linux/amd64 -v "$(cd .. && pwd)":/work minibash-linux-builder bash -lc '
  set -euo pipefail
  bash /work/minibash-linux/build.sh

  ISO_NAME=minibash-linux-custom-kernel.iso \
    bash /work/minibash-linux/build-iso.sh

  bash /work/minibash-linux/scripts/fetch-debian-kernel.sh \
    /work/minibash-linux/out/debian-vmlinuz

  KERNEL_IMAGE=/work/minibash-linux/out/debian-vmlinuz \
    ISO_NAME=minibash-linux.iso \
    bash /work/minibash-linux/build-iso.sh

  bash /work/minibash-linux/build-desktop-payload.sh

  KERNEL_IMAGE=/work/minibash-linux/out/debian-vmlinuz \
    DESKTOP_PAYLOAD_TAR=/work/minibash-linux/out/minibash-desktop-root.tar.gz \
    DESKTOP_PAYLOAD_MANIFEST=/work/minibash-linux/out/minibash-desktop-MANIFEST \
    USB_IMG=/work/minibash-linux/out/minibash-linux-usb.img \
    bash /work/minibash-linux/build-usb.sh
'
