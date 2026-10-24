#!/usr/bin/env bash
# One-shot trusted install for GT1.
#
# Extracts exactly two files from the fixed commit, verifies their SHA-256, and
# installs them under /usr/local/lib/aegl-model-task. It does not touch
# /usr/local/lib/aegl-model, the formal AEGL tree, /var/lib, or systemd.
set -euo pipefail

GT1_COMMIT="e5f31c8227353e60683c86a6092b93561da30c74"
GT1_PARENT="866c1d2b108d9911809bf5c542d1ad7351340599"
GT1_BASELINE="d36f073ba98fd00e2678d773d06aa44723a0b728"
CLI_REL="bin/aegl-model-task"
MOD_REL="recovery/model_task_registry.py"
CLI_SHA="edb38c2155f617417c8f225128144fba94c822db317a799613fa5e9203669b6e"
MOD_SHA="0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de"
TARGET="/usr/local/lib/aegl-model-task"
PARENT_DIR="/usr/local/lib"

say() { printf '%s\n' "$*"; }
fail() { printf 'INSTALL_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail not_root "run as root from a trusted terminal"
for tool in git tar sha256sum mktemp realpath stat; do
  command -v "$tool" >/dev/null 2>&1 || fail missing_tool "$tool"
done

SOURCE=""
COMMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SOURCE="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    *) fail usage "unknown argument: $1" ;;
  esac
done
[ -n "$SOURCE" ] || fail usage "--source is required"
[ "$COMMIT" = "$GT1_COMMIT" ] || fail commit_mismatch "expected $GT1_COMMIT got ${COMMIT:-<empty>}"
[ -d "$SOURCE" ] || fail source_missing "$SOURCE"
SOURCE_REAL="$(realpath -e "$SOURCE")" || fail source_missing "$SOURCE"
case "$SOURCE_REAL" in
  /home/zhong/Projects/AI-Engineering-Governance-Layer|/home/zhong/Projects/AI-Engineering-Governance-Layer/*)
    fail source_is_formal "$SOURCE_REAL" ;;
esac

SAFE=(-c "safe.directory=$SOURCE_REAL")
if [ -f "$SOURCE_REAL/.git" ]; then
  GITDIR_LINE="$(sed -n 's/^gitdir: //p' "$SOURCE_REAL/.git" | head -1)"
  [ -n "$GITDIR_LINE" ] || fail source_not_git "no gitdir in $SOURCE_REAL/.git"
  case "$GITDIR_LINE" in
    /*) GITDIR="$GITDIR_LINE" ;;
    *) GITDIR="$SOURCE_REAL/$GITDIR_LINE" ;;
  esac
  GITDIR="$(realpath -e "$GITDIR")" || fail source_not_git "gitdir missing"
  COMMON="$(realpath -e "$(dirname "$(dirname "$GITDIR")")")" || fail source_not_git "common dir missing"
  SAFE+=(-c "safe.directory=$GITDIR" -c "safe.directory=$COMMON")
fi
GIT=(git "${SAFE[@]}" -C "$SOURCE_REAL")

"${GIT[@]}" rev-parse --is-inside-work-tree >/dev/null 2>&1 || fail source_not_git "$SOURCE_REAL"
test "$("${GIT[@]}" rev-parse "$GT1_COMMIT^{commit}")" = "$GT1_COMMIT" || fail commit_missing "$GT1_COMMIT"
test "$("${GIT[@]}" rev-parse "$GT1_COMMIT^")" = "$GT1_PARENT" || fail parent_mismatch
"${GIT[@]}" merge-base --is-ancestor "$GT1_BASELINE" "$GT1_COMMIT" || fail baseline_not_ancestor
test -z "$("${GIT[@]}" status --porcelain)" || fail source_dirty "commit extraction source must be clean"

[ -d "$PARENT_DIR" ] || fail parent_missing "$PARENT_DIR"
PARENT_STAT="$(stat -c '%U:%G %a' "$PARENT_DIR")"
case "$PARENT_STAT" in
  "root:root 755"|"root:root 0755") ;;
  *) fail parent_untrusted "$PARENT_STAT" ;;
esac
[ ! -e "$TARGET" ] || fail target_exists "$TARGET"

EXTRACT="$(mktemp -d /root/gt1-install-src.XXXXXX)" || fail extract_dir
chmod 0700 "$EXTRACT"
STAGE=""
cleanup() {
  [ -n "$EXTRACT" ] && rm -rf "$EXTRACT" 2>/dev/null || true
  [ -n "$STAGE" ] && rm -rf "$STAGE" 2>/dev/null || true
}
trap cleanup EXIT

"${GIT[@]}" archive "$GT1_COMMIT" "$CLI_REL" "$MOD_REL" | tar -x -C "$EXTRACT" || fail extract_failed
FILES="$(cd "$EXTRACT" && find . -type f -printf '%P\n' | sort)"
EXPECT="$(printf '%s\n%s\n' "$CLI_REL" "$MOD_REL" | sort)"
[ "$FILES" = "$EXPECT" ] || fail file_list "unexpected extracted files: $FILES"
printf '%s  %s\n' "$CLI_SHA" "$EXTRACT/$CLI_REL" | sha256sum -c - >/dev/null || fail cli_hash
printf '%s  %s\n' "$MOD_SHA" "$EXTRACT/$MOD_REL" | sha256sum -c - >/dev/null || fail module_hash

STAGE="$(mktemp -d "$PARENT_DIR/.aegl-model-task.install.XXXXXX")" || fail stage_dir
chmod 0700 "$STAGE"
install -d -o root -g root -m 0755 "$STAGE/bin" "$STAGE/recovery"
install -o root -g root -m 0755 "$EXTRACT/$CLI_REL" "$STAGE/$CLI_REL"
install -o root -g root -m 0644 "$EXTRACT/$MOD_REL" "$STAGE/$MOD_REL"

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

say "INSTALL_SOURCE_COMMIT=$GT1_COMMIT"
say "INSTALL_BASELINE=$GT1_BASELINE"
say "INSTALL_FILE $CLI_REL sha256=$CLI_SHA mode=0755 owner=root:root"
say "INSTALL_FILE $MOD_REL sha256=$MOD_SHA mode=0644 owner=root:root"
say "INSTALL_TARGET=$TARGET"
say "INSTALL_IMPACT=only $TARGET created; /usr/local/lib/aegl-model and all other paths untouched"
say "INSTALL=OK"
