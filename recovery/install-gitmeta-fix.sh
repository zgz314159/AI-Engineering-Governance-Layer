#!/usr/bin/env bash
# install.sh — deploy ONLY the Git-metadata mapping fix (launcher + helper).
# Root only. Helper goes in FIRST, the launcher is enabled LAST. No backups, no other file
# is written, and every payload is verified before anything is replaced.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$HERE/../payload"
DEST_DIR="/usr/local/lib/aegl-model"
LAUNCHER="$DEST_DIR/aegl-hermes-sandbox"
HELPER="$DEST_DIR/git_meta_mounts.sh"
BROKER="$DEST_DIR/model_broker.py"

EXPECT_LAUNCHER_BEFORE="bc92cb1ab43e2a227021ed5e0f90369ce7f9f70ca320a30ff3ffc34f8732f070"
EXPECT_LAUNCHER_AFTER="06aab45259a1fe2e220260dc962137c227468e49f5d6027cfb9fc534380ee41a"
EXPECT_HELPER_AFTER="f93bbfdd286e6a554c10edcdda6dd40a20d32d1ffbcb17dc56091bbeac8ac50a"
EXPECT_BROKER="ab0d4c36cb27f1b23cc1510f3650f10df8375dd72db4078eb2a99ad41d93c3e3"

say() { printf '%s\n' "$*"; }
die() { printf 'DEPLOY_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }
h() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
mode_of() { stat -c '%U:%G %a' "$1"; }

snapshot() { # every OTHER installed file — must not change
  local f
  for f in "$DEST_DIR"/* "$DEST_DIR"/guard/*; do
    [ -f "$f" ] || continue
    case "$f" in "$LAUNCHER"|"$HELPER") continue ;; esac
    sha256sum "$f"
  done
}

atomic() { # <src> <dest> <mode>
  install -o root -g root -m "$3" -- "$1" "$2.new" || die stage "$2.new"
  mv -f -- "$2.new" "$2" || die swap "$2"
}

[ "$(id -u)" -eq 0 ] || die not_root "run as root"
[ -d "$DEST_DIR" ] || die dest_dir "$DEST_DIR"
[ -f "$PAYLOAD/aegl-hermes-sandbox" ] || die payload_launcher
[ -f "$PAYLOAD/git_meta_mounts.sh" ] || die payload_helper

# 3. every payload verified BEFORE anything is replaced
[ "$(h "$PAYLOAD/aegl-hermes-sandbox")" = "$EXPECT_LAUNCHER_AFTER" ] || die payload_launcher_hash "$(h "$PAYLOAD/aegl-hermes-sandbox")"
[ "$(h "$PAYLOAD/git_meta_mounts.sh")" = "$EXPECT_HELPER_AFTER" ] || die payload_helper_hash "$(h "$PAYLOAD/git_meta_mounts.sh")"
[ -f "$LAUNCHER" ] || die launcher_missing "$LAUNCHER"
# the broker must already be the reviewed candidate and must stay that way
[ "$(h "$BROKER")" = "$EXPECT_BROKER" ] || die broker "$(h "$BROKER")"
SNAP_BEFORE="$(snapshot)"

# 1a. helper FIRST — only if it was absent or is already the approved version
if [ ! -e "$HELPER" ]; then
  say "HELPER_ABSENT -> installing"
  atomic "$PAYLOAD/git_meta_mounts.sh" "$HELPER" 0755
elif [ "$(h "$HELPER")" = "$EXPECT_HELPER_AFTER" ]; then
  say "HELPER_ALREADY_APPROVED"
else
  die helper_unknown "$HELPER is $(h "$HELPER") (expected absent or $EXPECT_HELPER_AFTER)"
fi
[ "$(h "$HELPER")" = "$EXPECT_HELPER_AFTER" ] || die helper_final "$(h "$HELPER")"
[ "$(mode_of "$HELPER")" = "root:root 755" ] || die helper_mode "$(mode_of "$HELPER")"
say "HELPER_OK sha=$EXPECT_HELPER_AFTER owner=root:root mode=0755"

# 1b. launcher LAST
BEFORE="$(h "$LAUNCHER")"
say "LAUNCHER_BEFORE=$BEFORE"
if [ "$BEFORE" = "$EXPECT_LAUNCHER_AFTER" ]; then
  say "LAUNCHER_ALREADY_APPROVED"
else
  [ "$BEFORE" = "$EXPECT_LAUNCHER_BEFORE" ] \
    || die launcher_predecessor "$BEFORE != $EXPECT_LAUNCHER_BEFORE"
  atomic "$PAYLOAD/aegl-hermes-sandbox" "$LAUNCHER" 0755
fi
AFTER="$(h "$LAUNCHER")"
[ "$AFTER" = "$EXPECT_LAUNCHER_AFTER" ] || die launcher_final "$AFTER"
[ "$(mode_of "$LAUNCHER")" = "root:root 755" ] || die launcher_mode "$(mode_of "$LAUNCHER")"
say "LAUNCHER_AFTER=$AFTER owner=root:root mode=0755"

# 4. the verified runtime deps and every other installed file must be untouched
[ "$SNAP_BEFORE" = "$(snapshot)" ] || die side_effect "another installed file changed"
[ "$(h "$BROKER")" = "$EXPECT_BROKER" ] || die broker_after "$(h "$BROKER")"
say "OTHERS_UNCHANGED broker=$EXPECT_BROKER"
say "DEPLOY_OK"
