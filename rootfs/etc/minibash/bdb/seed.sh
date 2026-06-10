#!/usr/bin/env bash
# First-boot seed for the NATIVE C bdb engine (bdbc, binary BDB1 format).
#
# The old base64-TSV table seeds were the BASH bootstrap; now that the engine is
# the C `bdbc`, the schema + rows are (re)built declaratively here, via `bdb`
# itself, into the native binary format. Idempotent: a table is only created if
# missing, so this is safe to run on every boot.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export BDB_PATH="${BDB_PATH:-/var/bdb}"
BDB=/bin/bdb

have_table() { $BDB tables 2>/dev/null | grep -qx "$1"; }

# --- modules: KERNEL MODULES, driven by the DB -----------------------------
# This is the "kernel services via the database" piece. `ccm` + aes were THE
# missing modules that broke WiFi for days (mac80211 could not install the WPA
# CCMP key). They now live in the database, not a hardcoded modprobe list, so
# the failure is visible (status=failed) and the set is editable with `bdb`.
if ! have_table modules; then
  $BDB create modules name:text:pk params:text stage:text autoload:bool \
    status:text description:text >/dev/null
  add() { $BDB insert modules name="$1" params="$2" stage="$3" autoload=true \
            status=unloaded description="$4" >/dev/null; }
  # crypto -- mandatory for the WPA CCMP/PMF key install (THE multi-day bug)
  add ccm         "" crypto "CCM(AES) - cle CCMP WPA (sans lui: handshake KO)"
  add aesni_intel "" crypto "AES accelere Intel"
  add ctr         "" crypto "CTR"
  add gcm         "" crypto "GCM"
  add cmac        "" crypto "CMAC - PMF/BIP (WPA3)"
  # 802.11 stack + drivers
  add cfg80211 "" net "Pile 802.11 (cfg80211)"
  add mac80211 "" net "MAC 802.11"
  add rfkill   "" net "RF kill"
  add iwlwifi  "" net "Intel WiFi"
  add iwlmvm   "" net "Intel WiFi opmode (MVM)"
  add rtl8xxxu "" net "Realtek USB WiFi (TP-Link)"
  add r8169    "" net "Realtek Ethernet"
fi

# Migrations for existing databases: iwd uses the kernel AF_ALG API, so these
# modules must be added even when the modules table predates iwd support.
ensure_module() {
  name="$1"; params="$2"; stage="$3"; description="$4"
  $BDB dump modules 2>/dev/null | cut -f1 | grep -qx "$name" && return 0
  $BDB insert modules name="$name" params="$params" stage="$stage" autoload=true \
    status=unloaded description="$description" >/dev/null
}
ensure_module crypto_user    "" crypto "AF_ALG userspace crypto"
ensure_module algif_hash     "" crypto "AF_ALG hash interface"
ensure_module algif_skcipher "" crypto "AF_ALG symmetric cipher interface"
ensure_module ecb            "" crypto "ECB cipher mode"
ensure_module cbc            "" crypto "CBC cipher mode"
ensure_module md5            "" crypto "MD5 for iwd compatibility"
ensure_module des_generic    "" crypto "DES compatibility"
ensure_module hmac           "" crypto "HMAC for WPA authentication"

# aes_generic disappeared as a loadable module on modern kernels; AES is
# provided by aesni_intel/aes-lib. Disable the legacy row on upgraded systems.
if $BDB dump modules 2>/dev/null | cut -f1 | grep -qx aes_generic; then
  $BDB update modules --where name=aes_generic autoload=false status=obsolete \
    description="legacy AES module; replaced by aesni_intel/aes-lib" >/dev/null
fi

# --- mounts: /etc/fstab as ROWS, driven by the DB (reconciled by mountd) ----
if ! have_table mounts; then
  $BDB create mounts dst:text:pk src:text fstype:text opts:text desired:text \
    status:text >/dev/null
  # demo: a tmpfs that exists purely because a DB row says so. Flip desired to
  # unmounted and mountd umounts it -- the filesystem follows the database.
  $BDB insert mounts dst=/mnt/data src=tmpfs fstype=tmpfs opts=size=64m \
    desired=mounted status=unmounted >/dev/null
fi

