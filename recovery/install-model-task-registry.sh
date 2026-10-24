#!/usr/bin/env bash
# Install the fixed GT1 payload from a root-exclusive, already-verified directory.
# This script never runs git and never reads the development checkout.
set -euo pipefail

CLI_REL="bin/aegl-model-task"
MOD_REL="recovery/model_task_registry.py"
CLI_SHA="edb38c2155f617417c8f225128144fba94c822db317a799613fa5e9203669b6e"
MOD_SHA="0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de"
TARGET="/usr/local/lib/aegl-model-task"
PARENT_DIR="/usr/local/lib"

say() { printf '%s\n' "$*"; }
fail() { printf 'INSTALL_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail not_root "run as root from a trusted terminal"
for tool in sha256sum mktemp realpath stat install mv chmod; do
  command -v "$tool" >/dev/null 2>&1 || fail missing_tool "$tool"
done

PAYLOAD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --payload-dir) PAYLOAD="${2:-}"; shift 2 ;;
    *) fail usage "unknown argument: $1" ;;
  esac
done
[ -n "$PAYLOAD" ] || fail usage "--payload-dir is required"
[ -d "$PAYLOAD" ] || fail payload_missing "$PAYLOAD"
PAYLOAD="$(realpath -e "$PAYLOAD")" || fail payload_missing "$PAYLOAD"
[ ! -L "$PAYLOAD" ] || fail payload_symlink "$PAYLOAD"
[ "$(stat -c '%U:%G %a' "$PAYLOAD")" = "root:root 700" ] \
  || fail payload_not_root_exclusive "$(stat -c '%U:%G %a' "$PAYLOAD")"

for rel in "$CLI_REL" "$MOD_REL"; do
  [ -f "$PAYLOAD/$rel" ] || fail payload_file_missing "$rel"
  [ ! -L "$PAYLOAD/$rel" ] || fail payload_symlink "$rel"
done
printf '%s  %s\n' "$CLI_SHA" "$PAYLOAD/$CLI_REL" | sha256sum -c - >/dev/null || fail cli_hash
printf '%s  %s\n' "$MOD_SHA" "$PAYLOAD/$MOD_REL" | sha256sum -c - >/dev/null || fail module_hash

MANIFEST="$PAYLOAD/recovery/gt1-install-manifest.txt"
[ -f "$MANIFEST" ] || fail manifest_missing "$MANIFEST"
[ ! -L "$MANIFEST" ] || fail manifest_symlink "$MANIFEST"
[ "$(stat -c '%U:%G' "$MANIFEST")" = "root:root" ] || fail manifest_owner
[ -r "$MANIFEST" ] || fail manifest_unreadable

[ -d "$PARENT_DIR" ] || fail parent_missing "$PARENT_DIR"
PARENT_STAT="$(stat -c '%U:%G %a' "$PARENT_DIR")"
case "$PARENT_STAT" in
  "root:root 755"|"root:root 0755") ;;
  *) fail parent_untrusted "$PARENT_STAT" ;;
esac
[ ! -e "$TARGET" ] || fail target_exists "$TARGET"

STAGE="$(mktemp -d "$PARENT_DIR/.aegl-model-task.install.XXXXXX")" || fail stage_dir
chmod 0700 "$STAGE"
cleanup() { [ -n "${STAGE:-}" ] && rm -rf "$STAGE" 2>/dev/null || true; }
trap cleanup EXIT

install -d -o root -g root -m 0755 "$STAGE/bin" "$STAGE/recovery"
install -o root -g root -m 0755 "$PAYLOAD/$CLI_REL" "$STAGE/$CLI_REL"
install -o root -g root -m 0644 "$PAYLOAD/$MOD_REL" "$STAGE/$MOD_REL"

test "$(stat -c '%U:%G %a' "$STAGE/bin")" = "root:root 755" || fail stage_bin_mode
test "$(stat -c '%U:%G %a' "$STAGE/recovery")" = "root:root 755" || fail stage_recovery_mode
test "$(stat -c '%U:%G %a' "$STAGE/$CLI_REL")" = "root:root 755" || fail stage_cli_mode
test "$(stat -c '%U:%G %a' "$STAGE/$MOD_REL")" = "root:root 644" || fail stage_module_mode
printf '%s  %s\n' "$CLI_SHA" "$STAGE/$CLI_REL" | sha256sum -c - >/dev/null || fail stage_cli_hash
printf '%s  %s\n' "$MOD_SHA" "$STAGE/$MOD_REL" | sha256sum -c - >/dev/null || fail stage_module_hash

chmod 0755 "$STAGE"
[ ! -e "$TARGET" ] || fail target_appeared "$TARGET"
mv -T "$STAGE" "$TARGET" || fail move_failed "$TARGET"
STAGE=""

test "$(stat -c '%U:%G %a' "$TARGET")" = "root:root 755" || fail target_mode
test "$(stat -c '%U:%G %a' "$TARGET/bin")" = "root:root 755" || fail target_bin_mode
test "$(stat -c '%U:%G %a' "$TARGET/recovery")" = "root:root 755" || fail target_recovery_mode
test "$(stat -c '%U:%G %a' "$TARGET/$CLI_REL")" = "root:root 755" || fail target_cli_mode
test "$(stat -c '%U:%G %a' "$TARGET/$MOD_REL")" = "root:root 644" || fail target_module_mode
printf '%s  %s\n' "$CLI_SHA" "$TARGET/$CLI_REL" | sha256sum -c - >/dev/null || fail target_cli_hash
printf '%s  %s\n' "$MOD_SHA" "$TARGET/$MOD_REL" | sha256sum -c - >/dev/null || fail target_module_hash

say "INSTALL_PAYLOAD_SHA_CLI=$CLI_SHA"
say "INSTALL_PAYLOAD_SHA_MODULE=$MOD_SHA"
say "INSTALL_TARGET=$TARGET"
say "INSTALL_IMPACT=only $TARGET created; /usr/local/lib/aegl-model and all other paths untouched"
say "INSTALL=OK"
