#!/usr/bin/env bash
# One-case regression: tip adds a file absent from baseline; real update-ref +
# production formal_pre_cas_check / sync_formal_to_tip land it cleanly.
# No model / browser / full orch suite.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
EXEC="$AEGL_ROOT/recovery/keeplab-appprojects-exec.sh"
ST="$(mktemp -d /var/tmp/aegl-formal-added-XXXXXX)" || { echo "mktemp failed"; exit 2; }
cleanup(){ chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

OP_USER="$(id -un)"
export OP_USER
say(){ printf '%s\n' "$*"; }
stop(){ printf 'STOP_AT=%s\n' "$1" >&2; shift; printf 'EXEC_ERROR: %s\n' "$*" >&2; exit 1; }
eval "$(python3 - "$EXEC" <<'PY'
from pathlib import Path
import sys
t = Path(sys.argv[1]).read_text()
a = t.index("# BEGIN_FORMAL_SYNC")
b = t.index("# END_FORMAL_SYNC")
print(t[a:b + len("# END_FORMAL_SYNC")])
PY
)"

# Static: production sync uses rev-parse --verify for blob_at.
grep -q 'git rev-parse --verify "\$treeish:\$path"' "$EXEC" \
  || { echo "FAIL: blob_at missing --verify"; exit 1; }
grep -qE 'new_blob="\$\(blob_at HEAD' "$EXEC" \
  || { echo "FAIL: new_blob not via blob_at"; exit 1; }
grep -qE 'old_blob="\$\(blob_at "\$BASELINE_OID"' "$EXEC" \
  || { echo "FAIL: old_blob not via blob_at"; exit 1; }

REPO="$ST/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
( cd "$REPO" && echo v1 > f.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm v1 )
git -C "$REPO" branch -M main
V1="$(git -C "$REPO" rev-parse HEAD)"
# Candidate tip: add new file absent from V1
git -C "$REPO" checkout -q -b cand
( cd "$REPO" && echo new > added.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm add )
V2="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q main
test ! -e "$REPO/added.txt"

# Demonstrate --verify failure is empty (not OID:path) before sync.
miss="$(git -C "$REPO" rev-parse --verify "$V1:added.txt" 2>/dev/null || true)"
test -z "$miss" || { echo "FAIL: unexpected OID for missing path: $miss"; exit 1; }
say "PASS: rev-parse --verify missing path yields empty (→ MISSING)"

FORMAL_BASELINE_OID=""
formal_pre_cas_check "$REPO" main >/dev/null
test "$FORMAL_BASELINE_OID" = "$V1"

git -C "$REPO" update-ref refs/heads/main "$V2"
test "$(git -C "$REPO" rev-parse HEAD)" = "$V2"
test ! -e "$REPO/added.txt"

sync_formal_to_tip "$REPO" "$V2" main "$V1"
test -f "$REPO/added.txt"
test "$(cat "$REPO/added.txt")" = "new"
test "$(git -C "$REPO" rev-parse HEAD)" = "$V2"
test -z "$(git -C "$REPO" status --porcelain)"
want="$(git -C "$REPO" rev-parse --verify HEAD:added.txt)"
got="$(git -C "$REPO" hash-object -t blob -- added.txt)"
test "$want" = "$got"
idx="$(git -C "$REPO" ls-files -s -- added.txt | awk '{print $2}')"
test "$idx" = "$want"

say "PASS: added file landed; index matches tip; worktree clean"
say "FORMAL_ADDED_FILE_TEST passed=1 failed=0"
