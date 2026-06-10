#!/usr/bin/env bash
set -euo pipefail

REPO="${1:?usage: assemble-altitude-rootfs.sh REPOSITORY DEST [PACKAGE...]}"
DEST="${2:?missing destination root}"
shift 2
PACKAGES=("$@")
PUBLIC_KEY="$REPO/repository.pem"

die() { echo "altitude-rootfs: $*" >&2; exit 1; }
field() { sed -n "s/^$1: *//p" "$2" | head -n 1; }
safe_link() {
  local rel="$1" target="$2" parent path part depth=0
  case "$target" in /*) return 0 ;; esac
  case "$rel" in */*) parent="${rel%/*}" ;; *) parent="" ;; esac
  path="${parent:+$parent/}$target"
  while [ -n "$path" ]; do
    case "$path" in
      */*) part="${path%%/*}"; path="${path#*/}" ;;
      *) part="$path"; path="" ;;
    esac
    case "$part" in
      ""|.) ;;
      ..) [ "$depth" -gt 0 ] || return 1; depth=$((depth - 1)) ;;
      *) depth=$((depth + 1)) ;;
    esac
  done
}
verify() {
  local digest
  digest="$(mktemp)"
  openssl dgst -sha256 -binary -out "$digest" "$1"
  openssl pkeyutl -verify -pubin -inkey "$PUBLIC_KEY" -rawin \
    -in "$digest" -sigfile "$2" >/dev/null 2>&1 || {
      rm -f "$digest"
      die "invalid signature: $1"
    }
  rm -f "$digest"
}
stanza() {
  awk -v wanted="$2" '
    BEGIN { RS=""; FS="\n" }
    {
      name=""
      for (i=1; i<=NF; i++)
        if ($i ~ /^Package: /) name=substr($i,10)
      if (name == wanted) found=$0
    }
    END { if (found != "") print found }
  ' "$1"
}
validate_archive() {
  local archive="$1" entry mode
  while read -r mode _; do
    case "${mode:0:1}" in -|d|l) ;; *) die "special file in $archive" ;; esac
  done < <(tar -tvf "$archive")
  while IFS= read -r entry; do
    case "$entry" in ALTITUDE|ALTITUDE/*|payload|payload/*) ;; *)
      die "invalid archive entry: $entry" ;;
    esac
    case "/$entry/" in */../*|*/./*) die "unsafe archive path: $entry" ;; esac
  done < <(tar -tf "$archive")
}
merge_payload_tree() {
  local source="$1" destination="$2" entry base target
  mkdir -p "$destination"
  (
    shopt -s dotglob nullglob
    for entry in "$source"/*; do
      base="${entry##*/}"
      target="$destination/$base"
      if [ -d "$entry" ] && [ -e "$target" ]; then
        merge_payload_tree "$entry" "$target"
      else
        cp -a "$entry" "$destination/"
      fi
    done
  )
}
install_payload() {
  local payload="$1" destination="$2"
  if [ -z "$(find "$destination" -mindepth 1 -print -quit)" ]; then
    cp -a "$payload/." "$destination/"
    return
  fi
  if command -v rsync >/dev/null; then
    rsync -a --keep-dirlinks "$payload/" "$destination/"
  else
    merge_payload_tree "$payload" "$destination"
  fi
}

[ -f "$REPO/INDEX" ] || die "repository index missing"
[ -f "$PUBLIC_KEY" ] || die "repository public key missing"
verify "$REPO/INDEX" "$REPO/INDEX.sig"
if [ "${#PACKAGES[@]}" -eq 0 ]; then
  while IFS= read -r package; do PACKAGES+=("$package"); done \
    < <(sed -n 's/^Package: *//p' "$REPO/INDEX")
fi

rm -rf "$DEST"
mkdir -p "$DEST"
for name in "${PACKAGES[@]}"; do
  metadata="$(stanza "$REPO/INDEX" "$name")"
  [ -n "$metadata" ] || die "package not found: $name"
  filename="$(printf '%s\n' "$metadata" | sed -n 's/^Filename: *//p')"
  expected="$(printf '%s\n' "$metadata" | sed -n 's/^SHA256: *//p')"
  package="$REPO/$filename"
  [ -f "$package" ] || die "package file missing: $filename"
  [ "$(sha256sum "$package" | awk '{print $1}')" = "$expected" ] ||
    die "checksum mismatch: $name"
  verify "$package" "$package.sig"
  validate_archive "$package"
  tmp="$(mktemp -d)"
  tar -xf "$package" -C "$tmp"
  manifest="$tmp/ALTITUDE/MANIFEST"
  [ "$(field Name "$manifest")" = "$name" ] ||
    die "manifest mismatch: $name"
  (cd "$tmp" && sha256sum -c ALTITUDE/files.sha256 >/dev/null) ||
    die "payload checksum mismatch: $name"
  while IFS= read -r link; do
    target="$(readlink "$link")"
    rel="${link#"$tmp/payload"/}"
    safe_link "$rel" "$target" || die "unsafe symlink: $link"
  done < <(find "$tmp/payload" -type l -print)
  install_payload "$tmp/payload" "$DEST"
  state="$DEST/var/lib/altitude/packages/$name"
  mkdir -p "$state"
  cp "$manifest" "$tmp/ALTITUDE/files.sha256" \
    "$tmp/ALTITUDE/links.sha256" "$tmp/ALTITUDE/paths" "$state/"
  printf '%s\n' "$expected" > "$state/package.sha256"
  printf 'file://%s\n' "$package" > "$state/source"
  rm -rf "$tmp"
  echo "altitude-rootfs: installed $name"
done
echo "altitude-rootfs: assembled $DEST from ${#PACKAGES[@]} signed packages"
