#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

for recipe in busybox bash base-runtime binutils gcc-bootstrap linux-headers glibc-bootstrap \
  forge-tools forge-libelf forge-openssl linux; do
  manifest="$ROOT/recipes/$recipe/MANIFEST"
  build="$ROOT/recipes/$recipe/build.sh"
  [ -f "$manifest" ]
  [ -x "$build" ]
  grep -q '^Format: altitude-package-1$' "$manifest"
  source_name="$recipe"
  [ "$recipe" != base-runtime ] || source_name=""
  [ "$recipe" != gcc-bootstrap ] || source_name=gcc
  [ "$recipe" != linux-headers ] || source_name=linux
  [ "$recipe" != glibc-bootstrap ] || source_name=glibc
  [ "$recipe" != forge-tools ] || source_name=m4
  [ "$recipe" != forge-libelf ] || source_name=elfutils
  [ "$recipe" != forge-openssl ] || source_name=openssl
  [ -z "$source_name" ] ||
    grep -q "^Source: $source_name$" "$ROOT/sources/SOURCES.lock"
  bash -n "$build"
done

grep -q -- '--prefix="$PREFIX"' "$ROOT/recipes/binutils/build.sh"
grep -q '^PREFIX="/opt/altitude/toolchain"$' "$ROOT/recipes/binutils/build.sh"
grep -q -- '--with-pkgversion="Altitude Linux 0.1 bootstrap"' \
  "$ROOT/recipes/gcc-bootstrap/build.sh"
grep -q 'headers_install' "$ROOT/recipes/linux-headers/build.sh"
grep -q 'all-target-libgcc' "$ROOT/recipes/gcc-bootstrap/build.sh"
grep -q 'export PATH=.*toolchain_path/bin' \
  "$ROOT/recipes/gcc-bootstrap/build.sh"
grep -q -- '--host="$TARGET_TRIPLET"' \
  "$ROOT/recipes/glibc-bootstrap/build.sh"
grep -q 'libc_cv_slibdir=/usr/lib' \
  "$ROOT/recipes/glibc-bootstrap/build.sh"
grep -q 'forge_path/bin' "$ROOT/recipes/glibc-bootstrap/build.sh"
grep -q 'CXX=false' "$ROOT/recipes/glibc-bootstrap/build.sh"
grep -q "CXX = false.*CXX =" "$ROOT/recipes/glibc-bootstrap/build.sh"
grep -q -- '-fno-asynchronous-unwind-tables' \
  "$ROOT/recipes/glibc-bootstrap/patches/0001-x86_64-bootstrap-libc-sigaction.patch"
grep -q '^Source: bison$' "$ROOT/sources/SOURCES.lock"
grep -q '^Source: gawk$' "$ROOT/sources/SOURCES.lock"
grep -q '^Source: flex$' "$ROOT/sources/SOURCES.lock"
grep -q '^Source: elfutils$' "$ROOT/sources/SOURCES.lock"
grep -q '^Source: openssl$' "$ROOT/sources/SOURCES.lock"
grep -q '^Source: bash$' "$ROOT/sources/SOURCES.lock"
grep -q -- '--enable-static-link' "$ROOT/recipes/bash/build.sh"
grep -q 'LDFLAGS="-static"' "$ROOT/recipes/bash/build.sh"
grep -q 'Debian-runtime-files: 0' "$ROOT/recipes/base-runtime/build.sh"
grep -q ' -static ' "$ROOT/recipes/base-runtime/build.sh"
grep -q 'cat > "\$PAYLOAD/init"' \
  "$ROOT/recipes/base-runtime/build.sh"
grep -q 'generic-x86_64.config' "$ROOT/recipes/linux/build.sh"
grep -q 'CONFIG_IWLWIFI=m' "$ROOT/recipes/linux/config/generic-x86_64.config"
grep -q 'CONFIG_DRM_NOUVEAU=m' "$ROOT/recipes/linux/config/generic-x86_64.config"
grep -q 'kmake -j"\$JOBS" bzImage modules' "$ROOT/recipes/linux/build.sh"
grep -q 'kmake modules_install' "$ROOT/recipes/linux/build.sh"
grep -q 'depmod -b "\$WORK/payload" -m /usr/lib/modules' \
  "$ROOT/recipes/linux/build.sh"
grep -q 'ALTITUDE_RECIPE_RESUME' "$ROOT/recipes/linux/build.sh"
grep -q '^Name: altitude-kernel$' "$ROOT/recipes/linux/MANIFEST"
grep -q "'\\*.ko.xz'" "$ROOT/build-disk.sh"
grep -q 'xz -d' "$ROOT/build-disk.sh"
grep -q 'BOOT_BUSYBOX=' "$ROOT/build-disk.sh"
grep -q -- '--show-depends' "$ROOT/build-disk.sh"

echo "Altitude source recipes: ok"
