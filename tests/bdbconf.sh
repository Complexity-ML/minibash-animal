#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cc -std=c11 -O2 -Wall -Wextra -Werror \
  -o "$TMP/bdbc" "$ROOT/rootfs/usr/src/minibash/bdbc.c"

export BDB_PATH="$TMP/live"
export BDB_BIN="$TMP/bdbc"
"$BDB_BIN" init >/dev/null
"$BDB_BIN" create services name:text:pk command:text autostart:bool \
  restart:bool desired:text status:text pid:int description:text >/dev/null
for service in dbus graphical displayd; do
  "$BDB_BIN" insert services name="$service" command="/services/$service.sh" \
    autostart=true restart=true desired=up status=stopped pid=0 \
    description="$service" >/dev/null
done
"$BDB_BIN" create registry path:text:pk type:text value:text owner:text \
  updated_at:int >/dev/null
"$BDB_BIN" create service_dependencies id:text:pk service:text \
  relation:text target:text >/dev/null
"$BDB_BIN" insert registry path=/system/desktop/enabled type=bool value=true \
  owner=system updated_at=0 >/dev/null
"$BDB_BIN" insert service_dependencies id=graphical:requires:dbus \
  service=graphical relation=requires target=dbus >/dev/null

bash "$ROOT/rootfs/bin/bdbconf" export "$TMP/current.conf" >/dev/null
bash "$ROOT/rootfs/bin/bdbconf" check "$TMP/current.conf" >/dev/null
bash "$ROOT/rootfs/bin/bdbconf" diff "$TMP/current.conf" >/dev/null

cat > "$TMP/wanted.conf" <<'EOF'
bdbconf 1

# Typed registry
registry /apps/demo/title string demo Minibash control center
registry /system/desktop/enabled bool system false

# Service graph
dependency displayd after graphical
dependency graphical requires dbus
EOF

bash "$ROOT/rootfs/bin/bdbconf" check "$TMP/wanted.conf" >/dev/null
set +e
bash "$ROOT/rootfs/bin/bdbconf" diff "$TMP/wanted.conf" >/dev/null
status=$?
set -e
[ "$status" -eq 1 ]
bash "$ROOT/rootfs/bin/bdbconf" apply "$TMP/wanted.conf" >/dev/null
bash "$ROOT/rootfs/bin/bdbconf" diff "$TMP/wanted.conf" >/dev/null

title=$("$BDB_BIN" select registry --where path=/apps/demo/title |
  tail -n 1 | cut -f3)
[ "$title" = "Minibash control center" ]
"$BDB_BIN" select service_dependencies \
  --where id=displayd:after:graphical | tail -n +2 | grep -q .

cp "$TMP/wanted.conf" "$TMP/invalid.conf"
echo "dependency missing requires dbus" >> "$TMP/invalid.conf"
before=$(cksum "$BDB_PATH/tables/registry/data.bdb")
set +e
bash "$ROOT/rootfs/bin/bdbconf" apply "$TMP/invalid.conf" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]
after=$(cksum "$BDB_PATH/tables/registry/data.bdb")
[ "$before" = "$after" ]

cat > "$TMP/cycle.conf" <<'EOF'
bdbconf 1
dependency graphical after displayd
dependency displayd after graphical
EOF
set +e
bash "$ROOT/rootfs/bin/bdbconf" check "$TMP/cycle.conf" >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]

echo "bdbconf round-trip and atomic validation: ok"
