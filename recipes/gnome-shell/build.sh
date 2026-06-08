#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/gnome-shell}"
VERSION=48.8
TARGET="${ALTITUDE_TARGET_TRIPLET:-x86_64-altitude-linux-gnu}"
TOOLCHAIN_ROOT="${ALTITUDE_TOOLCHAIN_ROOT:-}"
FORGE_ROOT="${ALTITUDE_FORGE_ROOT:-}"
EXE_WRAPPER="${ALTITUDE_EXE_WRAPPER:-}"
TOOLCHAIN="$TOOLCHAIN_ROOT/opt/altitude/toolchain"
FORGE="$FORGE_ROOT/opt/altitude/forge"
SYSROOT="$TOOLCHAIN/sysroot"
CC="$TOOLCHAIN/bin/$TARGET-gcc"
AR="$TOOLCHAIN/bin/$TARGET-ar"
STRIP="$TOOLCHAIN/bin/$TARGET-strip"
PKG_CONFIG="$FORGE/bin/pkg-config"
PAYLOAD="$WORK/payload"
HOST_TOOLS="$WORK/host-tools"
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" gnome-shell)"

export PATH="$HOST_TOOLS:$FORGE/bin:$TOOLCHAIN/bin:$PATH"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export LD_LIBRARY_PATH="$WORK/build/src:$WORK/build/src/st:$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$SYSROOT/usr/lib/pulseaudio:$SYSROOT/usr/lib/evolution-data-server:$TOOLCHAIN/$TARGET/lib64:$FORGE/lib:${LD_LIBRARY_PATH:-}"
export LDFLAGS="-L$WORK/build/src -L$WORK/build/src/st -L$SYSROOT/usr/lib -L$SYSROOT/usr/lib/pulseaudio -L$SYSROOT/usr/lib/evolution-data-server -Wl,-rpath-link,$WORK/build/src -Wl,-rpath-link,$WORK/build/src/st -Wl,-rpath-link,$SYSROOT/usr/lib -Wl,-rpath-link,$SYSROOT/usr/lib64 -Wl,-rpath-link,$SYSROOT/usr/lib/pulseaudio -Wl,-rpath-link,$SYSROOT/usr/lib/evolution-data-server ${LDFLAGS:-}"

for tool in "$CC" "$AR" "$STRIP" "$PKG_CONFIG"; do
  [ -x "$tool" ] || { echo "gnome-shell: missing build tool: $tool" >&2; exit 1; }
done
for tool in meson ninja python3 gjs g-ir-scanner g-ir-compiler sassc; do
  command -v "$tool" >/dev/null ||
    { echo "gnome-shell: missing forge tool: $tool" >&2; exit 1; }
done
for dep in atk-bridge-2.0 libecal-2.0 libedataserver-1.2 gcr-4 \
  gdk-pixbuf-2.0 gobject-introspection-1.0 gio-2.0 gio-unix-2.0 gjs-1.0 \
  gtk4 libxml-2.0 mutter-clutter-16 mutter-mtk-16 mutter-cogl-16 \
  libmutter-16 polkit-agent-1 gsettings-desktop-schemas gnome-desktop-4 \
  pango libpulse libpulse-mainloop-glib alsa x11 xext xfixes; do
  "$PKG_CONFIG" --exists "$dep" ||
    { echo "gnome-shell: target dependency missing from $SYSROOT: $dep" >&2; exit 1; }
done

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/build" \
  "$PAYLOAD/usr/share/altitude/sources" "$HOST_TOOLS" "$OUT"
cat > "$HOST_TOOLS/ldd" <<EOF
#!/usr/bin/env sh
exec "$SYSROOT/usr/lib/ld-linux-x86-64.so.2" --list "\$@"
EOF
chmod 755 "$HOST_TOOLS/ldd"
cat > "$HOST_TOOLS/gtk-update-icon-cache" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
ln -sf gtk-update-icon-cache "$HOST_TOOLS/gtk4-update-icon-cache"
chmod 755 "$HOST_TOOLS/gtk-update-icon-cache"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

if [ -z "$EXE_WRAPPER" ]; then
  EXE_WRAPPER="$WORK/target-wrapper"
  cat > "$EXE_WRAPPER" <<EOF
#!/usr/bin/env sh
export LD_LIBRARY_PATH="$WORK/build/src:$WORK/build/src/st:$SYSROOT/usr/lib:$SYSROOT/usr/lib64:$SYSROOT/usr/lib/pulseaudio:$SYSROOT/usr/lib/evolution-data-server:$SYSROOT/lib:$SYSROOT/lib64:$TOOLCHAIN/$TARGET/lib64:$FORGE/lib:\${LD_LIBRARY_PATH:-}"
exec "\$@"
EOF
  chmod 755 "$EXE_WRAPPER"
fi

cat > "$WORK/cross.ini" <<EOF
[binaries]
c = '$CC'
ar = '$AR'
strip = '$STRIP'
pkg-config = '$PKG_CONFIG'
exe_wrapper = '$EXE_WRAPPER'

[properties]
sys_root = '$SYSROOT'
pkg_config_libdir = '$PKG_CONFIG_LIBDIR'
needs_exe_wrapper = true

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[built-in options]
c_link_args = ['-L$WORK/build/src', '-L$WORK/build/src/st', '-L$SYSROOT/usr/lib', '-L$SYSROOT/usr/lib/pulseaudio', '-L$SYSROOT/usr/lib/evolution-data-server', '-Wl,-rpath-link,$WORK/build/src', '-Wl,-rpath-link,$WORK/build/src/st', '-Wl,-rpath-link,$SYSROOT/usr/lib', '-Wl,-rpath-link,$SYSROOT/usr/lib64', '-Wl,-rpath-link,$SYSROOT/usr/lib/pulseaudio', '-Wl,-rpath-link,$SYSROOT/usr/lib/evolution-data-server', '-lpulsecommon-17.0', '-ldbus-1', '-lsndfile', '-lz', '-lpcre2-8', '-lffi', '-lm']
EOF

meson setup "$WORK/build" "$WORK/source" \
  --cross-file="$WORK/cross.ini" --prefix=/usr --libdir=lib \
  --sysconfdir=/etc --buildtype=release --wrap-mode=nofallback \
  -Dcamera_monitor=false -Dextensions_tool=false -Dextensions_app=false \
  -Dgtk_doc=false -Dman=false -Dtests=false \
  -Dnetworkmanager=false -Dportal_helper=false -Dsystemd=false
DESTDIR="$PAYLOAD" meson install -C "$WORK/build"
install -Dm644 "$ROOT/recipes/gnome-shell/org.gnome.settings-daemon.altitude.gschema.xml" \
  "$PAYLOAD/usr/share/glib-2.0/schemas/org.gnome.settings-daemon.altitude.gschema.xml"

find "$PAYLOAD/usr" -type f -perm -0100 -print0 |
  while IFS= read -r -d '' file; do
    "$STRIP" --strip-unneeded "$file" 2>/dev/null || true
  done
install -d "$SYSROOT/usr"
cp -a "$PAYLOAD/usr/." "$SYSROOT/usr/"

{
  echo "Source: gnome-shell"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: Wayland shell without systemd, NetworkManager or portal helper, cross $TARGET"
  echo "Compiler: $("$CC" --version | head -1)"
} > "$PAYLOAD/usr/share/altitude/sources/gnome-shell.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/gnome-shell/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-gnome-shell-$VERSION-amd64.altpkg"
