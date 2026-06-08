#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/gnome-session}"
VERSION=48.0
PAYLOAD="$WORK/payload"

rm -rf "$WORK"
mkdir -p "$PAYLOAD/usr/bin" \
  "$PAYLOAD/usr/share/applications" \
  "$PAYLOAD/usr/share/wayland-sessions" \
  "$PAYLOAD/usr/share/gnome-session/sessions" \
  "$PAYLOAD/usr/share/altitude/sources" "$OUT"

cat > "$PAYLOAD/usr/bin/gnome-session" <<'EOF'
#!/bin/sh
set -eu

export XDG_CURRENT_DESKTOP="${XDG_CURRENT_DESKTOP:-GNOME}"
export XDG_SESSION_DESKTOP="${XDG_SESSION_DESKTOP:-gnome}"
export XDG_SESSION_TYPE="${XDG_SESSION_TYPE:-wayland}"
export GNOME_SHELL_SESSION_MODE="${GNOME_SHELL_SESSION_MODE:-user}"
export GIO_USE_VFS="${GIO_USE_VFS:-local}"

if [ -z "${XDG_RUNTIME_DIR:-}" ]; then
  uid="$(id -u 2>/dev/null || echo 0)"
  export XDG_RUNTIME_DIR="/run/user/$uid"
fi
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true

if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] &&
   [ -z "${ALTITUDE_GNOME_SESSION_DBUS:-}" ] &&
   command -v dbus-run-session >/dev/null 2>&1; then
  export ALTITUDE_GNOME_SESSION_DBUS=1
  exec dbus-run-session -- "$0" "$@"
fi

if ! command -v gnome-shell >/dev/null 2>&1; then
  echo "gnome-session: gnome-shell is not installed" >&2
  exit 127
fi

exec gnome-shell --wayland "$@"
EOF
chmod 755 "$PAYLOAD/usr/bin/gnome-session"

cat > "$PAYLOAD/usr/share/wayland-sessions/altitude-gnome.desktop" <<'EOF'
[Desktop Entry]
Name=Altitude GNOME
Comment=GNOME Shell session for Altitude Linux
Exec=gnome-session
TryExec=gnome-session
Type=Application
DesktopNames=GNOME
X-GDM-SessionRegisters=true
EOF

cat > "$PAYLOAD/usr/share/gnome-session/sessions/altitude.session" <<'EOF'
[GNOME Session]
Name=Altitude GNOME
RequiredComponents=org.gnome.Shell;
EOF

cat > "$PAYLOAD/usr/share/applications/org.gnome.Settings.desktop" <<'EOF'
[Desktop Entry]
Name=Settings
Comment=Configure Altitude GNOME
Exec=/bin/false
Icon=preferences-system
Type=Application
Categories=GNOME;GTK;Settings;
NoDisplay=true
EOF

{
  echo "Source: Altitude Linux"
  echo "Version: $VERSION"
  echo "Build: non-systemd GNOME Shell Wayland session wrapper and Settings stub"
  echo "Upstream-note: gnome-session 48 requires GTK3 and systemd/libsystemd;"
  echo "Upstream-note: this package provides the Altitude session entry point."
} > "$PAYLOAD/usr/share/altitude/sources/gnome-session.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/gnome-session/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-gnome-session-$VERSION-amd64.altpkg"
