#!/usr/bin/env bash
# A real (tiny) HTTP server in Bash. One connection per accept via busybox nc;
# the outer loop re-arms the listener. Serves live service status from bdb.
set -u

PORT="${WEB_PORT:-80}"
BDB_PATH="${BDB_PATH:-/var/bdb}"
export BDB_PATH

echo "web: http status server starting on 0.0.0.0:${PORT}"

build_body() {
  echo "minibash-linux :: service status"
  echo
  /bin/bdb select services
  echo
  local up="0" host="minibash"
  if read -r up _ < /proc/uptime 2>/dev/null; then up="${up%.*}"; fi
  if [ -r /proc/sys/kernel/hostname ]; then read -r host < /proc/sys/kernel/hostname; fi
  echo "host: ${host}   uptime: ${up}s"
}

respond() {
  local body
  body="$(build_body)"
  printf 'HTTP/1.0 200 OK\r\n'
  printf 'Content-Type: text/plain; charset=utf-8\r\n'
  printf 'Connection: close\r\n'
  printf 'Content-Length: %s\r\n' "${#body}"
  printf '\r\n'
  printf '%s' "$body"
}

while true; do
  # busybox nc: serve one client then exit; the loop re-arms the listener.
  if ! respond | busybox nc -l -p "$PORT" >/dev/null 2>&1; then
    echo "web: listener on :${PORT} failed (no nc/port busy?), retrying"
    sleep 2
  fi
done
