#!/usr/bin/env bash
# Push a rootfs file to the live minibash box (over SSH) and restart its service.
# minibash runs in RAM, so this hot-swaps userspace scripts with no reflash.
#
# Usage:
#   scripts/live-push.sh root@<ip> rootfs/services/desktopd.sh desktopd
#   scripts/live-push.sh root@<ip> rootfs/etc/sway/...        # no restart
#
# (minit and the kernel are NOT hot-swappable: those still need a reflash.)
set -euo pipefail

HOST="${1:?usage: live-push.sh root@<ip> <rootfs/path> [service]}"
SRC="${2:?missing source file under rootfs/}"
SVC="${3:-}"

case "$SRC" in
  rootfs/*) DEST="/${SRC#rootfs/}" ;;
  *) echo "source must be under rootfs/" >&2; exit 1 ;;
esac

# minibash regenerates its dropbear host key every boot (runs in RAM), so don't
# let known_hosts churn block the loop.
SSHOPTS="-o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

scp $SSHOPTS "$SRC" "$HOST:$DEST"
[ -n "$SVC" ] && ssh $SSHOPTS "$HOST" "bashsvc restart $SVC"
echo "pushed $SRC -> $HOST:$DEST${SVC:+  (restarted $SVC)}"
