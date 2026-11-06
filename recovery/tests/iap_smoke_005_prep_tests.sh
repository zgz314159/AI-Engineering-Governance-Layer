#!/usr/bin/env bash
# iap_smoke_005_prep_tests.sh — isolated tests for the IAP-SMOKE-005 prep entry.
# Run from a staged package copy:  bash tests/iap_smoke_005_prep_tests.sh
# Calls the REAL functions of the frozen driver. No real Bridge write, no 005 prep, no model.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HERE/../bin/run_smoke.sh"          # frozen-package layout
[ -f "$D" ] || { echo "MISSING $D (run the suite from a staged package copy)"; exit 1; }
# Child entry — ABOVE mktemp: the child allocates nothing; it uses the parent's isolated
# fixture. Source the verified driver FIRST, then bind the explicit positionals, then call
# the real function bare under set -Eeuo pipefail (never eval, never a variable name).
#   --child <IAP> <TASK_ROOT> <WORKTREE> <SCRATCH> <LEDGER> <PKG_DEST> <REGISTRY>
#           <EXPECT_BASE> <EXPECT_MANIFEST_SHA> <fn> [args...]
if [ "${1:-}" = "--child" ]; then
  shift
  # shellcheck disable=SC1090
  source "$D" || { echo SOURCE_FAILED; exit 1; }
  IAP="$1"; TASK_ROOT="$2"; WORKTREE="$3"; SCRATCH="$4"; LEDGER="$5"
  PKG_DEST="$6"; REGISTRY="$7"; EXPECT_BASE="$8"; EXPECT_MANIFEST_SHA="$9"
  shift 9
  set -Eeuo pipefail
  "$@"
  exit 0
fi

T="$(mktemp -d /var/tmp/aegl-005-tests.XXXXXX)"
# Records are written while the fixture is created; cleanup never rescans the tree.
CLEAN_FILES="$T.cleanup-files"; CLEAN_DIRS="$T.cleanup-dirs"
: > "$CLEAN_FILES"; : > "$CLEAN_DIRS"
record_file() { printf '%s\n' "$1" >> "$CLEAN_FILES"; }
record_dir() { printf '%s\n' "$1" >> "$CLEAN_DIRS"; }
record_tree() { local root="$1"; find "$root" -type f >> "$CLEAN_FILES"; find "$root" -depth -type d >> "$CLEAN_DIRS"; }

pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
runs() { ( "$@" ) >/dev/null 2>&1; }   # sub-shell: die() must not kill the suite

export SMOKE_ALLOW_NONROOT=1 LEDGER="$T/ledger"
mkdir -p "$LEDGER"; record_dir "$LEDGER"
# shellcheck disable=SC1090
source "$D" || { echo SOURCE_FAILED; exit 1; }
# as_op drops to the operator, so it must be able to traverse/read THIS temp dir only
if [ "$(id -u)" -eq 0 ]; then chmod 0755 "$T"; fi

# --- fixtures: real state.json / pending / registry, under $T ---------------------------
BRIDGE_DIR="$T/bridge"; mkdir -p "$BRIDGE_DIR"; record_dir "$BRIDGE_DIR"
if [ "$(id -u)" -eq 0 ]; then chmod 0755 "$BRIDGE_DIR"; fi
PENDING_PATH="$T/pending_result.json"
state() { # <status> <seq> <nonce> <in_reply_to>
  printf '{"status":"%s","expected_sequence":%s,"expected_nonce":"%s","expected_in_reply_to":"%s"}\n' \
    "$1" "$2" "$3" "$4" > "$BRIDGE_DIR/state.json"
  chmod 0644 "$BRIDGE_DIR/state.json"
}
record_file "$BRIDGE_DIR/state.json"
REGISTRY_PATH="$T/reg.json"; record_file "$REGISTRY_PATH"
python3 - "$REGISTRY_PATH" <<'PY'
import json, sys
json.dump({"IAP-SMOKE-005": {
    "worktree": "/var/tmp/IAP-SMOKE-005/project",
    "scratch": "/var/tmp/IAP-SMOKE-005/scratch",
    "project": "/home/zhong/AndroidStudioProjects/ImageAnalysisFactory",
    "contract_package": "/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/IAP-SMOKE-005"}},
    open(sys.argv[1], "w"))
PY

