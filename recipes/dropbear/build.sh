#!/usr/bin/env bash
# dropbear cross-built STATIC by the Altitude toolchain -- the SSH server for the
# native slot (remote shell). Self-contained crypto (bundled libtomcrypt/
# libtommath), no OpenSSL. Static so it runs on the console-first native root.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${ALTITUDE_RECIPE_OUT:-$ROOT/out/source-packages}"
WORK="${ALTITUDE_RECIPE_WORK:-$ROOT/out/source-work/dropbear}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)}"
VERSION=2024.85
TARGET=x86_64-altitude-linux-gnu
CROSS="$TARGET-"
TOOLCHAIN=/opt/altitude/toolchain
FORGE=/opt/altitude/forge
TARBALL="$(bash "$ROOT/scripts/source-fetch.sh" dropbear)"

export PATH="$FORGE/bin:$TOOLCHAIN/bin:$PATH"

rm -rf "$WORK"
mkdir -p "$WORK/source" "$WORK/payload/usr/sbin" "$WORK/payload/usr/bin" \
  "$WORK/payload/usr/share/altitude/sources" "$OUT"
tar -xf "$TARBALL" -C "$WORK/source" --strip-components=1

# glibc 2.41 dropped crypt() (now libxcrypt). We authenticate by SSH key
# (authorized_keys), which is more secure anyway, so disable password auth -- no
# crypt() needed. Password auth can return later via a libxcrypt forge recipe.
cat > "$WORK/source/localoptions.h" <<'EOF'
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PUBKEY_AUTH 1
EOF

( cd "$WORK/source"
  # --disable-harden: drops dropbear's -D_FORTIFY_SOURCE=2, which is the only
  # thing tripping a toolchain headers bug (gcc<->glibc limits.h include_next
  # chain leaves MB_LEN_MAX at the freestanding 1, so glibc's bits/stdlib.h
  # FORTIFY assert fails). dropbear stays fully functional; fixing the toolchain
  # fixinc/limits.h is a separate follow-up.
  ac_cv_lib_crypt_crypt=no ac_cv_func_crypt=no ./configure --host="$TARGET" CC="${CROSS}gcc" \
    --disable-zlib --disable-pam --disable-wtmp --disable-lastlog --disable-harden
  sed -i.bak 's/[[:space:]]-lcrypt//g' Makefile
  make -j"$JOBS" PROGRAMS="dropbear dropbearkey scp dbclient" STATIC=1
)

install -m755 "$WORK/source/dropbear"    "$WORK/payload/usr/sbin/dropbear"
install -m755 "$WORK/source/dropbearkey" "$WORK/payload/usr/bin/dropbearkey"
[ -f "$WORK/source/scp" ]      && install -m755 "$WORK/source/scp"      "$WORK/payload/usr/bin/scp"      || true
[ -f "$WORK/source/dbclient" ] && install -m755 "$WORK/source/dbclient" "$WORK/payload/usr/bin/dbclient" || true

{
  echo "Source: dropbear"
  echo "Version: $VERSION"
  echo "SHA256: $(sha256sum "$TARBALL" | awk '{print $1}')"
  echo "Build: static cross $TARGET (bundled crypto)"
  echo "Compiler: $(${CROSS}gcc --version | head -1)"
} > "$WORK/payload/usr/share/altitude/sources/dropbear.build"

bash "$ROOT/rootfs/bin/altpkg-build" \
  "$ROOT/recipes/dropbear/MANIFEST" "$WORK/payload" \
  "$OUT/altitude-dropbear-$VERSION-amd64.altpkg"
