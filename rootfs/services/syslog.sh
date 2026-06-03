#!/usr/bin/env bash
# BusyBox syslog collector. Runs in foreground so minit can supervise it.
set -u

mkdir -p /var/log
echo "syslog: collector online -> /var/log/messages"
exec busybox syslogd -n -O /var/log/messages
