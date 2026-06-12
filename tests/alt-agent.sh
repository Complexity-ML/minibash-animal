#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/bin" "$TMP/scripts" "$TMP/logs" "$TMP/repo"

cat > "$TMP/bin/pkg" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  refresh) echo "pkg refresh ok" ;;
  info) echo "Package: $2" ;;
  verify) echo "pkg verify ${2:-all}" ;;
  *) exit 64 ;;
esac
EOF
cat > "$TMP/bin/systemd-audit" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  refresh) echo refreshed ;;
  list) echo "UNIT LOAD ACTIVE SUB DESCRIPTION" ;;
  *) exit 64 ;;
esac
EOF
cat > "$TMP/bin/bdbctl" <<'EOF'
#!/usr/bin/env bash
[ "$1" = systemd ] && echo systemd-ok
EOF
cat > "$TMP/scripts/use-altitude-workshop.sh" <<EOF
#!/usr/bin/env bash
export ALTITUDE_WORKSHOP_ROOT="$TMP/workshop"
export ALTITUDE_REPO_ROOT="$TMP/repo"
export ALTITUDE_PACKAGE_STAGING="$TMP/staging"
if [ "\${BASH_SOURCE[0]}" = "\$0" ]; then
  echo "export ALTITUDE_WORKSHOP_ROOT=$TMP/workshop"
  echo "export ALTITUDE_REPO_ROOT=$TMP/repo"
  echo "export ALTITUDE_PACKAGE_STAGING=$TMP/staging"
fi
EOF
cat > "$TMP/scripts/build-source-recipe.sh" <<'EOF'
#!/usr/bin/env bash
echo "build $1"
EOF
cat > "$TMP/scripts/publish-workshop-packages.sh" <<'EOF'
#!/usr/bin/env bash
echo publish
EOF
chmod +x "$TMP/bin/"* "$TMP/scripts/"*
mkdir -p "$TMP/recipes/demo"
echo '# demo build' > "$TMP/recipes/demo/build.sh"

mkdir -p "$TMP/repo"
cat > "$TMP/repo/INDEX" <<'EOF'
Package: altitude-demo
EOF

PATH="$TMP/bin:$PATH" \
ALTITUDE_AGENT_SCRIPTS="$TMP/scripts" \
ALTITUDE_AGENT_LOG_ROOT="$TMP/logs" \
ALTITUDE_REPO_ROOT="$TMP/repo" \
ALTITUDE_WORKSHOP_ROOT="$TMP/workshop" \
  bash "$ROOT/rootfs/bin/alt-agent" env > "$TMP/env.out"
grep -q "ALTITUDE_WORKSHOP_ROOT" "$TMP/env.out"

PATH="$TMP/bin:$PATH" ALTITUDE_AGENT_SCRIPTS="$TMP/scripts" ALTITUDE_AGENT_LOG_ROOT="$TMP/logs" \
  bash "$ROOT/rootfs/bin/alt-agent" build-recipe demo > "$TMP/build.out"
grep -q "build demo" "$TMP/build.out"

PATH="$TMP/bin:$PATH" ALTITUDE_AGENT_SCRIPTS="$TMP/scripts" ALTITUDE_AGENT_LOG_ROOT="$TMP/logs" \
  bash "$ROOT/rootfs/bin/alt-agent" recipes > "$TMP/recipes.out"
grep -q '^demo$' "$TMP/recipes.out"

PATH="$TMP/bin:$PATH" ALTITUDE_AGENT_SCRIPTS="$TMP/scripts" ALTITUDE_AGENT_LOG_ROOT="$TMP/logs" \
  bash "$ROOT/rootfs/bin/alt-agent" publish-staging > "$TMP/publish.out"
grep -q publish "$TMP/publish.out"

PATH="$TMP/bin:$PATH" ALTITUDE_AGENT_LOG_ROOT="$TMP/logs" \
ALTITUDE_PKG_BIN="$TMP/bin/pkg" \
  bash "$ROOT/rootfs/bin/alt-agent" pkg-info altitude-demo > "$TMP/pkg-info.out"
grep -q "Package: altitude-demo" "$TMP/pkg-info.out"

PATH="$TMP/bin:$PATH" ALTITUDE_AGENT_LOG_ROOT="$TMP/logs" \
ALTITUDE_SYSTEMD_AUDIT_BIN="$TMP/bin/systemd-audit" \
  bash "$ROOT/rootfs/bin/alt-agent" systemd-audit > "$TMP/systemd-audit.out"
grep -q "UNIT LOAD" "$TMP/systemd-audit.out"

set +e
PATH="$TMP/bin:$PATH" ALTITUDE_AGENT_LOG_ROOT="$TMP/logs" \
ALTITUDE_PKG_BIN="$TMP/bin/pkg" \
  bash "$ROOT/rootfs/bin/alt-agent" shell >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]

echo "Altitude agent shell: ok"