# 1. REAL chain_now + REAL bridge_ok against the same real state file --------------------
state WAITING_FOR_GPT 9 NONCE_A REPLY_A
cn="$(chain_now)"
[ "$cn" = "seq=9 nonce=NONCE_A in_reply_to=REPLY_A" ] && ok chain_now_format_unchanged || no "chain_now format: $cn"
bridge_ok && ok bridge_ok_accepts_expected_state || no "bridge_ok rejected the expected state"
state WAITING_FOR_GPT 8 NONCE_A REPLY_A; bridge_ok && no "bridge_ok accepted seq=8" || ok bridge_ok_rejects_wrong_seq
state WAITING_FOR_GPT 9 NONCE_A REPLY_A; : > "$PENDING_PATH"; record_file "$PENDING_PATH"
bridge_ok && no "bridge_ok accepted a pending result" || ok bridge_ok_rejects_pending
rm -f "$PENDING_PATH"
state WORKING 9 NONCE_A REPLY_A; bridge_ok && no "bridge_ok accepted status=WORKING" || ok bridge_ok_rejects_wrong_status

# 2. a nonce / in_reply_to CHANGE during prep must be rejected ---------------------------
state WAITING_FOR_GPT 9 NONCE_A REPLY_A
chain_now > "$LEDGER/chain.before_prep"; record_file "$LEDGER/chain.before_prep"
state WAITING_FOR_GPT 9 NONCE_B REPLY_A
cur="$(chain_now)"; [ "$cur" != "$(cat "$LEDGER/chain.before_prep")" ] \
  && ok chain_change_detected || no "nonce change not detected"
state WAITING_FOR_GPT 9 NONCE_A REPLY_B
cur="$(chain_now)"; [ "$cur" != "$(cat "$LEDGER/chain.before_prep")" ] \
  && ok reply_change_detected || no "in_reply_to change not detected"
state WAITING_FOR_GPT 9 NONCE_A REPLY_A
[ "$(chain_now)" = "$(cat "$LEDGER/chain.before_prep")" ] && ok unchanged_chain_matches || no "unchanged chain mismatch"

# 3. REAL binding generation + acceptance (own directory B1; root only) ---------------------
if [ "$(id -u)" -eq 0 ]; then
  B1="$T/binding1"
  mkdir -p "$B1/wt" "$B1/pkg" "$B1/other"
  record_dir "$B1"; record_dir "$B1/wt"; record_dir "$B1/pkg"; record_dir "$B1/other"
  bp="$B1/PREP-BINDING.json"; record_file "$bp"
  binding_write "$bp" "$B1/wt" "$EXPECT_BASE" "$B1/pkg" && ok binding_write_ok || no binding_write_failed
  binding_accept "$bp" "$B1/wt" "$EXPECT_BASE" "$B1/pkg" && ok binding_accept_ok || no binding_accept_failed
  before_sum="$(sha256sum "$bp")"
  runs binding_accept "$bp" "$B1/wt" 0000000000000000000000000000000000000000 "$B1/pkg" \
    && no "wrong commit accepted" || ok binding_rejects_wrong_commit
  runs binding_accept "$bp" "$B1/wt" "$EXPECT_BASE" "$B1/other" \
    && no "wrong contract accepted" || ok binding_rejects_wrong_contract
  [ "$(sha256sum "$bp")" = "$before_sum" ] && ok binding_bytes_unchanged || no "binding rewritten"
  runs binding_write "$bp" "$B1/wt" "$EXPECT_BASE" "$B1/pkg"     && no "existing binding overwritten" || ok binding_write_refuses_overwrite
else
  printf 'NOT_RUN binding base cases (needs root)\n'
fi

# 4. ONE live fixture (everything under $B/pkg consistent), then one change per case ---------
# The fixture paths are fixed here in the parent, so cleanup never depends on a subshell
# variable coming back from live_group.
LIVE_PATH="$T/live"
FIX_IAP="$LIVE_PATH/formal"; FIX_TASK_ROOT="$LIVE_PATH"; FIX_WT="$LIVE_PATH/project"
FIX_SC="$LIVE_PATH/scratch"; FIX_LG="$LIVE_PATH/ledger"; FIX_PK="$LIVE_PATH/pkg"
FIX_REG="$T/fixreg.json"; FIX_LINK="$LIVE_PATH/link.json"

