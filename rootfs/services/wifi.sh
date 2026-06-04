#!/usr/bin/env bash
# Bring up Intel WiFi (iwlwifi) and join the configured network, then DHCP.
# Verbose on purpose: a failed boot can be read from the console (`wifi`) or,
# once online, live over SSH.
set -u
export PATH=/bin:/usr/bin:/sbin:/usr/sbin

# Capture everything this service does (and a command trace) so a failed boot is
# fully diagnosable from /var/log/wifi.log.
exec >>/var/log/wifi.log 2>&1
set -x

IF="${WIFI_IF:-wlan0}"
CONF=/etc/wpa_supplicant.conf
DHCP_SCRIPT=/usr/share/udhcpc/default.script

log() { echo "wifi: $*"; }

# 1. driver + opmode. Don't rely on the kernel auto-loading the opmode via
#    request_module (timing-sensitive): load both explicitly so the one matching
#    the card binds and creates wlanN deterministically.
modprobe iwlwifi 2>/dev/null || true
modprobe iwlmvm  2>/dev/null || true
modprobe iwldvm  2>/dev/null || true

# 2. clear any RF-kill soft block (a common cause of "failed to init interface")
modprobe rfkill 2>/dev/null || true
command -v rfkill >/dev/null 2>&1 && rfkill unblock all 2>/dev/null || true
for f in /sys/class/rfkill/*/soft; do [ -e "$f" ] && echo 0 > "$f" 2>/dev/null || true; done

# 3. wait for the interface to appear
for ((i=0; i<30; i++)); do
  [ -e "/sys/class/net/$IF" ] && break
  sleep 1
done
if [ ! -e "/sys/class/net/$IF" ]; then
  log "no $IF interface (iwlwifi opmode/firmware?). dmesg:"
  dmesg 2>/dev/null | grep -iE 'iwlwifi|iwlmvm|firmware' | tail -5
  while true; do log "no $IF; run 'wifi' on the console"; sleep 60; done
fi

ip link set "$IF" up 2>/dev/null || ifconfig "$IF" up 2>/dev/null || true
sleep 1

# 4. associate (retry: the interface may need a moment after coming up)
if ! command -v wpa_supplicant >/dev/null 2>&1; then
  log "wpa_supplicant missing"; while true; do sleep 60; done
fi
mkdir -p /run/wpa_supplicant
# Run wpa_supplicant in the foreground but backgrounded with '&' (NOT -B): that
# way ALL of its output — driver init errors AND association events — is captured
# in the log instead of being lost to syslog when it daemonises.
log "starting wpa_supplicant on $IF (foreground, logged)"
wpa_supplicant -i "$IF" -c "$CONF" -Dnl80211 -d -t >/var/log/wpa_supplicant.log 2>&1 &
WPA_PID=$!
sleep 6
if ! kill -0 "$WPA_PID" 2>/dev/null; then
  log "wpa_supplicant exited early; log:"
  tail -8 /var/log/wpa_supplicant.log 2>/dev/null
fi

# 5. DHCP (busybox udhcpc backgrounds itself and keeps retrying until associated)
log "requesting DHCP lease on $IF"
busybox udhcpc -i "$IF" -s "$DHCP_SCRIPT" -t 10 -A 5 -b >/var/log/udhcpc.log 2>&1 &

# 6. status reporter
while true; do
  addr="$(busybox ip -4 addr show "$IF" 2>/dev/null | awk '/inet /{print $2; exit}')"
  log "$IF=${addr:-none}"
  sleep 30
done
