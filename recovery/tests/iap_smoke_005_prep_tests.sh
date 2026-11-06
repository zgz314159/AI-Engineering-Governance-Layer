#!/usr/bin/env bash
# iap_smoke_005_prep_tests.sh — isolated tests for the IAP-SMOKE-005 prep entry.
# Run:  bash recovery/tests/iap_smoke_005_prep_tests.sh
# Calls the REAL functions of the frozen driver. No real Bridge write, no 005 prep, no model.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
D="$HERE/../bin/run_smoke.sh"          # frozen-package layout
[ -f "$D" ] || { echo "MISSING $D (run the suite from a staged package copy)"; exit 1; }
T="$(mktemp -d /var/tmp/aegl-005-tests.XXXXXX)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'PASS %s\n' "$1"; }
no() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
runs() { ( "$@" ) >/dev/null 2>&1; }   # sub-shell: die() must not kill the suite

export SMOKE_ALLOW_NONROOT=1 LEDGER="$T/ledger"
mkdir -p "$LEDGER"
# shellcheck disable=SC1090
source "$D" || { echo SOURCE_FAILED; exit 1; }
# as_op drops to the operator, so it must be able to traverse/read THIS temp dir only
if [ "$(id -u)" -eq 0 ]; then chmod 0755 "$T"; mkdir -p "$T/bridge"; chmod 0755 "$T/bridge"; fi

# --- fixtures: real state.json / pending / registry, under $T ---------------------------
BRIDGE_DIR="$T/bridge"; mkdir -p "$BRIDGE_DIR"
PENDING_PATH="$T/pending_result.json"
state() { # <status> <seq> <nonce> <in_reply_to>
  printf '{"status":"%s","expected_sequence":%s,"expected_nonce":"%s","expected_in_reply_to":"%s"}\n' \
    "$1" "$2" "$3" "$4" > "$BRIDGE_DIR/state.json"
}
REGISTRY_PATH="$T/reg.json"
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
state WAITING_FOR_GPT 9 NONCE_A REPLY_A; : > "$PENDING_PATH"
bridge_ok && no "bridge_ok accepted a pending result" || ok bridge_ok_rejects_pending
rm -f "$PENDING_PATH"
state WORKING 9 NONCE_A REPLY_A; bridge_ok && no "bridge_ok accepted status=WORKING" || ok bridge_ok_rejects_wrong_status

# 2. a nonce / in_reply_to CHANGE during prep must be rejected ---------------------------
state WAITING_FOR_GPT 9 NONCE_A REPLY_A
chain_now > "$LEDGER/chain.before_prep"
state WAITING_FOR_GPT 9 NONCE_B REPLY_A
cur="$(chain_now)"; [ "$cur" != "$(cat "$LEDGER/chain.before_prep")" ] \
  && ok chain_change_detected || no "nonce change not detected"
state WAITING_FOR_GPT 9 NONCE_A REPLY_B
cur="$(chain_now)"; [ "$cur" != "$(cat "$LEDGER/chain.before_prep")" ] \
  && ok reply_change_detected || no "in_reply_to change not detected"
state WAITING_FOR_GPT 9 NONCE_A REPLY_A
[ "$(chain_now)" = "$(cat "$LEDGER/chain.before_prep")" ] && ok unchanged_chain_matches || no "unchanged chain mismatch"

# 3. REAL binding generation then REAL acceptance (isolated dir) --------------------------
# binding_write/binding_accept assert root:root 0644, so this block is only meaningful
# as root. Run the suite with sudo to exercise it.
if [ "$(id -u)" -eq 0 ]; then
  B1="$T/binding1"; mkdir -p "$B1/wt" "$B1/pkg" "$B1/other"   # created BEFORE first use
  bp="$B1/PREP-BINDING.json"
  runs binding_write "$bp" "$B1/wt" "$EXPECT_BASE" "$B1/pkg" && ok binding_write_ok || no "binding_write failed"
  runs binding_accept "$bp" "$B1/wt" "$EXPECT_BASE" "$B1/pkg" && ok binding_accept_ok || no "binding_accept rejected its own file"
  before_sum="$(sha256sum "$bp")"
  runs binding_accept "$bp" "$B1/wt" "0000000000000000000000000000000000000000" "$B1/pkg" \
    && no "binding_accept accepted a wrong commit" || ok binding_accept_rejects_wrong_commit
  runs binding_accept "$bp" "$B1/wt" "$EXPECT_BASE" "$B1/other" \
    && no "binding_accept accepted a wrong contract_package" || ok binding_accept_rejects_wrong_contract
  [ "$(sha256sum "$bp")" = "$before_sum" ] && ok binding_file_bytes_unchanged || no "binding file was rewritten"
  runs binding_write "$bp" "$B1/wt" "$EXPECT_BASE" "$B1/pkg" \
    && no "binding_write overwrote an existing binding" || ok binding_write_refuses_overwrite

else
  printf 'SKIP binding_write_ok (needs root)\n'; printf 'SKIP binding_accept_ok (needs root)\n'
  printf 'SKIP binding_accept_rejects_wrong_commit (needs root)\n'
  printf 'SKIP binding_accept_rejects_wrong_contract (needs root)\n'
  printf 'SKIP binding_file_bytes_unchanged (needs root)\n'
  printf 'SKIP binding_write_refuses_overwrite (needs root)\n'
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

