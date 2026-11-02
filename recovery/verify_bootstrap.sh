#!/usr/bin/env bash
# verify_bootstrap.sh — root-exclusive staging for a verification package.
# Root only. Verifies the manifest anchor FIRST, copies the whole package file by file
# into a fresh root-exclusive directory, re-verifies it, and runs ONLY that copy.
#   verify_bootstrap.sh --src DIR --dest NEWDIR --manifest-sha256 HEX64
set -euo pipefail

SRC=""; DEST=""; ANCHOR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:-}"; shift 2 ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    --manifest-sha256) ANCHOR="${2:-}"; shift 2 ;;
    *) printf 'BOOTSTRAP_FAILED reason=usage: %s\n' "$1" >&2; exit 1 ;;
  esac
done
fail() { printf 'BOOTSTRAP_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail not_root "run as root"
[ -n "$SRC" ] && [ -d "$SRC" ] && [ ! -L "$SRC" ] || fail src "$SRC"
[ -n "$DEST" ] || fail usage "--dest required"
[ ! -e "$DEST" ] || fail dest_exists "$DEST"
[ "${#ANCHOR}" -eq 64 ] || fail usage "anchor must be 64 hex"
case "$ANCHOR" in *[!0-9a-f]*) fail usage "anchor must be lowercase hex" ;; esac

install -d -o root -g root -m 0700 "$DEST"
install -o root -g root -m 0600 "$SRC/MANIFEST.sha256" "$DEST/MANIFEST.sha256"
GOT="$(sha256sum "$DEST/MANIFEST.sha256" | awk '{print $1}')"
[ "$GOT" = "$ANCHOR" ] || fail manifest_anchor "$GOT != $ANCHOR"

while read -r sha rel; do
  [ -n "$rel" ] || continue
  case "$rel" in /*|*..*) fail bad_path "$rel" ;; esac
  [ -f "$SRC/$rel" ] && [ ! -L "$SRC/$rel" ] || fail member "$rel"
  install -d -o root -g root -m 0755 "$DEST/$(dirname "$rel")"
  case "$rel" in bin/*|*.sh) mode=0755 ;; *) mode=0644 ;; esac
  install -o root -g root -m "$mode" "$SRC/$rel" "$DEST/$rel"
done < "$DEST/MANIFEST.sha256"
printf '%s\n' "$GOT" > "$DEST/MANIFEST.sha256.sha256"
( cd "$DEST" && sha256sum -c --quiet MANIFEST.sha256 ) || fail copied_tree "copy differs from manifest"
exec "$DEST/bin/run_check.sh"