child_at() { # <want|-> <iap> <task_root> <worktree> <scratch> <ledger> <pkg_dest> <registry> <expect_base> <expect_manifest> <fn> [args...]
  local want="$1"; shift
  local iap="$1" tr="$2" wt="$3" sc="$4" lg="$5" pk="$6" reg="$7" eb="$8" em="$9"
  shift 9
  local err rc=0
  err="$( bash "$0" --child "$iap" "$tr" "$wt" "$sc" "$lg" "$pk" "$reg" "$eb" "$em" "$@" 2>&1 >/dev/null )" || rc=$?
  [ "$rc" -ne 0 ] || { printf '  (rc=0, expected a real non-zero exit)\n'; return 1; }
  [ "$want" = "-" ] || grep -qF -- "reason=$want" <<< "$err" || { printf '  (reason mismatch: %s)\n' "$err"; return 1; }
  return 0
}
child() { child_at "$1" "$FIX_IAP" "$FIX_TASK_ROOT" "$FIX_WT" "$FIX_SC" "$FIX_LG" "$FIX_PK" "$FIX_REG" "$FIXHEAD" "$FIXMAN" "${@:2}"; }

live_group() {   # isolated: cannot pollute the later registry cases
  local lp=0 lf=0
  ok() { lp=$((lp + 1)); printf 'PASS %s\n' "$1"; }
  no() { lf=$((lf + 1)); printf 'FAIL %s\n' "$1"; }
  if [ "$(id -u)" -ne 0 ]; then
    printf 'NOT_RUN live-fixture + registry cases (needs root)\n'
    printf 'LIVE_RESULT pass=%d fail=%d\n' "$lp" "$lf"
    return 0
  fi
  set -Eeuo pipefail
  B="$FIX_TASK_ROOT"
  mkdir -p "$B/scratch" "$B/ledger" "$B/pkg"
  record_dir "$B"; record_dir "$B/scratch"; record_dir "$B/ledger"; record_dir "$B/pkg"
  IAP="$FIX_IAP"; mkdir -p "$IAP"; record_dir "$IAP"
  git -C "$IAP" init -q -b main || { echo GIT_FIXTURE_FAILED; return 1; }
  printf 'plan\n' > "$IAP/PLAN.md"; record_file "$IAP/PLAN.md"
  git -C "$IAP" add PLAN.md || { echo GIT_FIXTURE_FAILED; return 1; }
  git -C "$IAP" -c user.name=t -c user.email=t@x commit -q -m base || { echo GIT_FIXTURE_FAILED; return 1; }
  WORKTREE="$FIX_WT"
  git -C "$IAP" worktree add -q "$WORKTREE" -b wt || { echo GIT_FIXTURE_FAILED; return 1; }
  printf 'tracked\n' >> "$WORKTREE/PLAN.md"
  git -C "$WORKTREE" -c user.name=t -c user.email=t@x commit -q -am tracked || { echo GIT_FIXTURE_FAILED; return 1; }
  FIXHEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
  { git -C "$WORKTREE" rev-parse --absolute-git-dir; \
    git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir; } > "$B/ledger/paths"
  record_file "$B/ledger/paths"
  printf 'anchor=%s stage=preflight\n' "$ANCHOR" > "$B/ledger/preflight.done"
  record_file "$B/ledger/preflight.done"
  printf 'a\n' > "$B/pkg/A.md"; printf 'b\n' > "$B/pkg/B.md"
  record_file "$B/pkg/A.md"; record_file "$B/pkg/B.md"
  printf '{"contract_id":"FIXTURE"}\n' > "$B/pkg/implementation-contract.json"
  record_file "$B/pkg/implementation-contract.json"
  python3 - "$B/pkg" <<'PY'
import hashlib, json, os, sys
pkg = sys.argv[1]
names = ("A.md", "B.md", "implementation-contract.json")
json.dump({"package": "FIXTURE", "entries": [
    {"path": n, "sha256": hashlib.sha256(open(os.path.join(pkg, n), "rb").read()).hexdigest()} for n in names]},
    open(os.path.join(pkg, "manifest.json"), "w"))
PY
  record_file "$B/pkg/manifest.json"
  FIXMAN="$(sha256sum "$B/pkg/manifest.json" | awk '{print $1}')"
  python3 - "$FIX_REG" "$B" "$IAP" <<'PY'
import json, sys
b, iap = sys.argv[2], sys.argv[3]
json.dump({"IAP-SMOKE-005": {"worktree": b + "/project", "scratch": b + "/scratch",
    "project": iap, "contract_package": b + "/pkg"}}, open(sys.argv[1], "w"))
PY
  record_file "$FIX_REG"
  TASK_ROOT="$B"; SCRATCH="$B/scratch"; LEDGER="$B/ledger"; PKG_DEST="$B/pkg"
  REGISTRY="$FIX_REG"; EXPECT_BASE="$FIXHEAD"; EXPECT_MANIFEST_SHA="$FIXMAN"
  binding_write "$B/PREP-BINDING.json" "$WORKTREE" "$FIXHEAD" "$PKG_DEST" || { echo BINDING_FIXTURE_FAILED; return 1; }
  binding_accept "$B/PREP-BINDING.json" "$WORKTREE" "$FIXHEAD" "$PKG_DEST" || { echo BINDING_FIXTURE_FAILED; return 1; }
  record_file "$B/PREP-BINDING.json"
  # the fixture is complete now: record every file and generated Git-metadata directory
  record_tree "$B"
  # the valid fixture MUST pass first; a non-zero child exit stops the group immediately
  local vo
  if ! vo="$( bash "$0" --child "$FIX_IAP" "$FIX_TASK_ROOT" "$FIX_WT" "$FIX_SC" "$FIX_LG" \
       "$FIX_PK" "$FIX_REG" "$FIXHEAD" "$FIXMAN" verify_live_state 2>&1 )"; then
    printf 'VALID_FIXTURE_REJECTED: %s\n' "$vo"; return 1
  fi
  record_file "$FIX_LG/live.status.err"
  ok live_valid_fixture_passes
  child binding_mismatch binding_accept "$B/PREP-BINDING.json" "$FIX_WT" 0000000000000000000000000000000000000000 "$FIX_PK" \
    && ok live_rejects_wrong_commit || no "wrong commit not rejected as binding_mismatch"
  chmod 0666 "$B/PREP-BINDING.json"
  child binding_mode binding_accept "$B/PREP-BINDING.json" "$FIX_WT" "$FIXHEAD" "$FIX_PK" \
    && ok binding_rejects_bad_mode || no "bad mode not rejected as binding_mode"
  chmod 0644 "$B/PREP-BINDING.json"; ln -sf "$B/PREP-BINDING.json" "$FIX_LINK"; record_file "$FIX_LINK"
  child binding_symlink binding_accept "$FIX_LINK" "$FIX_WT" "$FIXHEAD" "$FIX_PK" \
    && ok binding_rejects_symlink || no "symlink not rejected as binding_symlink"
  printf 'dirty\n' >> "$FIX_WT/PLAN.md"
  child live_worktree_dirty verify_live_state && ok live_rejects_dirty_worktree || no "dirty worktree not rejected"
  git -C "$FIX_WT" checkout -q -- PLAN.md
  # empty/bad-registry cases get their OWN scene (paths that do not exist for this case)
  printf '{}\n' > "$T/reg-empty.json"; record_file "$T/reg-empty.json"
  printf '{bad json\n' > "$T/reg-bad.json"; record_file "$T/reg-bad.json"
  local rc err
  rc=0; err="$( bash "$0" --child "$FIX_IAP" "$T/none/tr" "$T/none/wt" "$T/none/sc" "$T/none/lg" \
              "$T/none/pk" "$T/reg-empty.json" "$FIXHEAD" "$FIXMAN" verify_existing_scene 2>&1 >/dev/null )" || rc=$?
  [ "$rc" -eq 0 ] && ok existing_scene_valid_empty_registry || no "valid {} rejected: $err"
  rc=0; err="$( bash "$0" --child "$FIX_IAP" "$T/none/tr" "$T/none/wt" "$T/none/sc" "$T/none/lg" \
              "$T/none/pk" "$T/reg-bad.json" "$FIXHEAD" "$FIXMAN" verify_existing_scene 2>&1 >/dev/null )" || rc=$?
  if [ "$rc" -ne 0 ] && grep -qF 'reason=existing_registry_unreadable' <<< "$err"; then
    ok existing_scene_bad_registry_rejected
  else
    no "bad JSON wrong rc/reason (rc=$rc): $err"
  fi
  printf 'LIVE_RESULT pass=%d fail=%d\n' "$lp" "$lf"
  [ "$lf" -eq 0 ]
}

