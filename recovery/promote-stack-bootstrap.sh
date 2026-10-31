#!/usr/bin/env bash
# promote-stack-bootstrap.sh — root-only bootstrap for the Stack promotion driver.
#
# Copies ONLY the driver, its sync verifier and the verifier's runtime module into a
# fresh root-exclusive (0700) directory, verifies EACH separately supplied SHA256 value,
# and executes ONLY that verified copy. Nothing outside the verified directory can be
# imported by the wrapper (it uses python3 -I and an explicit local sys.path entry).
#
#   promote-stack-bootstrap.sh \
#     --src-driver FILE --sha256-driver HEX64 \
#     --src-helper FILE --sha256-helper HEX64 \
#     --src-module FILE --sha256-module HEX64 \
#     --dest NEWDIR
set -euo pipefail

SRC_DRIVER=""; SHA_DRIVER=""; SRC_HELPER=""; SHA_HELPER=""
SRC_MODULE=""; SHA_MODULE=""; DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --src-driver) SRC_DRIVER="${2:-}"; shift 2 ;;
    --sha256-driver) SHA_DRIVER="${2:-}"; shift 2 ;;
    --src-helper) SRC_HELPER="${2:-}"; shift 2 ;;
    --sha256-helper) SHA_HELPER="${2:-}"; shift 2 ;;
    --src-module) SRC_MODULE="${2:-}"; shift 2 ;;
    --sha256-module) SHA_MODULE="${2:-}"; shift 2 ;;
    --dest) DEST="${2:-}"; shift 2 ;;
    *) printf 'BOOTSTRAP_FAILED reason=usage:%s\n' "$1" >&2; exit 1 ;;
  esac
done
fail(){ printf 'BOOTSTRAP_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }
check_hex(){ [ "${#1}" -eq 64 ] || fail usage "sha256 must be 64 hex"; case "$1" in *[!0-9a-f]*) fail usage "sha256 must be lowercase hex" ;; esac; }

[ "$(id -u)" -eq 0 ] || fail not_root "run as root"
for pair in "src_driver:$SRC_DRIVER" "src_helper:$SRC_HELPER" "src_module:$SRC_MODULE"; do
  name="${pair%%:*}"; val="${pair#*:}"
  [ -n "$val" ] && [ -f "$val" ] && [ ! -L "$val" ] || fail "$name" "$val"
done
[ -n "$DEST" ] || fail usage "--dest required"
[ ! -e "$DEST" ] || fail dest_exists "$DEST"
check_hex "$SHA_DRIVER"; check_hex "$SHA_HELPER"; check_hex "$SHA_MODULE"

install -d -o root -g root -m 0700 "$DEST"
install -o root -g root -m 0700 "$SRC_DRIVER" "$DEST/promote-stack-preconsume.sh"
install -o root -g root -m 0600 "$SRC_HELPER" "$DEST/promote_stack_sync.py"
install -o root -g root -m 0600 "$SRC_MODULE" "$DEST/iap_delivery.py"
GOT_DRIVER="$(sha256sum "$DEST/promote-stack-preconsume.sh" | awk '{print $1}')"
GOT_HELPER="$(sha256sum "$DEST/promote_stack_sync.py" | awk '{print $1}')"
GOT_MODULE="$(sha256sum "$DEST/iap_delivery.py" | awk '{print $1}')"
[ "$GOT_DRIVER" = "$SHA_DRIVER" ] || fail driver_sha "$GOT_DRIVER != $SHA_DRIVER"
[ "$GOT_HELPER" = "$SHA_HELPER" ] || fail helper_sha "$GOT_HELPER != $SHA_HELPER"
[ "$GOT_MODULE" = "$SHA_MODULE" ] || fail module_sha "$GOT_MODULE != $SHA_MODULE"

printf 'DRIVER_STAGED=%s sha256=%s\n' "$DEST/promote-stack-preconsume.sh" "$GOT_DRIVER"
printf 'HELPER_STAGED=%s sha256=%s\n' "$DEST/promote_stack_sync.py" "$GOT_HELPER"
printf 'MODULE_STAGED=%s sha256=%s\n' "$DEST/iap_delivery.py" "$GOT_MODULE"
exec "$DEST/promote-stack-preconsume.sh"
