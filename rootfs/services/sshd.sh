#!/usr/bin/env bash
set -u

PORT="${SSHD_PORT:-22}"
mkdir -p /etc/dropbear

if ! command -v dropbear >/dev/null 2>&1; then
  echo "sshd: dropbear binary missing; install dropbear-bin in builder"
  sleep 3600
  exit 0
fi

if [ ! -s /etc/dropbear/dropbear_ed25519_host_key ]; then
  if command -v dropbearkey >/dev/null 2>&1; then
    echo "sshd: generating ed25519 host key"
    dropbearkey -t ed25519 -f /etc/dropbear/dropbear_ed25519_host_key >/dev/null 2>&1 || true
  fi
fi

echo "sshd: dropbear listening on 0.0.0.0:${PORT}"
exec dropbear -F -E -p "$PORT"