LIVE_OUT="$( live_group 2>&1 )"; LIVE_RC=$?
printf '%s\n' "$LIVE_OUT" | grep -v '^LIVE_RESULT ' || true
lres="$(printf '%s\n' "$LIVE_OUT" | sed -n 's/^LIVE_RESULT pass=\([0-9][0-9]*\) fail=\([0-9][0-9]*\)$/\1 \2/p' | tail -n 1)"
lpass=0; lfail=0
if [ -n "$lres" ]; then lpass="${lres% *}"; lfail="${lres#* }"; fi
pass=$((pass + lpass)); fail=$((fail + lfail))
if [ "$LIVE_RC" -ne 0 ]; then
  # a non-zero group exit is ALWAYS a failure; the printed lines only locate it
  [ "$lfail" -gt 0 ] || fail=$((fail + 1))
  printf 'FAIL live_group_rc=%d (scene kept)\n' "$LIVE_RC"
fi

# 4. registry: four exact fields, read failure stops --------------------------------------
REGISTRY="$REGISTRY_PATH"
runs registry_fields_ok IAP-SMOKE-005 && ok registry_four_fields_match || no "registry fixture rejected: ${REGISTRY_DIFF:-}"
python3 - "$REGISTRY_PATH" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["IAP-SMOKE-005"]["scratch"] = "/var/tmp/IAP-SMOKE-005/WRONG"
json.dump(d, open(sys.argv[1], "w"))
PY
runs registry_fields_ok IAP-SMOKE-005 && no "registry mismatch accepted" || ok registry_mismatch_rejected
REGISTRY="$T/does-not-exist.json"
runs registry_fields_ok IAP-SMOKE-005 && no "unreadable registry accepted" || ok registry_read_failure_stops
REGISTRY="$REGISTRY_PATH"

