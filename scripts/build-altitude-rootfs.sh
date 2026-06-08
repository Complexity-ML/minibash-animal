#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${ALTITUDE_REPO_ROOT:-$ROOT/out/repository}"
DEST="${ALTITUDE_ROOTFS_DIR:-$ROOT/out/altitude-rootfs}"
ROOTFS_TGZ="${ROOTFS_TGZ:-$ROOT/out/altitude-rootfs.tar.gz}"
PROFILE="${ALTITUDE_PROFILE:-desktop}"

case "$PROFILE" in
  desktop|rescue) ;;
  *) echo "unknown ALTITUDE_PROFILE=$PROFILE (desktop, rescue)" >&2; exit 1 ;;
esac

require_package() {
  local package="$1"
  grep -q "^Package: $package$" "$REPO/INDEX" 2>/dev/null || {
    echo "missing native Altitude package: $package" >&2
    exit 1
  }
}

base_packages=(
  altitude-base-runtime
  altitude-busybox
  altitude-ncurses
  altitude-bash
  altitude-kernel
  altitude-dropbear
  altitude-wpa-supplicant
  altitude-identity
  altitude-core
  altitude-services
  altitude-access
)

desktop_packages=(
  altitude-python-build-runtime
  altitude-meson
  altitude-ninja
  altitude-cmake
  altitude-dbus
  altitude-glib
  altitude-wayland
  altitude-wayland-protocols
  altitude-libdrm
  altitude-mesa
  altitude-gtk4
  altitude-hicolor-icon-theme
  altitude-gsettings-desktop-schemas
  altitude-gnome-desktop
  altitude-json-c
  altitude-accountsservice
  altitude-gdm
  altitude-geoclue
  altitude-geocode-glib
  altitude-libgweather
  altitude-ibus
  altitude-upower
  altitude-mutter
  altitude-gnome-shell
  altitude-gnome-session
  altitude-elogind
  altitude-polkit
  # upower and udisks are tracked as desktop service recipes, but still need
  # service integration before they are useful in Altitude's init model.
)

packages=("${base_packages[@]}")
if [ "$PROFILE" = "desktop" ]; then
  packages+=("${desktop_packages[@]}")
fi

[ -f "$REPO/INDEX" ] || {
  echo "missing repository index: $REPO/INDEX" >&2
  echo "Build the native .altpkg repository first." >&2
  exit 1
}

for package in "${packages[@]}"; do
  require_package "$package"
done

bash "$ROOT/scripts/assemble-altitude-rootfs.sh" "$REPO" "$DEST" "${packages[@]}"
mkdir -p "$DEST"/{dev,proc,run,sys,tmp}
chmod 1777 "$DEST/tmp"
if command -v glib-compile-schemas >/dev/null 2>&1 &&
   [ -d "$DEST/usr/share/glib-2.0/schemas" ]; then
  glib-compile-schemas "$DEST/usr/share/glib-2.0/schemas"
elif [ -x "$DEST/usr/bin/glib-compile-schemas" ] &&
     [ -d "$DEST/usr/share/glib-2.0/schemas" ]; then
  "$DEST/usr/bin/glib-compile-schemas" "$DEST/usr/share/glib-2.0/schemas" ||
    echo "warning: could not compile GSettings schemas in $DEST" >&2
fi

tar_args=(-czf "$ROOTFS_TGZ" -C "$DEST" .)
if tar --help 2>&1 | grep -q -- '--owner'; then
  tar --numeric-owner --owner=0 --group=0 "${tar_args[@]}"
else
  tar --numeric-owner "${tar_args[@]}"
fi
echo "Altitude $PROFILE rootfs: $ROOTFS_TGZ"
