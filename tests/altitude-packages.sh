#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/payload/usr/share/altitude"
echo "Basecamp" > "$TMP/payload/usr/share/altitude/release"
cat > "$TMP/MANIFEST" <<'EOF'
Format: altitude-package-1
Name: altitude-test
Version: 1.0.0
Architecture: all
Description: Altitude package integration test
EOF

bash "$ROOT/rootfs/bin/altpkg-build" "$TMP/MANIFEST" "$TMP/payload" \
  "$TMP/altitude-test-1.0.0-all.altpkg"
ALTITUDE_REPO_ROOT="$TMP/repository" bash "$ROOT/rootfs/bin/altrepo" init
ALTITUDE_REPO_ROOT="$TMP/repository" bash "$ROOT/rootfs/bin/altrepo" keygen
ALTITUDE_REPO_ROOT="$TMP/repository" bash "$ROOT/rootfs/bin/altrepo" add \
  "$TMP/altitude-test-1.0.0-all.altpkg"
ALTITUDE_REPO_ROOT="$TMP/repository" bash "$ROOT/rootfs/bin/altrepo" verify

# Packages cannot smuggle symlinks into the destination root.
mkdir -p "$TMP/link-payload"
ln -s /etc/passwd "$TMP/link-payload/passwd"
set +e
bash "$ROOT/rootfs/bin/altpkg-build" "$TMP/MANIFEST" "$TMP/link-payload" \
  "$TMP/invalid.altpkg" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]

mkdir -p "$TMP/root" "$TMP/state" "$TMP/db"
cc -std=c11 -O2 -Wall -Wextra -Werror \
  -o "$TMP/bdbc" "$ROOT/rootfs/usr/src/minibash/bdbc.c"
BDB_PATH="$TMP/db" "$TMP/bdbc" init
BDB_PATH="$TMP/db" "$TMP/bdbc" create packages name:text:pk version:text \
  state:text source:text checksum:text description:text
mkdir -p "$TMP/etc"
cat > "$TMP/etc/repositories.conf" <<EOF
Repository: test
Location: file://$TMP/repository
Public-Key: $TMP/repository/repository.pem
EOF

BDB_BIN="$TMP/bdbc" BDB_PATH="$TMP/db" ALTITUDE_ROOT="$TMP/root" \
  ALTITUDE_PKG_STATE="$TMP/state" ALTITUDE_REPO_CONF="$TMP/etc/repositories.conf" \
  bash "$ROOT/rootfs/bin/pkg" install altitude-test
grep -qx Basecamp "$TMP/root/usr/share/altitude/release"
BDB_BIN="$TMP/bdbc" BDB_PATH="$TMP/db" ALTITUDE_ROOT="$TMP/root" \
  ALTITUDE_PKG_STATE="$TMP/state" ALTITUDE_REPO_CONF="$TMP/etc/repositories.conf" \
  bash "$ROOT/rootfs/bin/pkg" verify altitude-test
BDB_BIN="$TMP/bdbc" BDB_PATH="$TMP/db" ALTITUDE_ROOT="$TMP/root" \
  ALTITUDE_PKG_STATE="$TMP/state" ALTITUDE_REPO_CONF="$TMP/etc/repositories.conf" \
  bash "$ROOT/rootfs/bin/pkg" refresh >/dev/null
BDB_BIN="$TMP/bdbc" BDB_PATH="$TMP/db" ALTITUDE_ROOT="$TMP/root" \
  ALTITUDE_PKG_STATE="$TMP/state" ALTITUDE_REPO_CONF="$TMP/etc/repositories.conf" \
  bash "$ROOT/rootfs/bin/pkg" check-updates | grep -q 'system packages are current'

printf tampered > "$TMP/root/usr/share/altitude/release"
set +e
BDB_BIN="$TMP/bdbc" BDB_PATH="$TMP/db" ALTITUDE_ROOT="$TMP/root" \
  ALTITUDE_PKG_STATE="$TMP/state" ALTITUDE_REPO_CONF="$TMP/etc/repositories.conf" \
  bash "$ROOT/rootfs/bin/pkg" verify altitude-test >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
echo "Altitude package/repository integration: ok"