# 5. stale/old done markers must not skip the pre-install Bridge gate ---------------------
printf 'anchor=STALE stage=preflight\n' > "$LEDGER/preflight.done"
record_file "$LEDGER/preflight.done"
done_marker preflight && no "stale marker accepted" || ok old_marker_not_trusted
grep -q 'local force=" preflight verify_live_state "' "$D" && ok preflight_always_runs || no "preflight not force-run"
if sed -n '/^stage_preflight()/,/^}/p' "$D" | grep -q 'bridge_ok || die bridge_before_writes'; then
  ok bridge_gate_before_writes
else
  no "no Bridge gate in preflight"
fi
grep -q 'chain.before_prep' "$D" && ok prep_start_snapshot_used || no "no prep-start snapshot"

# 6. removed legacy code / baseline verify-only -------------------------------------------
! grep -q 'grant_approved_traverse\|TRAVERSE_APPROVED' "$D" && ok legacy_traversal_gone || no "legacy traversal code present"
! grep -qE 'op_git (init|add|commit)|stage_repair_git_owner' "$D" && ok baseline_verify_only || no "baseline create/repair present"

printf 'FIXTURES pass=%d fail=%d\n' "$pass" "$fail"
if [ "$fail" -ne 0 ]; then
  printf 'SCENE_KEPT=%s\n' "$T"
  printf 'SUITE_RC=%d\n' "$fail"
  exit "$fail"
fi

# Only after every applicable test passed: normal worktree removal, then exactly the
# recorded files, then the recorded (now empty) directories, then $T itself.
cleanup_scene() {
  if [ -d "$FIX_WT" ] && [ -e "$FIX_IAP/.git" ]; then
    git -C "$FIX_IAP" worktree remove "$FIX_WT" || { echo "CLEANUP_FAILED worktree $FIX_WT"; return 1; }
  fi
  local f
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -L "$f" ] || [ -e "$f" ] || continue
    if [ -d "$f" ] && [ ! -L "$f" ]; then echo "CLEANUP_FAILED unexpected directory $f"; return 1; fi
    rm -f -- "$f" || { echo "CLEANUP_FAILED $f"; return 1; }
  done < "$CLEAN_FILES"
  local d
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -d "$d" ] || continue
    rmdir -- "$d" || { echo "CLEANUP_FAILED directory not empty: $d"; return 1; }
  done < <(sort -r "$CLEAN_DIRS" | awk '!seen[$0]++')
  rmdir -- "$T" || { echo "CLEANUP_FAILED $T (unrecorded content remains)"; return 1; }
  rm -f -- "$CLEAN_FILES" "$CLEAN_DIRS" || { echo "CLEANUP_FAILED records"; return 1; }
  return 0
}

if cleanup_scene; then
  printf 'TEST_TMP_CLEANED=%s\n' "$T"
  printf 'SUITE_RC=0\n'
else
  printf 'SCENE_KEPT=%s\n' "$T"
  printf 'SUITE_RC=1\n'
  exit 1
fi
exit 0
