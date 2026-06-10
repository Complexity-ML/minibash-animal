#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REPO="${ALTITUDE_REPO_ROOT:-$ROOT/out/repository}"
DEST="${ALTITUDE_ROOTFS_DIR:-$ROOT/out/altitude-rootfs}"
ROOTFS_TGZ="${ROOTFS_TGZ:-$ROOT/out/altitude-rootfs.tar.gz}"
PROFILE="${ALTITUDE_PROFILE:-desktop}"
EMBED_REPOSITORY="${ALTITUDE_EMBED_REPOSITORY:-1}"

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
  altitude-desktop-base
  altitude-python-build-runtime
  altitude-meson
  altitude-ninja
  altitude-cmake
  altitude-ca-certificates
  altitude-openssl
  altitude-expat
  altitude-zlib
  altitude-libffi
  altitude-pcre2
  altitude-libxcrypt
  altitude-dbus
  altitude-systemd
  altitude-glib
  altitude-cantarell-fonts
  altitude-freetype
  altitude-fontconfig
  altitude-libpng
  altitude-pixman
  altitude-cairo
  altitude-fribidi
  altitude-harfbuzz
  altitude-datrie
  altitude-libthai
  altitude-pango
  altitude-libjpeg-turbo
  altitude-libtiff
  altitude-gdk-pixbuf
  altitude-libxml2
  altitude-json-glib
  altitude-graphene
  altitude-libepoxy
  altitude-libxkbcommon
  altitude-atk
  altitude-at-spi2-core
  altitude-wayland
  altitude-wayland-protocols
  altitude-xorgproto
  altitude-xtrans
  altitude-xcb-proto
  altitude-libxau
  altitude-libxdmcp
  altitude-libxcb
  altitude-libx11
  altitude-libxext
  altitude-libxfixes
  altitude-libdrm
  altitude-mesa
  altitude-lz4
  altitude-gmp
  altitude-nettle
  altitude-libtasn1
  altitude-libunistring
  altitude-gnutls
  altitude-fast-float
  altitude-icu
  altitude-gcc-cxx
  altitude-gtk4
  altitude-appstream
  altitude-libadwaita
  altitude-vte
  altitude-libgtop
  altitude-gnome-console
  altitude-hicolor-icon-theme
  altitude-adwaita-icon-theme
  altitude-gsettings-desktop-schemas
  altitude-gobject-introspection
  altitude-gnome-desktop
  altitude-sqlite
  altitude-json-c
  altitude-libgcrypt
  altitude-libgpg-error
  altitude-libpsl
  altitude-libnghttp2
  altitude-libsoup
  altitude-nspr
  altitude-nss
  altitude-p11-kit
  altitude-gcr
  altitude-libsecret
  altitude-iso-codes
  altitude-libical
  altitude-evolution-data-server
  altitude-libusb
  altitude-libgusb
  altitude-lcms2
  altitude-eudev
  altitude-libgudev
  altitude-libevdev
  altitude-mtdev
  altitude-libei
  altitude-libinput
  altitude-libdisplay-info
  altitude-libseccomp
  altitude-libcap
  altitude-libnl
  altitude-util-linux
  altitude-alsa
  altitude-libsndfile
  altitude-pulseaudio
  altitude-accountsservice
  altitude-gdm
  altitude-colord
  altitude-libcroco
  altitude-librsvg
  altitude-gstreamer
  altitude-geoclue
  altitude-geocode-glib
  altitude-libgweather
  altitude-ibus
  altitude-upower
  altitude-mozjs
  altitude-gjs
  altitude-mutter
  altitude-gnome-shell
  altitude-gnome-session
  altitude-elogind
  altitude-polkit
  altitude-rtkit
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

if [ "$EMBED_REPOSITORY" = 1 ]; then
  mkdir -p "$DEST/var/lib/altitude/repository/packages" "$DEST/etc/altitude/keys"
  cp -a "$REPO/INDEX" "$REPO/INDEX.sig" "$DEST/var/lib/altitude/repository/"
  cp -a "$REPO/repository.pem" "$DEST/var/lib/altitude/repository/"
  cp -a "$REPO/repository.pem" "$DEST/etc/altitude/keys/repository.pem"
  cp -a "$REPO"/packages/*.altpkg "$REPO"/packages/*.altpkg.sig \
    "$DEST/var/lib/altitude/repository/packages/"
fi

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
