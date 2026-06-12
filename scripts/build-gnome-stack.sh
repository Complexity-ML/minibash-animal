#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
JOBS="${GNOME_RECIPE_JOBS:-4}"

"$ROOT/scripts/ensure-forge-make.sh"

build_layer() {
  local name="$1"
  shift
  local recipe pid failed
  local -a pids=()

  printf '[gnome-stack] layer %s: %s\n' "$name" "$*"
  failed=0
  for recipe in "$@"; do
    if ls "$ROOT/out/source-packages/altitude-$recipe"-*-amd64.altpkg >/dev/null 2>&1; then
      printf '[gnome-stack] skipping %s (package exists)\n' "$recipe"
      continue
    fi
    (
      printf '[gnome-stack] building %s\n' "$recipe"
      "$ROOT/scripts/build-source-recipe.sh" "$recipe"
    ) &
    pids+=("$!")
    if [ "${#pids[@]}" -ge "$JOBS" ]; then
      for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
      pids=()
    fi
  done
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  if [ "$failed" -ne 0 ]; then
    echo "[gnome-stack] layer $name failed" >&2
    exit 1
  fi
}

build_layer host-bootstrap forge-perl
build_layer core-primitives zlib libffi pcre2 expat ncurses openssl
build_layer trust ca-certificates
build_layer python python-build-runtime
build_layer compiler gcc-cxx
build_layer tooling forge-tools forge-cvt forge-gettext meson ninja cmake
build_layer python-tooling forge-jinja2 forge-distutils
build_layer core glib
build_layer ipc dbus
build_layer mesa-forge forge-mesa-python
build_layer graphics-primitives wayland libdrm
build_layer graphics-protocols wayland-protocols
build_layer x-protocols xorgproto xcb-proto
build_layer x-auth libxau libxdmcp
build_layer x-transport xtrans
build_layer xcb libxcb
build_layer x11 libx11 libxext libxfixes
build_layer graphics mesa
build_layer image-primitives libpng
build_layer ui-primitives freetype pixman
build_layer fonts fontconfig cantarell-fonts dejavu-fonts
build_layer text-primitives fribidi datrie
build_layer thai libthai
build_layer image gdk-pixbuf libtiff libjpeg-turbo
build_layer xml libxml2
build_layer css libcroco
build_layer svg librsvg
build_layer geometry graphene
build_layer gl-dispatch libepoxy
build_layer keymaps libxkbcommon
build_layer shaping harfbuzz
build_layer drawing cairo
build_layer text pango
build_layer toolkit gtk4
build_layer icon-theme hicolor-icon-theme adwaita-icon-theme
build_layer shell-schemas gsettings-desktop-schemas
build_layer desktop-data xkeyboard-config iso-codes
build_layer sandbox libseccomp
build_layer shell-desktop gnome-desktop
build_layer system-libs libcap util-linux e2fsprogs dosfstools
build_layer devices eudev
build_layer device-glue libgudev
build_layer login elogind
build_layer input-primitives libevdev mtdev
build_layer input libinput
build_layer introspection gobject-introspection
build_layer usb libusb libgusb
build_layer color-primitives lcms2
build_layer compositor-primitives atk at-spi2-core libei libdisplay-info
build_layer color colord
build_layer media gstreamer
build_layer shell-compositor mutter
build_layer rust-bootstrap forge-rust forge-cbindgen
build_layer css-tools forge-sassc
build_layer js-runtime mozjs gjs
build_layer eds-primitives sqlite libnghttp2 json-glib libsecret libpsl libsoup libical
build_layer unicode icu nspr nss
build_layer calendar-data evolution-data-server
build_layer location geoclue geocode-glib
build_layer weather libgweather
build_layer crypto-primitives libgpg-error libgcrypt
build_layer pkcs11 p11-kit
build_layer tls-primitives gmp nettle libtasn1 libunistring gnutls
build_layer certificate-ui gcr
build_layer policy-primitives duktape libxcrypt
build_layer policy polkit rtkit
build_layer audio alsa libsndfile pulseaudio
build_layer input-method ibus
build_layer shell gnome-shell
build_layer session gnome-session
build_layer desktop-services accountsservice upower udisks
build_layer terminal-primitives appstream libadwaita libgtop vte
build_layer terminal-apps gnome-console

printf '[gnome-stack] foundational GNOME stack complete\n'
