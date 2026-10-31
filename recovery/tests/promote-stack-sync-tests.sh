#!/usr/bin/env bash
# promote-stack-sync-tests.sh — the ONE real-Git flow check for the Stack promotion sync.
#
# Offline, model-free, no root: throwaway repos only. It calls the ACTUAL production
# sync body (_formal_sync_lib) emitted by the driver — not a re-implementation.
#
# Case A: the broker CAS already advanced master while the index/worktree still sit at
#         the approved baseline. The production sync must verify the lag and synchronise
#         index+files to the candidate, with HEAD unchanged at the candidate.
# Case B: the same pre-state plus a REAL user modification that matches neither the
#         baseline nor the candidate blob. The sync must refuse and PRESERVE the file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIVER="$HERE/../promote-stack-preconsume.sh"
[ -f "$DRIVER" ] || { echo "FAIL driver missing"; exit 1; }
LIB="$(bash -c 'source "$1" >/dev/null 2>&1; _formal_sync_lib' _ "$DRIVER")" \
  || { echo "FAIL cannot extract production sync body"; exit 1; }
[ -n "$LIB" ] || { echo "FAIL empty sync body"; exit 1; }

RC=0
check(){ if [ "$2" = "$3" ]; then printf 'PASS %s (%s)\n' "$1" "$2"; else printf 'FAIL %s got=%s want=%s\n' "$1" "$2" "$3"; RC=1; fi; }

T="$(mktemp -d /var/tmp/iap-promote-sync-XXXXXX)"
trap 'rm -rf "$T"' EXIT

make_repo(){ # <dir> -> sets BASE/COMMIT (parent = BASE)
  local d="$1"
  git -C "$d" init -q -b master
  printf 'base\n' > "$d/a.txt"; printf 'base\n' > "$d/b.txt"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@l commit -q -m base
  BASE="$(git -C "$d" rev-parse HEAD)"
  printf 'tip\n' > "$d/a.txt"; printf 'new\n' > "$d/c.txt"
  git -C "$d" add -A
  git -C "$d" -c user.name=t -c user.email=t@l commit -q -m tip
  COMMIT="$(git -C "$d" rev-parse HEAD)"
}

# --- Case A: CAS advanced, index/files at baseline -> sync must complete correctly --- #
R="$T/r1"; mkdir -p "$R"; make_repo "$R"
git -C "$R" checkout -q -B master "$BASE"
git -C "$R" update-ref refs/heads/master "$COMMIT"          # broker CAS applied
check "A1.head_is_candidate" "$(git -C "$R" rev-parse HEAD)" "$COMMIT"
[ -n "$(git -C "$R" status --porcelain)" ] && echo "PASS A2.baseline_lag_visible" || { echo "FAIL A2 no lag"; RC=1; }

PROJ="$R" BRANCH=master TIP="$COMMIT" BASELINE_OID="$BASE" FORMAL_MODE=sync \
  bash -c "$LIB" >"$T/a.out" 2>&1; src=$?
check "A3.sync_rc" "$src" "0"
check "A4.head" "$(git -C "$R" rev-parse HEAD)" "$COMMIT"
check "A5.index_worktree_clean" "$(git -C "$R" status --porcelain)" ""
check "A6.a_content" "$(cat "$R/a.txt")" "tip"
check "A7.c_created" "$([ -f "$R/c.txt" ] && echo yes || echo no)" "yes"
check "A8.a_index_blob" "$(git -C "$R" ls-files -s -- a.txt | awk '{print $2}')" "$(git -C "$R" rev-parse "$COMMIT:a.txt")"

# --- Case B: same pre-state + a real user modification -> refuse and preserve -------- #
R2="$T/r2"; mkdir -p "$R2"; make_repo "$R2"
git -C "$R2" checkout -q -B master "$BASE"
git -C "$R2" update-ref refs/heads/master "$COMMIT"
printf 'user-edit\n' > "$R2/a.txt"                           # neither base nor tip blob
PROJ="$R2" BRANCH=master TIP="$COMMIT" BASELINE_OID="$BASE" FORMAL_MODE=sync \
  bash -c "$LIB" >"$T/b.out" 2>&1; src=$?
[ "$src" -ne 0 ] && echo "PASS B1.real_mod_refused (rc=$src)" || { echo "FAIL B1 rc=0"; RC=1; }
grep -q 'formal_dirty_preserved' "$T/b.out" && echo "PASS B2.reason" || { echo "FAIL B2 reason"; RC=1; }
check "B3.modification_preserved" "$(cat "$R2/a.txt")" "user-edit"
check "B4.head_untouched" "$(git -C "$R2" rev-parse HEAD)" "$COMMIT"

echo "SUMMARY rc=$RC"; exit "$RC"
