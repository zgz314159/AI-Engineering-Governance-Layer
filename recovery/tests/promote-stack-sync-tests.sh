#!/usr/bin/env bash
# promote-stack-sync-tests.sh — the necessary real-Git flow checks for the Stack promotion.
#
# Offline, model-free, no root: throwaway repos only. Every case drives the ACTUAL
# production helper (promote_stack_sync.py -> iap_delivery.Delivery), not a copy.
#
#  A  CAS advanced, index/files at baseline        -> sync completes, files+index correct
#  B  same + real worktree modification             -> refused, preserved
#  C  Git query failure (not a repo)                -> non-zero, zero restore
#  D  real STAGED modification, worktree baseline   -> refused, index preserved
#  E  continuation cleanup via trusted record       -> precise removal
#  F  unknown leftover in the candidate dir         -> non-zero, preserved, no CLEANUP_DONE
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/../promote_stack_sync.py"
[ -f "$HELPER" ] || { echo "FAIL helper missing"; exit 1; }

RC=0
check(){ if [ "$2" = "$3" ]; then printf 'PASS %s (%s)\n' "$1" "$2"; else printf 'FAIL %s got=%s want=%s\n' "$1" "$2" "$3"; RC=1; fi; }
check_ne(){ if [ "$2" != "$3" ]; then printf 'PASS %s (%s)\n' "$1" "$2"; else printf 'FAIL %s unexpectedly %s\n' "$1" "$2"; RC=1; fi; }
has(){ printf '%s' "$2" | grep -q "$1"; }

T="$(mktemp -d /var/tmp/iap-promote-sync-XXXXXX)"
trap 'rm -rf "$T"' EXIT
LED="$T/ledger"; mkdir -p "$LED"
GLP=references/architecture-templates
GLO=4a3b2a141f457f1312c8dc52d6cbea6c9592af72
PY=(python3 "$HELPER" --ledger "$LED" --gitlink-path "$GLP" --gitlink-oid "$GLO")

make_repo(){ # <dir> -> BASE/COMMIT (parent = BASE)
  local d="$1"
  git -C "$d" init -q -b master
  printf 'base\n' > "$d/a.txt"; printf 'base\n' > "$d/b.txt"
  git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@l commit -q -m base
  BASE="$(git -C "$d" rev-parse HEAD)"
  printf 'tip\n' > "$d/a.txt"; printf 'new\n' > "$d/c.txt"
  git -C "$d" add -A; git -C "$d" -c user.name=t -c user.email=t@l commit -q -m tip
  COMMIT="$(git -C "$d" rev-parse HEAD)"
}
cas_applied(){ # <dir> : master=COMMIT while index/worktree stay at BASE
  git -C "$1" checkout -q -B master "$BASE"
  git -C "$1" update-ref refs/heads/master "$COMMIT"
}

# ---- A: sync from the approved baseline lag --------------------------------------- #
R="$T/r1"; mkdir -p "$R"; make_repo "$R"; cas_applied "$R"
out="$("${PY[@]}" --mode sync --project "$R" --base "$BASE" --final "$COMMIT" 2>&1)"; rc=$?
check "A1.sync_rc" "$rc" "0"
check "A2.head" "$(git -C "$R" rev-parse HEAD)" "$COMMIT"
check "A3.clean" "$(git -C "$R" status --porcelain)" ""
check "A4.a_content" "$(cat "$R/a.txt")" "tip"
check "A5.c_created" "$([ -f "$R/c.txt" ] && echo yes || echo no)" "yes"
check "A6.index_blob" "$(git -C "$R" ls-files -s -- a.txt | awk '{print $2}')" "$(git -C "$R" rev-parse "$COMMIT:a.txt")"

# ---- B: real worktree modification -> refuse and preserve ------------------------- #
R2="$T/r2"; mkdir -p "$R2"; make_repo "$R2"; cas_applied "$R2"; printf 'user-edit\n' > "$R2/a.txt"
out="$("${PY[@]}" --mode sync --project "$R2" --base "$BASE" --final "$COMMIT" 2>&1)"; rc=$?
check_ne "B1.refused" "$rc" "0"
has 'worktree_edit_preserved' "$out" && echo "PASS B2.reason" || { echo "FAIL B2 reason: $out"; RC=1; }
check "B3.preserved" "$(cat "$R2/a.txt")" "user-edit"
check "B4.head_untouched" "$(git -C "$R2" rev-parse HEAD)" "$COMMIT"

