#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="${1:?usage: capture-altitude-system.sh ROOTFS [OUTPUT_DIR]}"
OUT="${2:-$ROOT/out/system-packages}"
BUILDER="$ROOT/rootfs/bin/altpkg-build"

[ -d "$SOURCE" ] || { echo "missing rootfs: $SOURCE" >&2; exit 1; }
command -v rsync >/dev/null || { echo "rsync is required" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

make_manifest() {
  local name="$1" version="$2" arch="$3" description="$4"
  mkdir -p "$work/$name/payload"
  {
    echo "Format: altitude-package-1"
    echo "Name: $name"
    echo "Version: $version"
    echo "Architecture: $arch"
    echo "Description: $description"
  } > "$work/$name/MANIFEST"
}

make_manifest altitude-base 0.1.0 amd64 "Altitude base userspace snapshot"
make_manifest altitude-kernel 0.1.0 amd64 \
  "Altitude kernel, modules and initramfs"
make_manifest altitude-firmware 0.1.0 all \
  "Altitude hardware firmware collection"

base_excludes=(
  --exclude=/boot
  --exclude=/lib/modules
  --exclude=/usr/lib/modules
  --exclude=/lib/firmware
  --exclude=/usr/lib/firmware
  --exclude=/usr/lib/crda
  --exclude=/proc
  --exclude=/sys
  --exclude=/dev
  --exclude=/run
  --exclude=/tmp
  --exclude=/.cache
  --exclude=/lost+found
  --exclude=/init.new
  --exclude=/init.pre-*
  --exclude=/init.prev.*
  --exclude=/vmlinuz
  --exclude=/vmlinuz.old
  --exclude=/initrd.img
  --exclude=/initrd.img.old
  --exclude=/home/*
  --exclude=/root/.ssh
  --exclude=/var/bdb
  --exclude=/etc/apt
  --exclude=/etc/dpkg
  --exclude=/etc/debian_version
  --exclude=/var/cache/apt
  --exclude=/var/lib/apt/lists
  --exclude=/var/lib/dpkg
  --exclude=/var/lib/NetworkManager
  --exclude=/var/lib/altitude/packages
  --exclude=/var/lib/altitude/repository
  --exclude=/var/log/*
  --exclude=/var/tmp/*
  --exclude=/etc/NetworkManager/system-connections
  --exclude=/etc/ssh/ssh_host_*
  --exclude=/etc/dropbear/dropbear_*
  --exclude=/etc/wpa_supplicant.conf
  --exclude=/etc/minibash/wifi.creds
  --exclude=/usr/bin/apt
  --exclude=/usr/bin/apt-*
  --exclude=/usr/bin/dpkg
  --exclude=/usr/bin/dpkg-*
  --exclude=/usr/sbin/dpkg-*
  --exclude=/usr/lib/apt
  --exclude=/usr/lib/dpkg
  --exclude=/usr/share/dpkg
)
for recipe in "$ROOT"/packages/altitude-*/FILES; do
  [ -f "$recipe" ] || continue
  while IFS= read -r owned; do
    [ -n "$owned" ] || continue
    base_excludes+=("--exclude=/$owned")
    case "$owned" in
      bin/*|sbin/*|lib/*|lib64/*)
        base_excludes+=("--exclude=/usr/$owned")
        ;;
    esac
  done < "$recipe"
done

rsync -a --numeric-ids "${base_excludes[@]}" \
  "$SOURCE/" "$work/altitude-base/payload/"

copy_group() {
  local package="$1"
  shift
  local path
  for path in "$@"; do
    [ -e "$SOURCE/$path" ] || [ -L "$SOURCE/$path" ] || continue
    mkdir -p "$work/$package/payload/$(dirname "$path")"
    rsync -a "$SOURCE/$path" "$work/$package/payload/$(dirname "$path")/"
  done
}
copy_group altitude-kernel boot usr/lib/modules
copy_group altitude-firmware usr/lib/firmware usr/lib/crda

for package in altitude-base altitude-kernel altitude-firmware; do
  version="$(sed -n 's/^Version: *//p' "$work/$package/MANIFEST")"
  arch="$(sed -n 's/^Architecture: *//p' "$work/$package/MANIFEST")"
  bash "$BUILDER" "$work/$package/MANIFEST" "$work/$package/payload" \
    "$OUT/$package-$version-$arch.altpkg"
done

echo "Altitude system snapshot: $OUT"