# 7. root-only: a COMPLETE valid fixture, then ONE change per case -----------------------------
if [ "$(id -u)" -eq 0 ]; then
  B="$T/live"
  mkdir -p "$B/scratch" "$B/ledger" "$B1/pkg"
  # an isolated "formal" repo + a REAL registered worktree, so nothing depends on the host tree
  IAP="$B/formal"; mkdir -p "$IAP"
  git -C "$IAP" init -q -b main || { echo GIT_FIXTURE_FAILED; exit 1; }
  printf 'plan\n' > "$IAP/PLAN.md"
  git -C "$IAP" add PLAN.md || { echo GIT_FIXTURE_FAILED; exit 1; }
  git -C "$IAP" -c user.name=t -c user.email=t@x commit -q -m base || { echo GIT_FIXTURE_FAILED; exit 1; }
  WORKTREE="$B/project"
  git -C "$IAP" worktree add -q "$WORKTREE" -b wt || { echo GIT_FIXTURE_FAILED; exit 1; }
  FIXHEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
  printf 'tracked\n' > "$WORKTREE/PLAN.md"
  git -C "$WORKTREE" -c user.name=t -c user.email=t@x commit -q -am tracked || { echo GIT_FIXTURE_FAILED; exit 1; }
  FIXHEAD="$(git -C "$WORKTREE" rev-parse HEAD)"
  git -C "$WORKTREE" rev-parse --absolute-git-dir > "$B/ledger/paths"
  git -C "$WORKTREE" rev-parse --path-format=absolute --git-common-dir >> "$B/ledger/paths"
  printf 'anchor=%s stage=preflight\n' "$ANCHOR" > "$B/ledger/preflight.done"
  printf 'main\n' > "$B/pkg/A.md"; printf 'b\n' > "$B/pkg/B.md"
  printf '{"contract_id":"FIXTURE"}\n' > "$B/pkg/implementation-contract.json"
  python3 - "$B1/pkg" <<'PY'
import hashlib, json, os, sys
pkg = sys.argv[1]
names = ("A.md", "B.md", "implementation-contract.json")
json.dump({"package": "FIXTURE", "entries": [
    {"path": n, "sha256": hashlib.sha256(open(os.path.join(pkg, n), "rb").read()).hexdigest()} for n in names]},
    open(os.path.join(pkg, "manifest.json"), "w"))
PY
  python3 - "$T/fixreg.json" "$B" "$IAP" <<'PY'
import json, sys
b, iap = sys.argv[2], sys.argv[3]
json.dump({"IAP-SMOKE-005": {"worktree": b + "/project", "scratch": b + "/scratch",
    "project": iap, "contract_package": b + "/pkg"}}, open(sys.argv[1], "w"))
PY
  TASK_ROOT="$B"; SCRATCH="$B/scratch"; LEDGER="$B/ledger"; PKG_DEST="$B1/pkg"
  REGISTRY="$T/fixreg.json"; EXPECT_BASE="$FIXHEAD"
  EXPECT_MANIFEST_SHA="$(sha256sum "$B/pkg/manifest.json" | awk '{print $1}')"
  binding_write "$B/PREP-BINDING.json" "$WORKTREE" "$FIXHEAD" "$PKG_DEST" || { echo BINDING_FIXTURE_FAILED; exit 1; }
  binding_accept "$B/PREP-BINDING.json" "$WORKTREE" "$FIXHEAD" "$PKG_DEST" || { echo BINDING_FIXTURE_FAILED; exit 1; }
  runs_reason() { local want="$1"; shift; local err; err="$( ( "$@" ) 2>&1 >/dev/null )";     printf '%s' "$err" | grep -q "reason=$want" && return 0; printf '  (got: %s)\n' "$err"; return 1; }
  runs verify_live_state && ok live_valid_fixture_passes || no "valid fixture rejected by verify_live_state"
  runs_reason binding_mismatch binding_accept "$B/PREP-BINDING.json" "$WORKTREE" "0000000000000000000000000000000000000000" "$PKG_DEST" \
    && ok live_rejects_wrong_commit || no "wrong commit not rejected as binding_mismatch"
  chmod 0666 "$B/PREP-BINDING.json"
  runs_reason binding_mode binding_accept "$B/PREP-BINDING.json" "$WORKTREE" "$FIXHEAD" "$PKG_DEST" \
    && ok binding_rejects_bad_mode || no "bad mode not rejected as binding_mode"
  chmod 0644 "$B/PREP-BINDING.json"; ln -sf "$B/PREP-BINDING.json" "$B/link.json"
  runs_reason binding_symlink binding_accept "$B/link.json" "$WORKTREE" "$FIXHEAD" "$PKG_DEST" \
    && ok binding_rejects_symlink || no "symlink not rejected as binding_symlink"
  printf 'dirty\n' >> "$WORKTREE/PLAN.md"
  runs_reason live_worktree_dirty verify_live_state && ok live_rejects_dirty_worktree || no "dirty worktree not rejected"
  git -C "$WORKTREE" checkout -q -- PLAN.md
else
  printf 'NOT_RUN live-fixture rejection cases (needs root)\n'
fi

if [ "$(id -u)" -eq 0 ]; then
  E="$T/scene"; mkdir -p "$E"; printf '{}\n' > "$E/reg-empty.json"
  REGISTRY="$E/reg-empty.json"
  runs verify_existing_scene && ok existing_scene_valid_empty_registry || no "empty valid registry rejected"
  printf '{not json\n' > "$E/reg-bad.json"; REGISTRY="$E/reg-bad.json"
  runs_reason existing_registry_unreadable verify_existing_scene && ok existing_scene_bad_registry_rejected || no "bad JSON registry not rejected"
else
  printf 'NOT_RUN verify_existing_scene cases (needs root)\n'
fi

printf 'FIXTURES pass=%d fail=%d\n' "$pass" "$fail"
exit "$fail"
