#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/hicolor-icon-theme}"
VERSION=0.1.0
PAYLOAD="$WORK/payload"

rm -rf "$WORK"
mkdir -p "$PAYLOAD/usr/share/icons/hicolor/scalable/actions" \
  "$PAYLOAD/usr/share/icons/hicolor/scalable/apps" \
  "$PAYLOAD/usr/share/altitude/sources" "$OUT"

cat > "$PAYLOAD/usr/share/icons/hicolor/index.theme" <<'EOF'
[Icon Theme]
Name=Hicolor
Comment=Fallback icon theme
Directories=scalable/actions,scalable/apps

[scalable/actions]
Context=Actions
Size=16
MinSize=8
MaxSize=512
Type=Scalable

[scalable/apps]
Context=Applications
Size=16
MinSize=8
MaxSize=512
Type=Scalable
EOF

cat > "$PAYLOAD/usr/share/icons/hicolor/scalable/actions/system-shutdown-symbolic.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path fill="#2e3436" d="M7 1h2v7H7z"/>
  <path fill="#2e3436" d="M5.05 3.05 6.46 4.46A4 4 0 1 0 9.54 4.46l1.41-1.41A6 6 0 1 1 5.05 3.05z"/>
</svg>
EOF
ln -s system-shutdown-symbolic.svg \
  "$PAYLOAD/usr/share/icons/hicolor/scalable/actions/system-shutdown-symbolic-ltr.svg"
ln -s system-shutdown-symbolic.svg \
  "$PAYLOAD/usr/share/icons/hicolor/scalable/actions/system-shutdown-symbolic-rtl.svg"

cat > "$PAYLOAD/usr/share/icons/hicolor/scalable/apps/preferences-system.svg" <<'EOF'
<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 16 16">
  <path fill="#2e3436" d="M7 1h2l.4 2a5 5 0 0 1 1 .4l1.7-1.1 1.4 1.4-1.1 1.7q.3.5.4 1L15 7v2l-2.2.6a5 5 0 0 1-.4 1l1.1 1.7-1.4 1.4-1.7-1.1a5 5 0 0 1-1 .4L9 15H7l-.4-2a5 5 0 0 1-1-.4l-1.7 1.1-1.4-1.4 1.1-1.7a5 5 0 0 1-.4-1L1 9V7l2.2-.6a5 5 0 0 1 .4-1L2.5 3.7l1.4-1.4 1.7 1.1a5 5 0 0 1 1-.4zM8 5a3 3 0 1 0 0 6 3 3 0 0 0 0-6z"/>
</svg>
EOF

{
  echo "Source: Altitude Linux"
  echo "Version: $VERSION"
  echo "Build: minimal hicolor fallback icon theme for GNOME Shell"
} > "$PAYLOAD/usr/share/altitude/sources/hicolor-icon-theme.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/hicolor-icon-theme/MANIFEST" "$PAYLOAD" \
  "$OUT/altitude-hicolor-icon-theme-$VERSION-all.altpkg"