# --- sysctl: /etc/sysctl.conf as ROWS, applied by sysctld -------------------
if ! have_table sysctl; then
  $BDB create sysctl key:text:pk value:text status:text description:text >/dev/null
  s() { $BDB insert sysctl key="$1" value="$2" status=unset description="$3" >/dev/null; }
  s net.ipv4.ip_forward       0        "routage IPv4 (1 pour faire routeur)"
  s vm.swappiness             10       "agressivite du swap (0-100)"
  s kernel.sysrq              1        "magic SysRq"
  s net.ipv4.tcp_syncookies   1        "protection SYN flood"
  s fs.file-max               262144   "nb max de descripteurs de fichiers"
fi

# --- control plane: generations, health and append-only event journal -------
if ! have_table control_state; then
  $BDB create control_state domain:text:pk desired_generation:int \
    observed_generation:int status:text retry_count:int next_retry:int \
    last_error:text last_signature:text updated_at:int >/dev/null
fi

ensure_control_domain() {
  domain="$1"
  $BDB dump control_state 2>/dev/null | cut -f1 | grep -qx "$domain" && return 0
  $BDB insert control_state domain="$domain" desired_generation=0 \
    observed_generation=0 status=new retry_count=0 next_retry=0 \
    last_error="" last_signature="" updated_at=0 >/dev/null
}
ensure_control_domain modules
ensure_control_domain mounts
ensure_control_domain sysctl
ensure_control_domain app_registry

if ! have_table events; then
  $BDB create events id:text:pk timestamp:int domain:text generation:int \
    action:text result:text message:text >/dev/null
fi

# --- app registry: indexed native Linux applications -----------------------
if ! have_table app_registry; then
  $BDB create app_registry id:text:pk name:text exec:text desktop:text \
    categories:text package:text installed:bool visible:bool description:text \
    >/dev/null
fi

# --- systemd audit: observed state only, never service control --------------
if ! have_table systemd_audit; then
  $BDB create systemd_audit unit:text:pk load:text active:text sub:text \
    description:text updated_at:int >/dev/null
fi

# --- registry: typed hierarchical system/application configuration ----------
if ! have_table registry; then
  $BDB create registry path:text:pk type:text value:text owner:text \
    updated_at:int >/dev/null
  now=$(date +%s 2>/dev/null || echo 0)
  $BDB insert registry path=/system/locale/keymap type=string value=fr \
    owner=system updated_at="$now" >/dev/null
  $BDB insert registry path=/system/desktop/enabled type=bool value=true \
    owner=system updated_at="$now" >/dev/null
  $BDB insert registry path=/system/network/failover type=string \
    value=carrier owner=netmgr updated_at="$now" >/dev/null
fi

ensure_registry() {
  path="$1"; type="$2"; value="$3"; owner="$4"
  $BDB dump registry 2>/dev/null | cut -f1 | grep -qx "$path" && return 0
  now=$(date +%s 2>/dev/null || echo 0)
  $BDB insert registry path="$path" type="$type" value="$value" \
    owner="$owner" updated_at="$now" >/dev/null
}
ensure_registry /system/product/name string "Altitude Linux" system
ensure_registry /system/product/id string altitude system
ensure_registry /system/product/version string 0.1.0 system
ensure_registry /system/product/codename string basecamp system
ensure_registry /system/product/base string altitude system
ensure_registry /system/package/manager string altpkg system
ensure_registry /system/package/registry string altitude-main system
ensure_registry /system/package/registry/enabled bool true system
ensure_registry /system/package/registry/url string file:///var/lib/altitude/repository system
ensure_registry /system/apps/registry string app_registry system
ensure_registry /system/apps/source string desktop-files system
ensure_registry /system/apps/autorefresh bool true system
ensure_registry /system/systemd/audit/enabled bool true system
ensure_registry /system/systemd/audit/table string systemd_audit system
ensure_registry /system/systemd/audit/control bool false system
ensure_registry /system/systemd/runtime/present bool true system
ensure_registry /system/systemd/runtime/pid1 bool true system
ensure_registry /system/init/provider string systemd system
ensure_registry /system/init/systemd/required bool true system
ensure_registry /system/registry/audit/enabled bool true system
ensure_registry /system/registry/audit/owner string registry-audit system
