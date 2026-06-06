#!/usr/bin/env bash
# reconciled -- the LIVE control loop of the bdb "tour de controle".
#
# Watches domain tables, advances desired/observed generations, journals every
# transition and retries failed reconciliations with bounded exponential
# backoff. This is the durable control plane behind the live Linux state.
set -u
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export BDB_PATH="${BDB_PATH:-/var/bdb}"
BDB=/bin/bdb
exec >>/var/log/reconciled.log 2>&1
log() { echo "reconciled: $* ($(date 2>/dev/null))"; }

# table -> reconciler
reconciler_for() {
  case "$1" in
    modules) echo /services/kmod.sh ;;
    mounts)  echo /services/mountd.sh ;;
    sysctl)  echo /services/sysctld.sh ;;
    *)       echo "" ;;
  esac
}
TABLES="modules mounts sysctl"

sig() {
  file="$BDB_PATH/tables/$1/data.bdb"
  [ -f "$file" ] || { echo missing; return; }
  cksum "$file" 2>/dev/null | awk '{print $1 ":" $2}'
}

control_field() {
  domain="$1"; column="$2"
  case "$column" in
    desired_generation) index=2 ;;
    observed_generation) index=3 ;;
    status) index=4 ;;
    retry_count) index=5 ;;
    next_retry) index=6 ;;
    last_error) index=7 ;;
    last_signature) index=8 ;;
    updated_at) index=9 ;;
    *) return 1 ;;
  esac
  $BDB dump control_state 2>/dev/null |
    awk -F '\t' -v d="$domain" -v i="$index" 'NR > 1 && $1 == d { print $i; exit }'
}

clean_message() {
  printf '%s' "$*" | tr '\t\r\n' '   ' | cut -c1-240
}

event() {
  domain="$1"; generation="$2"; action="$3"; result="$4"; shift 4
  now=$(date +%s)
  seq_file="$state/event-seq"
  seq=$(cat "$seq_file" 2>/dev/null || echo 0)
  seq=$((seq + 1))
  echo "$seq" > "$seq_file"
  id="$now-$$-$seq"
  message=$(clean_message "$*")
  $BDB insert events id="$id" timestamp="$now" domain="$domain" \
    generation="$generation" action="$action" result="$result" \
    message="$message" >/dev/null 2>&1 ||
    log "could not append event '$id'"
}

domain_error() {
  table="$1"
  case "$table" in
    modules)
      $BDB dump modules 2>/dev/null |
        awk -F '\t' 'NR > 1 && ($4 == "true" || $4 == "1") && $5 == "failed" {
          print "module " $1 " failed"; exit
        }'
      ;;
    mounts)
      $BDB dump mounts 2>/dev/null |
        awk -F '\t' 'NR > 1 && $5 == "mounted" && $6 == "error" {
          print "mount " $1 " failed"; exit
        }'
      ;;
    sysctl)
      $BDB dump sysctl 2>/dev/null |
        awk -F '\t' 'NR > 1 && $3 == "failed" {
          print "sysctl " $1 "=" $2 " failed"; exit
        }'
      ;;
  esac
}

mark_changed() {
  table="$1"; signature="$2"; now=$(date +%s)
  generation=$(control_field "$table" desired_generation)
  generation=$((${generation:-0} + 1))
  $BDB update control_state --where "domain=$table" \
    desired_generation="$generation" status=pending retry_count=0 \
    next_retry=0 last_error="" last_signature="$signature" \
    updated_at="$now" >/dev/null
  event "$table" "$generation" change detected "signature $signature"
  log "table '$table' desired generation -> $generation"
}

reconcile_table() {
  table="$1"
  rec="$(reconciler_for "$table")"
  generation=$(control_field "$table" desired_generation)
  generation=${generation:-0}
  [ -n "$rec" ] && [ -x "$rec" ] || {
    finish_failure "$table" "$generation" "no reconciler for table"
    return 1
  }
  log "reconcile '$table' generation $generation -> $rec"
  event "$table" "$generation" reconcile started "$rec"
  if ! "$rec" >/dev/null 2>&1; then
    finish_failure "$table" "$generation" "reconciler exited non-zero"
    return 1
  fi
  error=$(domain_error "$table")
  if [ -n "$error" ]; then
    finish_failure "$table" "$generation" "$error"
    return 1
  fi
  now=$(date +%s)
  signature=$(sig "$table")
  $BDB update control_state --where "domain=$table" \
    observed_generation="$generation" status=applied retry_count=0 \
    next_retry=0 last_error="" last_signature="$signature" \
    updated_at="$now" >/dev/null
  event "$table" "$generation" reconcile succeeded "generation applied"
  echo "$signature" > "$state/$table"
  return 0
}

finish_failure() {
  table="$1"; generation="$2"; message=$(clean_message "$3")
  retries=$(control_field "$table" retry_count)
  retries=$((${retries:-0} + 1))
  exponent=$retries
  [ "$exponent" -gt 8 ] && exponent=8
  delay=$((1 << exponent))
  [ "$delay" -gt 300 ] && delay=300
  now=$(date +%s)
  next=$((now + delay))
  signature=$(sig "$table")
  $BDB update control_state --where "domain=$table" status=failed \
    retry_count="$retries" next_retry="$next" last_error="$message" \
    last_signature="$signature" updated_at="$now" >/dev/null
  echo "$signature" > "$state/$table"
  event "$table" "$generation" reconcile failed "$message; retry in ${delay}s"
  log "'$table' generation $generation failed: $message (retry ${delay}s)"
}

state=/run/reconciled
mkdir -p "$state"
[ -x /etc/minibash/bdb/seed.sh ] &&
  /etc/minibash/bdb/seed.sh >/dev/null 2>&1

# A restart does not invent a generation when desired data is unchanged.
for t in $TABLES; do
  cur=$(sig "$t")
  known=$(control_field "$t" last_signature)
  if [ "$cur" != "$known" ]; then
    mark_changed "$t" "$cur"
  fi
  status=$(control_field "$t" status)
  if [ "$status" != applied ]; then
    reconcile_table "$t" || true
  else
    echo "$cur" > "$state/$t"
  fi
done
log "control loop up (watch: $TABLES)"

while true; do
  now=$(date +%s)
  for t in $TABLES; do
    cur=$(sig "$t")
    known=$(control_field "$t" last_signature)
    status=$(control_field "$t" status)
    next_retry=$(control_field "$t" next_retry)
    if [ "$cur" != "$known" ]; then
      mark_changed "$t" "$cur"
      reconcile_table "$t" || true
    elif [ "$status" = failed ] && [ "${next_retry:-0}" -le "$now" ]; then
      reconcile_table "$t" || true
    fi
  done
  sleep 2
done
