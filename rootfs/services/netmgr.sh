#!/usr/bin/env bash
# NetworkManager service for minibash-native.
#
# We still apply a wired static fallback before NM starts so the Omen stays
# reachable over SSH even when DHCP/carrier are flaky. GNOME then talks to the
# real org.freedesktop.NetworkManager service for WiFi.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export BDB_PATH="${BDB_PATH:-/var/bdb}"
exec >>/var/log/netmgr.log 2>&1
NM_PID=""

cleanup() {
  [ -n "$NM_PID" ] && kill "$NM_PID" 2>/dev/null || true
  wait "$NM_PID" 2>/dev/null || true
}
trap cleanup TERM INT EXIT

log() { echo "netmgr: $* ($(date 2>/dev/null))"; }

WIRED_IP="192.168.1.25/24"
WIRED_GW="192.168.1.1"
WIRED_DNS="192.168.1.1"
[ -f /etc/minibash/wifi.creds ] && . /etc/minibash/wifi.creds

DHS=/usr/share/udhcpc/default.script
mkdir -p /usr/share/udhcpc /run/dbus /run/NetworkManager /var/lib/NetworkManager \
  /etc/NetworkManager/conf.d /run/udev /run/udev/data
cat > "$DHS" <<'EOF'
#!/bin/sh
case "$1" in
  bound|renew)
    ifconfig "$interface" "$ip" netmask "${subnet:-255.255.255.0}"
    [ -n "$router" ] && { route del default 2>/dev/null; route add default gw "$router"; }
    : > /etc/resolv.conf
    for d in $dns; do echo "nameserver $d" >> /etc/resolv.conf; done ;;
esac
EOF
chmod +x "$DHS"

cat > /etc/NetworkManager/NetworkManager.conf <<'EOF'
[main]
plugins=keyfile

[ifupdown]
managed=true

[keyfile]
unmanaged-devices=none

[device]
wifi.backend=iwd
match-device=*
managed=1
EOF
cat > /etc/NetworkManager/conf.d/10-minibash.conf <<'EOF'
[main]
plugins=keyfile

[ifupdown]
managed=true

[keyfile]
unmanaged-devices=none

[device-all]
wifi.backend=iwd
match-device=*
managed=1

[device-wifi]
match-device=type:wifi
managed=1

[device-ethernet]
match-device=type:ethernet
managed=1
EOF

# Kernel modules are driven by the bdb `modules` table: kmod reconciles it
# (modprobe + writes loaded/failed status back). This is the DB-driven kernel.
# CRITICAL: it loads `ccm`+aes BEFORE the WiFi -- mac80211 needs CCM(AES) to
# install the WPA CCMP key; a missing `ccm` is THE multi-day "WRONG_KEY" bug,
# now visible as modules.status=failed instead of invisible.
if [ -x /services/kmod.sh ]; then
  /services/kmod.sh || true
else
  # fallback if the modules table isn't seeded yet
  for m in ccm ctr gcm aes_generic aesni_intel cmac evdev mousedev \
           cfg80211 mac80211 rfkill iwlwifi iwlmvm rtl8xxxu r8169 r8125 e1000e igb; do
    modprobe "$m" 2>/dev/null || true
  done
fi
rfkill unblock all 2>/dev/null || true
if command -v iw >/dev/null 2>&1 && ! iw dev "${WIFI_IFACE:-wlan0}" info >/dev/null 2>&1; then
  iw phy phy0 interface add "${WIFI_IFACE:-wlan0}" type managed 2>/dev/null || true
fi

if command -v udevadm >/dev/null 2>&1; then
  if ! pgrep -x systemd-udevd >/dev/null 2>&1 && ! pgrep -x udevd >/dev/null 2>&1; then
    /lib/systemd/systemd-udevd --daemon 2>/dev/null || /usr/lib/systemd/systemd-udevd --daemon 2>/dev/null || true
  fi
  udevadm trigger --action=add >/dev/null 2>&1 || true
  udevadm settle --timeout=8 >/dev/null 2>&1 || true
fi

if [ -n "${WIFI_SSID:-}" ] && [ -n "${WIFI_PSK:-}" ]; then
  mkdir -p /etc/NetworkManager/system-connections
  nm_conn="/etc/NetworkManager/system-connections/${WIFI_SSID}.nmconnection"
  {
    cat <<EOF
[connection]
id=${WIFI_SSID}
type=wifi
interface-name=${WIFI_IFACE:-wlan0}
autoconnect=true
autoconnect-priority=100

[wifi]
mode=infrastructure
ssid=${WIFI_SSID}
mac-address-randomization=1
EOF
    [ -n "${WIFI_BSSID:-}" ] && echo "bssid=${WIFI_BSSID}"
    [ -n "${WIFI_BAND:-}" ] && echo "band=${WIFI_BAND}"
    [ -n "${WIFI_CHANNEL:-}" ] && echo "channel=${WIFI_CHANNEL}"
    cat <<EOF

[wifi-security]
key-mgmt=wpa-psk
proto=rsn
pairwise=ccmp
group=ccmp
pmf=1
psk=${WIFI_PSK}

[ipv4]
method=auto

[ipv6]
method=ignore
EOF
  } > "$nm_conn"
  chmod 600 "$nm_conn"
fi

detect_eth() {
  local d n
  for d in /sys/class/net/*; do
    n=${d##*/}
    case "$n" in lo|wl*) continue ;; esac
    [ -e "$d/device" ] && { echo "$n"; return; }
  done
}

