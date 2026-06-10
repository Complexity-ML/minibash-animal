#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

recipes=(
  python-build-runtime ninja meson cmake
  libffi pcre2 expat glib dbus
  forge-mesa-python wayland wayland-protocols libdrm mesa
  libpng freetype fontconfig pixman cairo harfbuzz pango gtk4
  fribidi datrie libthai gdk-pixbuf graphene libepoxy libxkbcommon
  gsettings-desktop-schemas gnome-desktop mutter gnome-shell gnome-session
  elogind polkit rtkit accountsservice upower udisks
  gmp nettle libtasn1 libunistring gnutls vte gnome-console
)

for recipe in "${recipes[@]}"; do
  manifest="$ROOT/recipes/$recipe/MANIFEST"
  build="$ROOT/recipes/$recipe/build.sh"
  [ -f "$manifest" ] || { echo "missing manifest: $recipe" >&2; exit 1; }
  [ -x "$build" ] || { echo "missing executable build script: $recipe" >&2; exit 1; }
  grep -q '^Format: altitude-package-1$' "$manifest"
  grep -q '^Name: altitude-' "$manifest"
  bash -n "$build"
done

sources=(
  python-build-runtime ninja meson cmake
  libffi pcre2 expat glib dbus
  mako pyyaml markupsafe wayland wayland_protocols libdrm mesa
  libpng freetype fontconfig pixman cairo harfbuzz pango gtk4
  fribidi datrie libthai gdk-pixbuf graphene libepoxy libxkbcommon
  gsettings-desktop-schemas gnome-desktop mutter gnome-shell gnome-session
  elogind polkit rtkit accountsservice upower udisks
  gmp nettle libtasn1 libunistring gnutls vte gnome-console
)

for source in "${sources[@]}"; do
  grep -q "^Source: $source$" "$ROOT/sources/SOURCES.lock" || {
    echo "missing locked source: $source" >&2
    exit 1
  }
done

awk '
  BEGIN { RS=""; FS="\n" }
  {
    source = ""
    for (i = 1; i <= NF; i++)
      if ($i ~ /^Source: /) source = substr($i, 9)
    if (source != "") {
      seen[source]++
      if (seen[source] > 1) {
        print "duplicate source: " source > "/dev/stderr"
        exit 1
      }
    }
  }
' "$ROOT/sources/SOURCES.lock"

grep -q -- '-Dgnutls=true' "$ROOT/recipes/vte/build.sh"
grep -q 'hardcode_into_libs=no' "$ROOT/recipes/libthai/build.sh"
grep -q "name '\\*.la' -delete" "$ROOT/recipes/datrie/build.sh"
grep -q "name '\\*.la' -delete" "$ROOT/recipes/libthai/build.sh"

echo "GNOME source recipes: ok"
