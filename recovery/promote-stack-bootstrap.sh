#!/usr/bin/env bash
# promote-stack-bootstrap.sh — root-only bootstrap for the Stack promotion driver.
#
# Copies ONLY the driver and its sync verifier into a fresh root-exclusive (0700)
# directory, verifies BOTH separately supplied SHA256 values, and executes ONLY that
# verified copy. The caller's mutable paths are never executed.
#
#   promote-stack-bootstrap.sh \
#     --src-driver FILE --sha256-driver HEX64 \
#     --src-helper FILE --sha256-helper HEX64 \
#     --dest NEWDIR
set -euo pipefail

SRC_DRIVER=""; SHA_DRIVER=""; SRC_HELPER=""; SHA_HELPER=""; DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src-driver) SRC_DRIVER="${2:-}"; shift 2 ;;
    --sha256-driver) SHA_DRIVER="${2:-}"; shift 2 ;;
    --src-helper) SRC_HELPER="${2:-}"; shift 2 ;;
    --sha256-helper) SHA_HELPER="${2:-}"; shift 2 ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    *) printf 'BOOTSTRAP_FAILED reason=usage:%s\n' "$1" >&2; exit 1 ;;
  esac
done
fail(){ printf 'BOOTSTRAP_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }
check_hex(){ [ "${#1}" -eq 64 ] || fail usage "sha256 must be 64 hex"; case "$1" in *[!0-9a-f]*) fail usage "sha256 must be lowercase hex" ;; esac; }

[ "$(id -u)" -eq 0 ] || fail not_root "run as root"
[ -n "$SRC_DRIVER" ] && [ -f "$SRC_DRIVER" ] && [ ! -L "$SRC_DRIVER" ] || fail src_driver "$SRC_DRIVER"
[ -n "$SRC_HELPER" ] && [ -f "$SRC_HELPER" ] && [ ! -L "$SRC_HELPER" ] || fail src_helper "$SRC_HELPER"
[ -n "$DEST" ] || fail usage "--dest required"
[ ! -e "$DEST" ] || fail dest_exists "$DEST"
check_hex "$SHA_DRIVER"; check_hex "$SHA_HELPER"

install -d -o root -g root -m 0700 "$DEST"
install -o root -g root -m 0700 "$SRC_DRIVER" "$DEST/promote-stack-preconsume.sh"
install -o root -g root -m 0600 "$SRC_HELPER" "$DEST/promote_stack_sync.py"
GOT_DRIVER="$(sha256sum "$DEST/promote-stack-preconsume.sh" | awk '{print $1}')"
GOT_HELPER="$(sha256sum "$DEST/promote_stack_sync.py" | awk '{print $1}')"
[ "$GOT_DRIVER" = "$SHA_DRIVER" ] || fail driver_sha "$GOT_DRIVER != $SHA_DRIVER"
[ "$GOT_HELPER" = "$SHA_HELPER" ] || fail helper_sha "$GOT_HELPER != $SHA_HELPER"

printf 'DRIVER_STAGED=%s sha256=%s\n' "$DEST/promote-stack-preconsume.sh" "$GOT_DRIVER"
printf 'HELPER_STAGED=%s sha256=%s\n' "$DEST/promote_stack_sync.py" "$GOT_HELPER"
exec "$DEST/promote-stack-preconsume.sh"