# ---- C: Git query failure -> non-zero and zero restore ---------------------------- #
D="$T/notrepo"; mkdir -p "$D"; printf 'sentinel\n' > "$D/marker.txt"
out="$("${PY[@]}" --mode pre_cas --project "$D" --base "$BASE" --final "$COMMIT" 2>&1)"; rc=$?
check_ne "C1.query_failure_nonzero" "$rc" "0"
has 'command_failed' "$out" && echo "PASS C2.failure_propagated" || { echo "FAIL C2 reason: $out"; RC=1; }
check "C3.no_restore" "$(cat "$D/marker.txt")" "sentinel"

# ---- D: real staged modification, worktree at baseline -> refuse, index preserved -- #
R3="$T/r3"; mkdir -p "$R3"; make_repo "$R3"; cas_applied "$R3"
printf 'staged-diff\n' > "$R3/a.txt"; git -C "$R3" add a.txt
printf 'base\n' > "$R3/a.txt"                                   # worktree back to baseline
staged="$(git -C "$R3" ls-files -s -- a.txt | awk '{print $2}')"
out="$("${PY[@]}" --mode sync --project "$R3" --base "$BASE" --final "$COMMIT" 2>&1)"; rc=$?
check_ne "D1.refused" "$rc" "0"
has 'staged_edit_preserved' "$out" && echo "PASS D2.reason" || { echo "FAIL D2 reason: $out"; RC=1; }
check "D3.index_preserved" "$(git -C "$R3" ls-files -s -- a.txt | awk '{print $2}')" "$staged"
check "D4.worktree_preserved" "$(cat "$R3/a.txt")" "base"

# ---- E: continuation cleanup finds the original candidate and removes precisely --- #
R4="$T/r4"; mkdir -p "$R4"; make_repo "$R4"
EXT="$(mktemp -d /var/tmp/iap-smoke-promote-XXXXXX)"
git -C "$R4" worktree add --detach "$EXT/wt" "$COMMIT" >/dev/null 2>&1
: > "$EXT/candidate.bundle"
git -C "$R4" update-ref refs/aegl-candidate/t "$COMMIT"
REC="$T/rec-e.json"
printf '{"ext":"%s","bundle":"%s/candidate.bundle","commit":"%s","candidate_ref":"refs/aegl-candidate/t"}\n' \
  "$EXT" "$EXT" "$COMMIT" > "$REC"
out="$("${PY[@]}" --mode cleanup --project "$R4" --commit "$COMMIT" \
  --candidate-ref refs/aegl-candidate/t --record "$REC" 2>&1)"; rc=$?
check "E1.cleanup_rc" "$rc" "0"
has 'CLEANUP_DONE' "$out" && echo "PASS E2.done_marker" || { echo "FAIL E2: $out"; RC=1; }
git -C "$R4" show-ref --verify --quiet refs/aegl-candidate/t && { echo "FAIL E3 ref remains"; RC=1; } || echo "PASS E3.ref_removed"
check "E4.dir_removed" "$([ -e "$EXT" ] && echo exists || echo gone)" "gone"
check "E5.record_removed" "$([ -e "$REC" ] && echo exists || echo gone)" "gone"

# ---- F: unknown leftover -> non-zero, preserved, no CLEANUP_DONE ------------------ #
R5="$T/r5"; mkdir -p "$R5"; make_repo "$R5"
EXT2="$(mktemp -d /var/tmp/iap-smoke-promote-XXXXXX)"
git -C "$R5" worktree add --detach "$EXT2/wt" "$COMMIT" >/dev/null 2>&1
: > "$EXT2/candidate.bundle"
git -C "$R5" update-ref refs/aegl-candidate/t2 "$COMMIT"
REC2="$T/rec-f.json"
printf '{"ext":"%s","bundle":"%s/candidate.bundle","commit":"%s","candidate_ref":"refs/aegl-candidate/t2"}\n' \
  "$EXT2" "$EXT2" "$COMMIT" > "$REC2"
printf 'leftover\n' > "$EXT2/unknown.txt"
out="$("${PY[@]}" --mode cleanup --project "$R5" --commit "$COMMIT" \
  --candidate-ref refs/aegl-candidate/t2 --record "$REC2" 2>&1)"; rc=$?
check_ne "F1.cleanup_nonzero" "$rc" "0"
has 'leftovers_preserved' "$out" && echo "PASS F2.reason" || { echo "FAIL F2: $out"; RC=1; }
if printf '%s' "$out" | grep -q 'CLEANUP_DONE'; then echo "FAIL F3 falsely reported done"; RC=1; else echo "PASS F3.no_false_success"; fi
check "F4.leftover_preserved" "$(cat "$EXT2/unknown.txt" 2>/dev/null)" "leftover"

echo "SUMMARY rc=$RC"; exit "$RC"
