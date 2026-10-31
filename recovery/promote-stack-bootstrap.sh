#!/usr/bin/env bash
# promote-stack-bootstrap.sh — root-only bootstrap for the Stack promotion driver.
#
# Copies ONLY the driver into a fresh root-exclusive (0700) directory, verifies its
# separately supplied SHA256, and executes ONLY that verified copy. The copy is the
# trust anchor; the caller's mutable path is never executed.
#
#   promote-stack-bootstrap.sh --src FILE --dest NEWDIR --sha256 HEX64
set -euo pipefail

SRC=""; DEST=""; SHA=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src) SRC="${2:-}"; shift 2 ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    --sha256) SHA="${2:-}"; shift 2 ;;
    *) printf 'BOOTSTRAP_FAILED reason=usage:%s\n' "$1" >&2; exit 1 ;;
  esac
done
fail(){ printf 'BOOTSTRAP_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail not_root "run as root"
[ -n "$SRC" ] && [ -f "$SRC" ] && [ ! -L "$SRC" ] || fail src "$SRC"
[ -n "$DEST" ] || fail usage "--dest required"
[ ! -e "$DEST" ] || fail dest_exists "$DEST"
[ "${#SHA}" -eq 64 ] || fail usage "sha256 must be 64 hex"
case "$SHA" in *[!0-9a-f]*) fail usage "sha256 must be lowercase hex" ;; esac

install -d -o root -g root -m 0700 "$DEST"
install -o root -g root -m 0700 "$SRC" "$DEST/driver.sh"
GOT="$(sha256sum "$DEST/driver.sh" | awk '{print $1}')"
[ "$GOT" = "$SHA" ] || fail driver_sha "$GOT != $SHA"

printf 'DRIVER_STAGED=%s sha256=%s\n' "$DEST/driver.sh" "$GOT"
exec "$DEST/driver.sh"
