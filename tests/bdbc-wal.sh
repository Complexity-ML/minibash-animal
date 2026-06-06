#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cc -std=c11 -O2 -Wall -Wextra -Werror \
  -o "$TMP/bdbc" "$ROOT/rootfs/usr/src/minibash/bdbc.c"

export BDB_PATH="$TMP/db"
"$TMP/bdbc" init
"$TMP/bdbc" create items id:text:pk value:int
"$TMP/bdbc" insert items id=one value=1
"$TMP/bdbc" check

set +e
BDB_TEST_CRASH_AFTER_WAL=1 "$TMP/bdbc" update items \
  --where id=one value=2 >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 99 ] || {
  echo "expected injected crash 99, got $status" >&2
  exit 1
}
[ -f "$BDB_PATH/WAL" ]
[ -d "$BDB_PATH/.lock" ]

# Any following command must remove the dead lock and replay the committed WAL.
value=$("$TMP/bdbc" select items --where id=one | tail -n 1 | cut -f2)
[ "$value" = 2 ]
[ ! -e "$BDB_PATH/WAL" ]
[ ! -e "$BDB_PATH/.lock" ]

set +e
"$TMP/bdbc" insert items id=one value=3 >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]

"$TMP/bdbc" check items

set +e
"$TMP/bdbc" update items --where id=one id=duplicate >/dev/null 2>&1
"$TMP/bdbc" insert items id=duplicate value=3 >/dev/null 2>&1
status=$?
set -e
[ "$status" -ne 0 ]

# Multi-table commit: both replacements become visible after one WAL recovery.
"$TMP/bdbc" create lefts id:text:pk value:int
"$TMP/bdbc" create rights id:text:pk value:int
"$TMP/bdbc" insert lefts id=l value=1
"$TMP/bdbc" insert rights id=r value=1
mkdir "$TMP/stage"
export STAGE_BDB="$TMP/stage"
BDB_PATH="$STAGE_BDB" "$TMP/bdbc" init
BDB_PATH="$STAGE_BDB" "$TMP/bdbc" create lefts id:text:pk value:int
BDB_PATH="$STAGE_BDB" "$TMP/bdbc" create rights id:text:pk value:int
BDB_PATH="$STAGE_BDB" "$TMP/bdbc" insert lefts id=l value=2
BDB_PATH="$STAGE_BDB" "$TMP/bdbc" insert rights id=r value=2

set +e
BDB_TEST_CRASH_AFTER_WAL=1 "$TMP/bdbc" transact \
  "lefts=$STAGE_BDB/tables/lefts/data.bdb" \
  "rights=$STAGE_BDB/tables/rights/data.bdb" >/dev/null 2>&1
status=$?
set -e
[ "$status" -eq 99 ]
[ -f "$BDB_PATH/WAL" ]
left=$("$TMP/bdbc" select lefts --where id=l | tail -n 1 | cut -f2)
right=$("$TMP/bdbc" select rights --where id=r | tail -n 1 | cut -f2)
[ "$left" = 2 ] && [ "$right" = 2 ]

echo "bdbc WAL recovery: ok"
