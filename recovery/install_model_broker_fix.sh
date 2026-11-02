#!/usr/bin/env bash
# install.sh — install ONLY model_broker.py from this verified package copy.
# Root only. No backups. No other installed file is written or removed.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PAYLOAD="$HERE/../payload/model_broker.py"
DEST_DIR="/usr/local/lib/aegl-model"
DEST="$DEST_DIR/model_broker.py"

# Pinned: the installed predecessor and the reviewed candidate.
EXPECT_BEFORE="29ecedf420cd455e556780a3ddcfd98966d8aab7bc154e46a759a015b096ab32"
EXPECT_AFTER="ab0d4c36cb27f1b23cc1510f3650f10df8375dd72db4078eb2a99ad41d93c3e3"

say() { printf '%s\n' "$*"; }
die() { printf 'DEPLOY_FAILED reason=%s: %s\n' "$1" "${2:-}" >&2; exit 1; }

snapshot() { # hashes of the OTHER installed files — must not change
  local f
  for f in "$DEST_DIR"/*; do
    [ -f "$f" ] || continue
    [ "$f" = "$DEST" ] && continue
    sha256sum "$f"
  done
}

[ "$(id -u)" -eq 0 ] || die not_root "run as root"
[ -f "$PAYLOAD" ] && [ ! -L "$PAYLOAD" ] || die payload "$PAYLOAD"
[ -f "$DEST" ] && [ ! -L "$DEST" ] || die installed_missing "$DEST"
[ "$(sha256sum "$PAYLOAD" | awk '{print $1}')" = "$EXPECT_AFTER" ] \
  || die payload_hash "payload is not the reviewed candidate"

before="$(sha256sum "$DEST" | awk '{print $1}')"
say "INSTALLED_BEFORE=$before"
if [ "$before" = "$EXPECT_AFTER" ]; then
  say "ALREADY_INSTALLED (installed file is already the candidate)"
  say "DEPLOY_OK (no change)"
  exit 0
fi
[ "$before" = "$EXPECT_BEFORE" ] \
  || die predecessor "installed hash $before != expected predecessor $EXPECT_BEFORE"

snap_before="$(snapshot)"
install -o root -g root -m 0644 -- "$PAYLOAD" "$DEST.new" || die stage "$DEST.new"
mv -f -- "$DEST.new" "$DEST" || die swap "$DEST"
after="$(sha256sum "$DEST" | awk '{print $1}')"
[ "$after" = "$EXPECT_AFTER" ] || die installed_hash "$after != $EXPECT_AFTER"
[ "$(stat -c '%U:%G %a' "$DEST")" = "root:root 644" ] \
  || die ownership "owner/mode is $(stat -c '%U:%G %a' "$DEST"), expected root:root 644"
snap_after="$(snapshot)"
[ "$snap_before" = "$snap_after" ] \
  || die side_effect "another installed file changed (sandbox/config/guard must stay untouched)"

say "INSTALLED_AFTER=$after owner=root:root mode=0644 others=unchanged"
say "DEPLOY_OK"
