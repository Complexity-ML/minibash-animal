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

IF="${WIFI_IF:-}"
CONF=/etc/wpa_supplicant.conf
DHCP_SCRIPT=/usr/share/udhcpc/default.script
[ -f /etc/minibash/wifi.creds ] && . /etc/minibash/wifi.creds

log() { echo "wifi: $*"; }

detect_wifi_if() {
  local dev base
  if [ -n "$IF" ] && [ -e "/sys/class/net/$IF" ]; then
    printf '%s\n' "$IF"
    return 0
  fi
  for dev in /sys/class/net/wlan* /sys/class/net/wlo* /sys/class/net/wlp* /sys/class/net/wl*; do
    [ -e "$dev" ] || continue
    base="${dev##*/}"
    [ "$base" = lo ] && continue
    printf '%s\n' "$base"
    return 0
  done
  return 1
}

ensure_ssh() {
  [ -x /services/sshd.sh ] || return 0
  pgrep -x dropbear >/dev/null 2>&1 && return 0
  log "starting sshd fallback after wifi"
  setsid /services/sshd.sh >/dev/null 2>&1 &
}

# 1. driver + opmode. Don't rely on the kernel auto-loading the opmode via
#    request_module (timing-sensitive): load both explicitly so the one matching
#    the card binds and creates wlanN deterministically.
#
KD="/lib/modules/$(uname -r)"
ins() {
  if [ -f "$KD/$1" ]; then
    local path="$1"
    shift
    insmod "$KD/$path" "$@" 2>&1 &&
      log "insmod $path $* OK" ||
      log "insmod $path $* rc=$?"
  else
    log "ABSENT $1"
  fi
}

# mac80211 advertises CCMP even when its crypto implementations are modular.
# BusyBox modules.dep.bb may still reference compressed Debian module names, so
# load the native Altitude .ko files directly. Without CCM, WPA reaches message
# 3/4 and NEW_KEY fails with ENOENT.
ins kernel/crypto/cryptd.ko
ins kernel/crypto/ghash-generic.ko
ins kernel/arch/x86/crypto/ghash-clmulni-intel.ko
ins kernel/arch/x86/crypto/aesni-intel.ko
ins kernel/crypto/cmac.ko
ins kernel/crypto/ccm.ko
ins kernel/crypto/gcm.ko

ins kernel/net/rfkill/rfkill.ko
ins kernel/net/wireless/cfg80211.ko
ins kernel/lib/crypto/libarc4.ko
ins kernel/net/mac80211/mac80211.ko
ins kernel/drivers/net/wireless/intel/iwlwifi/iwlwifi.ko \
  11n_disable=1 bt_coex_active=0 power_save=0
ins kernel/drivers/net/wireless/intel/iwlwifi/mvm/iwlmvm.ko \
  power_scheme=1
modprobe iwlmvm 2>&1 || true

# 2. clear any RF-kill soft block (a common cause of "failed to init interface")
modprobe rfkill 2>/dev/null || true
command -v rfkill >/dev/null 2>&1 && rfkill unblock all 2>/dev/null || true
for f in /sys/class/rfkill/*/soft; do [ -e "$f" ] && echo 0 > "$f" 2>/dev/null || true; done

# 3. wait for the interface to appear. udev/kernel may rename wlan0 to a
# predictable name such as wlo1 after iwlmvm binds, so discover it dynamically.
for ((i=0; i<30; i++)); do
  IF="$(detect_wifi_if || true)"
  [ -n "$IF" ] && break
  sleep 1
done
if [ -z "$IF" ] || [ ! -e "/sys/class/net/$IF" ]; then
  log "no wifi interface (iwlwifi opmode/firmware?). dmesg:"
  dmesg 2>/dev/null | grep -iE 'iwlwifi|iwlmvm|firmware' | tail -5
  while true; do log "no wifi interface; run 'wifi' on the console"; sleep 60; done
fi
log "using interface $IF"

# Make sure no competing manager fights us for the interface (NetworkManager on
# the Debian disk root, or a stray supplicant) — that causes an endless
# authenticate/deauthenticate loop.
pkill -x NetworkManager 2>/dev/null || true
pkill -x wpa_supplicant 2>/dev/null || true

ip link set "$IF" up 2>/dev/null || ifconfig "$IF" up 2>/dev/null || true
# Disable WiFi power-save: the #1 cause of iwlwifi auth/deauth flapping.
iw dev "$IF" set power_save off 2>/dev/null || true
sleep 1

# 4. associate (retry: the interface may need a moment after coming up)
if ! command -v wpa_supplicant >/dev/null 2>&1; then
  log "wpa_supplicant missing"; while true; do sleep 60; done
fi
mkdir -p /run/wpa_supplicant
if [ -n "${WIFI_BSSID:-}" ]; then
  log "pinning BSSID from private wifi.creds"
  CONF=/run/wpa_supplicant-altitude.conf
  awk -v bssid="$WIFI_BSSID" '
    BEGIN { innet=0; added=0 }
    /^[[:space:]]*network=\{/ { innet=1; added=0; print; next }
    innet && /^[[:space:]]*ssid=/ {
      print
      print "    bssid=" bssid
      print "    proto=RSN"
      print "    pairwise=CCMP"
      print "    group=CCMP"
      print "    ieee80211w=0"
      added=1
      next
    }
    innet && /^[[:space:]]*(proto|pairwise|group|ieee80211w)=/ { if (!added) print; next }
    innet && /^[[:space:]]*bssid=/ { if (!added) print; next }
    innet && /^\}/ { innet=0; print; next }
    { print }
  ' /etc/wpa_supplicant.conf >"$CONF"
  chmod 600 "$CONF"
fi
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
  [ -n "$addr" ] && ensure_ssh
  sleep 30
done
