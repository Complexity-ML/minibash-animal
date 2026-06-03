#!/usr/bin/env bash
set -euo pipefail

VERSION="0.1.0"
DB_DIR="${BDB_PATH:-.bdb}"
LOCK_DIR=""

die() {
  printf 'bdb: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
bdb - une mini base de donnees relationnelle en Bash

Usage:
  bdb init [path]
  bdb create TABLE COL:TYPE[:pk]...
  bdb tables
  bdb schema TABLE
  bdb insert TABLE COL=VALUE...
  bdb select TABLE [--where COL=VALUE]
  bdb dump TABLE
  bdb update TABLE --where COL=VALUE COL=VALUE...
  bdb delete TABLE --where COL=VALUE
  bdb drop TABLE
  bdb sql "SELECT * FROM TABLE [WHERE COL = VALUE];"

Types:
  text, int, real, bool

Exemples:
  bdb init ./data
  BDB_PATH=./data bdb create users id:int:pk name:text email:text active:bool
  BDB_PATH=./data bdb insert users id=1 name=Alice email=alice@example.com active=true
  BDB_PATH=./data bdb select users --where name=Alice
USAGE
}

is_name() {
  [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

table_dir() {
  printf '%s/tables/%s' "$DB_DIR" "$1"
}

require_db() {
  [[ -d "$DB_DIR/tables" ]] || die "base introuvable: $DB_DIR (lance: bdb init)"
}

require_table() {
  local tdir
  tdir="$(table_dir "$1")"
  [[ -d "$tdir" ]] || die "table introuvable: $1"
}

lock_db() {
  mkdir -p "$DB_DIR"
  LOCK_DIR="$DB_DIR/.lock"
  local waited=0
  until mkdir "$LOCK_DIR" 2>/dev/null; do
    waited=$((waited + 1))
    [[ "$waited" -le 50 ]] || die "verrou occupe: $DB_DIR"
    sleep 0.1
  done
  trap unlock_db EXIT INT TERM
}

unlock_db() {
  if [[ -n "${LOCK_DIR:-}" && -d "$LOCK_DIR" ]]; then
    rmdir "$LOCK_DIR" 2>/dev/null || true
  fi
}

# Pure-Bash base64, no external process. bdb calls these once per field, and
# forking `base64` each time is brutally slow under emulation (QEMU TCG); a
# loop of shell builtins is far cheaper. Byte-oriented via LC_ALL=C, and kept
# compatible with bash 3.2+ (no associative arrays).
B64_ALPHABET="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

b64enc() {
  local LC_ALL=C
  local s="$1" out="" len i b0 b1 b2 c1 c2 n
  len=${#s}
  i=0
  while [ "$i" -lt "$len" ]; do
    printf -v b0 '%d' "'${s:i:1}"; b0=$(( b0 & 0xFF ))
    if [ $((i + 1)) -lt "$len" ]; then printf -v b1 '%d' "'${s:i+1:1}"; b1=$(( b1 & 0xFF )); else b1=-1; fi
    if [ $((i + 2)) -lt "$len" ]; then printf -v b2 '%d' "'${s:i+2:1}"; b2=$(( b2 & 0xFF )); else b2=-1; fi
    c1=$(( b1 < 0 ? 0 : b1 ))
    c2=$(( b2 < 0 ? 0 : b2 ))
    n=$(( (b0 << 16) | (c1 << 8) | c2 ))
    out+="${B64_ALPHABET:$(( (n >> 18) & 63 )):1}${B64_ALPHABET:$(( (n >> 12) & 63 )):1}"
    if [ "$b1" -lt 0 ]; then
      out+="=="
    else
      out+="${B64_ALPHABET:$(( (n >> 6) & 63 )):1}"
      if [ "$b2" -lt 0 ]; then out+="="; else out+="${B64_ALPHABET:$(( n & 63 )):1}"; fi
    fi
    i=$(( i + 3 ))
  done
  printf '%s' "$out"
}

b64dec() {
  local LC_ALL=C
  local s="$1" esc="" i c prefix v oct
  local acc=0 bits=0 byte
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    [ "$c" = "=" ] && break
    prefix="${B64_ALPHABET%%"$c"*}"
    [ "$prefix" = "$B64_ALPHABET" ] && continue   # not in alphabet (whitespace) -> skip
    v=${#prefix}
    acc=$(( (acc << 6) | v ))
    bits=$(( bits + 6 ))
    if [ "$bits" -ge 8 ]; then
      bits=$(( bits - 8 ))
      byte=$(( (acc >> bits) & 0xFF ))
      printf -v oct '%03o' "$byte"
      esc+="\\0$oct"
    fi
  done
  printf '%b' "$esc"
}

load_schema() {
  local table="$1"
  local schema_file
  schema_file="$(table_dir "$table")/schema.tsv"
  COLS=()
  TYPES=()
  PK_COL=""

  while IFS=$'\t' read -r col typ flags; do
    [[ -n "${col:-}" ]] || continue
    COLS+=("$col")
    TYPES+=("$typ")
    [[ "${flags:-}" == "pk" ]] && PK_COL="$col"
  done < "$schema_file"
  return 0
}

col_index() {
  local wanted="$1"
  local i
  for ((i = 0; i < ${#COLS[@]}; i++)); do
    if [[ "${COLS[$i]}" == "$wanted" ]]; then
      printf '%s' "$i"
      return 0
    fi
  done
  return 1
}

validate_type() {
  local typ="$1"
  local val="$2"
  case "$typ" in
    text|string) return 0 ;;
    int) [[ "$val" =~ ^-?[0-9]+$ ]] ;;
    real) [[ "$val" =~ ^-?([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]] ;;
    bool) [[ "$val" == "true" || "$val" == "false" || "$val" == "1" || "$val" == "0" ]] ;;
    *) die "type inconnu: $typ" ;;
  esac
}

parse_assignment() {
  local pair="$1"
  [[ "$pair" == *=* ]] || die "affectation attendue: COL=VALUE"
  ASSIGN_COL="${pair%%=*}"
  ASSIGN_VAL="${pair#*=}"
  is_name "$ASSIGN_COL" || die "nom de colonne invalide: $ASSIGN_COL"
}

value_for_col() {
  local wanted="$1"
  shift
  local pair
  for pair in "$@"; do
    parse_assignment "$pair"
    if [[ "$ASSIGN_COL" == "$wanted" ]]; then
      printf '%s' "$ASSIGN_VAL"
      return 0
    fi
  done
  return 1
}

validate_assignments() {
  local pair
  for pair in "$@"; do
    parse_assignment "$pair"
    col_index "$ASSIGN_COL" >/dev/null || die "colonne inconnue: $ASSIGN_COL"
  done
}

decode_field_at() {
  local line="$1"
  local idx="$2"
  local fields
  IFS=$'\t' read -r -a fields <<< "$line"
  b64dec "${fields[$idx]:-}"
}

row_matches() {
  local line="$1"
  local where_col="$2"
  local where_val="$3"
  local idx actual
  idx="$(col_index "$where_col")" || die "colonne inconnue: $where_col"
  actual="$(decode_field_at "$line" "$idx")"
  [[ "$actual" == "$where_val" ]]
}

render_table() {
  awk -F '\t' '
    {
      rows[NR] = $0
      if (NF > cols) cols = NF
      for (i = 1; i <= NF; i++) {
        cell[NR, i] = $i
        if (length($i) > width[i]) width[i] = length($i)
      }
    }
    function border(   i, j) {
      printf "+"
      for (i = 1; i <= cols; i++) {
        for (j = 0; j < width[i] + 2; j++) printf "-"
        printf "+"
      }
      printf "\n"
    }
    END {
      if (NR == 0) exit
      border()
      for (r = 1; r <= NR; r++) {
        printf "|"
        for (i = 1; i <= cols; i++) {
          printf " %-" width[i] "s |", cell[r, i]
        }
        printf "\n"
        if (r == 1) border()
      }
      border()
      printf "%d row%s\n", NR - 1, (NR - 1 == 1 ? "" : "s")
    }
  '
}

print_rows() {
  local table="$1"
  local where_col="${2:-}"
  local where_val="${3:-}"
  local data_file line i val
  data_file="$(table_dir "$table")/data.tsv"

  {
    (IFS=$'\t'; printf '%s\n' "${COLS[*]}")
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -n "$line" ]] || continue
      if [[ -n "$where_col" ]] && ! row_matches "$line" "$where_col" "$where_val"; then
        continue
      fi
      for ((i = 0; i < ${#COLS[@]}; i++)); do
        val="$(decode_field_at "$line" "$i")"
        if [[ "$i" -gt 0 ]]; then
          printf '\t'
        fi
        printf '%s' "$val"
      done
      printf '\n'
    done < "$data_file"
  } | render_table
}

ensure_unique_pk() {
  local table="$1"
  local pk_value="$2"
  local pk_idx line existing
  [[ -n "$PK_COL" ]] || return 0
  pk_idx="$(col_index "$PK_COL")"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    existing="$(decode_field_at "$line" "$pk_idx")"
    [[ "$existing" != "$pk_value" ]] || die "cle primaire deja presente: $PK_COL=$pk_value"
  done < "$(table_dir "$table")/data.tsv"
}

ensure_unique_pk_file() {
  local table="$1"
  local file="$2"
  local pk_idx line left right seen
  [[ -n "$PK_COL" ]] || return 0
  pk_idx="$(col_index "$PK_COL")"

  while IFS= read -r left || [[ -n "$left" ]]; do
    [[ -n "$left" ]] || continue
    seen=0
    while IFS= read -r right || [[ -n "$right" ]]; do
      [[ -n "$right" ]] || continue
      if [[ "$(decode_field_at "$left" "$pk_idx")" == "$(decode_field_at "$right" "$pk_idx")" ]]; then
        seen=$((seen + 1))
      fi
      if [[ "$seen" -gt 1 ]]; then
        printf 'bdb: cle primaire dupliquee dans %s: %s=%s\n' "$table" "$PK_COL" "$(decode_field_at "$left" "$pk_idx")" >&2
        return 1
      fi
    done < "$file"
  done < "$file"
  return 0
}

cmd_init() {
  if [[ $# -gt 0 ]]; then
    DB_DIR="$1"
  fi
  mkdir -p "$DB_DIR/tables"
  printf '%s\n' "$VERSION" > "$DB_DIR/VERSION"
  printf 'base initialisee: %s\n' "$DB_DIR"
}

cmd_create() {
  require_db
  [[ $# -ge 2 ]] || die "usage: bdb create TABLE COL:TYPE[:pk]..."
  local table="$1"
  shift
  is_name "$table" || die "nom de table invalide: $table"

  local tdir schema_file spec col typ flag pk_count
  tdir="$(table_dir "$table")"
  [[ ! -e "$tdir" ]] || die "table deja existante: $table"
  mkdir -p "$tdir"
  schema_file="$tdir/schema.tsv"
  : > "$schema_file"
  : > "$tdir/data.tsv"
  pk_count=0

  for spec in "$@"; do
    IFS=':' read -r col typ flag <<< "$spec"
    is_name "$col" || die "nom de colonne invalide: $col"
    case "$typ" in text|string|int|real|bool) ;; *) die "type invalide pour $col: $typ" ;; esac
    if [[ "${flag:-}" == "pk" ]]; then
      pk_count=$((pk_count + 1))
      [[ "$pk_count" -le 1 ]] || die "une seule cle primaire est supportee"
    elif [[ -n "${flag:-}" ]]; then
      die "option de colonne inconnue: $flag"
    fi
    printf '%s\t%s\t%s\n' "$col" "$typ" "${flag:-}" >> "$schema_file"
  done

  printf 'table creee: %s\n' "$table"
}

cmd_tables() {
  require_db
  local dir found
  found=0
  for dir in "$DB_DIR"/tables/*; do
    [[ -d "$dir" ]] || continue
    basename "$dir"
    found=1
  done
  [[ "$found" -eq 1 ]] || true
}

cmd_schema() {
  require_db
  [[ $# -eq 1 ]] || die "usage: bdb schema TABLE"
  require_table "$1"
  column -t -s $'\t' "$(table_dir "$1")/schema.tsv"
}

cmd_insert() {
  require_db
  [[ $# -ge 2 ]] || die "usage: bdb insert TABLE COL=VALUE..."
  local table="$1"
  shift
  require_table "$table"
  load_schema "$table"
  validate_assignments "$@"

  local encoded=()
  local i col typ val pk_value
  for ((i = 0; i < ${#COLS[@]}; i++)); do
    col="${COLS[$i]}"
    typ="${TYPES[$i]}"
    if ! val="$(value_for_col "$col" "$@")"; then
      die "colonne manquante: $col"
    fi
    validate_type "$typ" "$val" || die "valeur invalide pour $col ($typ): $val"
    [[ "$col" == "$PK_COL" ]] && pk_value="$val"
    encoded+=("$(b64enc "$val")")
  done

  if [[ -n "$PK_COL" ]]; then
    ensure_unique_pk "$table" "$pk_value"
  fi

  (IFS=$'\t'; printf '%s\n' "${encoded[*]}") >> "$(table_dir "$table")/data.tsv"
  printf 'ligne inseree: %s\n' "$table"
}

parse_where() {
  [[ "${1:-}" == "--where" ]] || die "clause attendue: --where COL=VALUE"
  [[ -n "${2:-}" ]] || die "clause where vide"
  parse_assignment "$2"
  WHERE_COL="$ASSIGN_COL"
  WHERE_VAL="$ASSIGN_VAL"
}

cmd_select() {
  require_db
  [[ $# -ge 1 ]] || die "usage: bdb select TABLE [--where COL=VALUE]"
  local table="$1"
  shift
  require_table "$table"
  load_schema "$table"

  if [[ $# -eq 0 ]]; then
    print_rows "$table"
  elif [[ $# -eq 2 ]]; then
    parse_where "$1" "$2"
    col_index "$WHERE_COL" >/dev/null || die "colonne inconnue: $WHERE_COL"
    print_rows "$table" "$WHERE_COL" "$WHERE_VAL"
  else
    die "usage: bdb select TABLE [--where COL=VALUE]"
  fi
}

cmd_dump() {
  require_db
  [[ $# -eq 1 ]] || die "usage: bdb dump TABLE"
  local table="$1"
  local data_file line i val
  require_table "$table"
  load_schema "$table"
  data_file="$(table_dir "$table")/data.tsv"

  (IFS=$'\t'; printf '%s\n' "${COLS[*]}")
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    for ((i = 0; i < ${#COLS[@]}; i++)); do
      val="$(decode_field_at "$line" "$i")"
      [[ "$i" -gt 0 ]] && printf '\t'
      printf '%s' "$val"
    done
    printf '\n'
  done < "$data_file"
}

cmd_update() {
  require_db
  [[ $# -ge 4 ]] || die "usage: bdb update TABLE --where COL=VALUE COL=VALUE..."
  local table="$1"
  shift
  require_table "$table"
  load_schema "$table"
  parse_where "$1" "$2"
  shift 2
  validate_assignments "$@"

  local data_file tmp line new_fields i col typ current new_val count
  data_file="$(table_dir "$table")/data.tsv"
  tmp="$(mktemp "$DB_DIR/update.XXXXXX")"
  count=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    if row_matches "$line" "$WHERE_COL" "$WHERE_VAL"; then
      new_fields=()
      for ((i = 0; i < ${#COLS[@]}; i++)); do
        col="${COLS[$i]}"
        typ="${TYPES[$i]}"
        current="$(decode_field_at "$line" "$i")"
        if ! new_val="$(value_for_col "$col" "$@")"; then
          new_val="$current"
        fi
        validate_type "$typ" "$new_val" || die "valeur invalide pour $col ($typ): $new_val"
        new_fields+=("$(b64enc "$new_val")")
      done
      (IFS=$'\t'; printf '%s\n' "${new_fields[*]}") >> "$tmp"
      count=$((count + 1))
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$data_file"

  ensure_unique_pk_file "$table" "$tmp" || { rm -f "$tmp"; exit 1; }

  mv "$tmp" "$data_file"
  printf 'lignes modifiees: %s\n' "$count"
}

cmd_delete() {
  require_db
  [[ $# -eq 3 ]] || die "usage: bdb delete TABLE --where COL=VALUE"
  local table="$1"
  shift
  require_table "$table"
  load_schema "$table"
  parse_where "$1" "$2"

  local data_file tmp line count
  data_file="$(table_dir "$table")/data.tsv"
  tmp="$(mktemp "$DB_DIR/delete.XXXXXX")"
  count=0

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    if row_matches "$line" "$WHERE_COL" "$WHERE_VAL"; then
      count=$((count + 1))
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$data_file"

  mv "$tmp" "$data_file"
  printf 'lignes supprimees: %s\n' "$count"
}

cmd_drop() {
  require_db
  [[ $# -eq 1 ]] || die "usage: bdb drop TABLE"
  require_table "$1"
  rm -rf "$(table_dir "$1")"
  printf 'table supprimee: %s\n' "$1"
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

strip_sql_value() {
  local v
  v="$(trim "$1")"
  if [[ "$v" == \'*\' && "$v" == *\' ]]; then
    v="${v:1:${#v}-2}"
  elif [[ "$v" == \"*\" && "$v" == *\" ]]; then
    v="${v:1:${#v}-2}"
  fi
  printf '%s' "$v"
}

sql_assignments_from_lists() {
  local cols="$1"
  local vals="$2"
  local -a col_arr val_arr
  local i col val
  IFS=',' read -r -a col_arr <<< "$cols"
  IFS=',' read -r -a val_arr <<< "$vals"
  [[ "${#col_arr[@]}" -eq "${#val_arr[@]}" ]] || die "SQL invalide: nombre de colonnes et valeurs different"

  SQL_ASSIGNMENTS=()
  for ((i = 0; i < ${#col_arr[@]}; i++)); do
    col="$(trim "${col_arr[$i]}")"
    val="$(strip_sql_value "${val_arr[$i]}")"
    is_name "$col" || die "SQL invalide: colonne $col"
    SQL_ASSIGNMENTS+=("$col=$val")
  done
}

sql_set_to_assignments() {
  local set_expr="$1"
  local -a parts
  local part col val
  IFS=',' read -r -a parts <<< "$set_expr"
  SQL_ASSIGNMENTS=()

  for part in "${parts[@]}"; do
    [[ "$part" == *=* ]] || die "SQL invalide: SET attend COL = VALUE"
    col="$(trim "${part%%=*}")"
    val="$(strip_sql_value "${part#*=}")"
    is_name "$col" || die "SQL invalide: colonne $col"
    SQL_ASSIGNMENTS+=("$col=$val")
  done
}

cmd_sql() {
  require_db
  [[ $# -ge 1 ]] || die "usage: bdb sql \"SELECT * FROM table WHERE id = 1;\""
  local query="$*"
  local table col val cols vals set_expr
  local select_re insert_re update_re delete_re
  query="$(trim "$query")"
  query="${query%;}"
  select_re='^SELECT[[:space:]]+\*[[:space:]]+FROM[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)([[:space:]]+WHERE[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.+))?$'
  insert_re='^INSERT[[:space:]]+INTO[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*\(([^)]*)\)[[:space:]]+VALUES[[:space:]]*\((.*)\)$'
  update_re='^UPDATE[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+SET[[:space:]]+(.+)[[:space:]]+WHERE[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$'
  delete_re='^DELETE[[:space:]]+FROM[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]+WHERE[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*(.+)$'

  shopt -s nocasematch
  if [[ "$query" =~ $select_re ]]; then
    table="${BASH_REMATCH[1]}"
    col="${BASH_REMATCH[3]:-}"
    val="$(strip_sql_value "${BASH_REMATCH[4]:-}")"
    shopt -u nocasematch
    if [[ -n "$col" ]]; then
      cmd_select "$table" --where "$col=$val"
    else
      cmd_select "$table"
    fi
  elif [[ "$query" =~ $insert_re ]]; then
    table="${BASH_REMATCH[1]}"
    cols="${BASH_REMATCH[2]}"
    vals="${BASH_REMATCH[3]}"
    shopt -u nocasematch
    sql_assignments_from_lists "$cols" "$vals"
    cmd_insert "$table" "${SQL_ASSIGNMENTS[@]}"
  elif [[ "$query" =~ $update_re ]]; then
    table="${BASH_REMATCH[1]}"
    set_expr="${BASH_REMATCH[2]}"
    col="${BASH_REMATCH[3]}"
    val="$(strip_sql_value "${BASH_REMATCH[4]}")"
    shopt -u nocasematch
    sql_set_to_assignments "$set_expr"
    cmd_update "$table" --where "$col=$val" "${SQL_ASSIGNMENTS[@]}"
  elif [[ "$query" =~ $delete_re ]]; then
    table="${BASH_REMATCH[1]}"
    col="${BASH_REMATCH[2]}"
    val="$(strip_sql_value "${BASH_REMATCH[3]}")"
    shopt -u nocasematch
    cmd_delete "$table" --where "$col=$val"
  else
    shopt -u nocasematch
    die "SQL supporte: SELECT *, INSERT INTO, UPDATE ... SET ... WHERE, DELETE FROM ... WHERE"
  fi
}

main() {
  [[ $# -gt 0 ]] || { usage; exit 0; }
  local cmd="$1"
  shift

  case "$cmd" in
    help|-h|--help) usage ;;
    init) cmd_init "$@" ;;
    create|insert|update|delete|drop|sql)
      lock_db
      "cmd_$cmd" "$@"
      ;;
    tables|schema|select|dump)
      "cmd_$cmd" "$@"
      ;;
    version|--version) printf '%s\n' "$VERSION" ;;
    *) die "commande inconnue: $cmd" ;;
  esac
}

main "$@"