set_static() {
  ip addr add "$WIRED_IP" dev "$1" 2>/dev/null || true
  [ -n "$WIRED_GW" ] && { ip route del default 2>/dev/null || true; ip route add default via "$WIRED_GW" 2>/dev/null || true; }
  [ -n "$WIRED_DNS" ] && echo "nameserver $WIRED_DNS" > /etc/resolv.conf
}

ETH="$(detect_eth || true)"
if [ -n "$ETH" ]; then
  ip link set "$ETH" up 2>/dev/null || true
  sleep 2  # let the link negotiate before reading carrier
  if [ "$(cat /sys/class/net/$ETH/carrier 2>/dev/null)" = "1" ]; then
    # cable plugged -> DHCP, then static fallback
    if ! ip -4 addr show "$ETH" 2>/dev/null | grep -q 'inet '; then
      busybox udhcpc -i "$ETH" -s "$DHS" -t 3 -T 2 -n -q >/dev/null 2>&1 || true
    fi
    if ! ip -4 addr show "$ETH" 2>/dev/null | grep -q 'inet '; then
      log "static $WIRED_IP on $ETH"
      set_static "$ETH"
    fi
  else
    # NO cable (carrier=0): NEVER put an IP or default route on a dead link.
    # Otherwise replies to the WiFi traffic egress via the dead eth0 and the box
    # is unreachable (SSH times out) even though WiFi is connected. Flush any
    # stale addr/route and let WiFi own the default route. THIS was the "ssh
    # impossible en wifi" bug.
    log "$ETH carrier=0 (pas de cable) -> ignore, le wifi gere le reseau"
    ip addr flush dev "$ETH" 2>/dev/null || true
    ip route del default dev "$ETH" 2>/dev/null || true
  fi
fi

[ -S /run/dbus/system_bus_socket ] || dbus-daemon --system --fork 2>/dev/null || true
if [ -x /usr/libexec/iwd ]; then
  killall wpa_supplicant 2>/dev/null || true
  mkdir -p /var/lib/iwd
  if [ -n "${WIFI_SSID:-}" ] && [ -n "${WIFI_PSK:-}" ]; then
    cat > "/var/lib/iwd/${WIFI_SSID}.psk" <<EOF
[Security]
Passphrase=${WIFI_PSK}

[Settings]
AutoConnect=false
EOF
    chmod 600 "/var/lib/iwd/${WIFI_SSID}.psk"
  fi
  pgrep -x iwd >/dev/null 2>&1 || /usr/libexec/iwd >/var/log/iwd.log 2>&1 &
  for _ in 1 2 3 4 5; do
    busctl --system --no-pager list 2>/dev/null | awk '{print $1}' | grep -qx net.connman.iwd && break
    sleep 1
  done
  iwctl device "${WIFI_IFACE:-wlan0}" set-property Powered on >/dev/null 2>&1 || true
fi

log "starting NetworkManager"
killall NetworkManager 2>/dev/null || true
sleep 1
NetworkManager --no-daemon --log-level=INFO &
NM_PID=$!

# Live carrier failover. Keep exactly one uplink active:
#   carrier=1 -> Ethernet owns the route, WiFi is disconnected
#   carrier=0 -> Ethernet is flushed, WiFi is powered and connected
if [ -n "$ETH" ]; then
  (
    last=""
    while kill -0 "$NM_PID" 2>/dev/null; do
      carrier="$(cat "/sys/class/net/$ETH/carrier" 2>/dev/null || echo 0)"
      if [ "$carrier" != "$last" ]; then
        if [ "$carrier" = 1 ]; then
          log "$ETH carrier=1 -> Ethernet primary"
        else
          log "$ETH carrier=0 -> switching to WiFi"
        fi
        last="$carrier"
      fi

      if [ "$carrier" = 1 ]; then
        if [ "$(nmcli -g GENERAL.STATE device show "$ETH" 2>/dev/null)" != "100 (connected)" ]; then
          ip link set "$ETH" up 2>/dev/null || true
          nmcli device connect "$ETH" >/dev/null 2>&1 || true
        fi
        if [ "$(nmcli -g GENERAL.STATE device show "${WIFI_IFACE:-wlan0}" 2>/dev/null)" = "100 (connected)" ]; then
          nmcli device disconnect "${WIFI_IFACE:-wlan0}" >/dev/null 2>&1 || true
        fi
      else
        if ip -4 addr show "$ETH" 2>/dev/null | grep -q 'inet '; then
          nmcli device disconnect "$ETH" >/dev/null 2>&1 || true
          ip addr flush dev "$ETH" 2>/dev/null || true
          ip route del default dev "$ETH" 2>/dev/null || true
        fi
        wifi_state="$(nmcli -g GENERAL.STATE device show "${WIFI_IFACE:-wlan0}" 2>/dev/null || true)"
        if [ "$wifi_state" != "100 (connected)" ]; then
          rfkill unblock wifi 2>/dev/null || true
          iwctl device "${WIFI_IFACE:-wlan0}" set-property Powered on >/dev/null 2>&1 || true
          nmcli radio wifi on >/dev/null 2>&1 || true
          nmcli device set "${WIFI_IFACE:-wlan0}" managed yes >/dev/null 2>&1 || true
          [ -n "${WIFI_SSID:-}" ] && nmcli connection up "$WIFI_SSID" >/dev/null 2>&1 || true
        fi
      fi
      sleep 2
    done
  ) &
fi

wait "$NM_PID"
