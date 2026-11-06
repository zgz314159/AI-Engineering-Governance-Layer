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
  bp="$B/PREP-BINDING.json"
  runs binding_write "$bp" "$B/wt" "$EXPECT_BASE" "$B/pkg" && ok binding_write_ok || no "binding_write failed"
  runs binding_accept "$bp" "$B/wt" "$EXPECT_BASE" "$B/pkg" && ok binding_accept_ok || no "binding_accept rejected its own file"
  before_sum="$(sha256sum "$bp")"
  runs binding_accept "$bp" "$B/wt" "0000000000000000000000000000000000000000" "$B/pkg" \
    && no "binding_accept accepted a wrong commit" || ok binding_accept_rejects_wrong_commit
  runs binding_accept "$bp" "$B/wt" "$EXPECT_BASE" "$B/other" \
    && no "binding_accept accepted a wrong contract_package" || ok binding_accept_rejects_wrong_contract
  [ "$(sha256sum "$bp")" = "$before_sum" ] && ok binding_file_bytes_unchanged || no "binding file was rewritten"
  runs binding_write "$bp" "$B/wt" "$EXPECT_BASE" "$B/pkg" \
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

# 7. root-only: verify_live_state rejects bad binding commit / mode / symlink -----------------
if [ "$(id -u)" -eq 0 ]; then
  S="$T/scene"; mkdir -p "$S/wt" "$S/pkg" "$S/scratch" "$S/ledger"; : > "$S/ledger/chain.before_prep"
  git -C "$S/wt" init -q -b main 2>/dev/null; git -C "$S/wt" -c user.name=t -c user.email=t@x commit -q --allow-empty -m base
  TASK_ROOT="$S"; WORKTREE="$S/wt"; SCRATCH="$S/scratch"; LEDGER="$S/ledger"; PKG_DEST="$S/pkg"
  printf 'anchor=x\n' > "$S/pkg/manifest.json"
  cp "$S/pkg/manifest.json" "$S/pkg/keep.json"
  printf '{"worktree":"%s","commit":"%s","contract_package":"%s"}\n' "$S/wt" "$EXPECT_BASE" "$S/pkg" > "$S/PREP-BINDING.json"
  chmod 0644 "$S/PREP-BINDING.json"
  runs verify_live_state && no "verify_live_state accepted a wrong commit" || ok live_rejects_wrong_commit
  ln -sf "$S/PREP-BINDING.json" "$S/link.json"
  runs binding_accept "$S/link.json" "$S/wt" "$EXPECT_BASE" "$S/pkg" && no "symlink accepted" || ok live_rejects_symlink
  chmod 0666 "$S/PREP-BINDING.json"
  runs binding_accept "$S/PREP-BINDING.json" "$S/wt" "$EXPECT_BASE" "$S/pkg" && no "bad mode accepted" || ok live_rejects_bad_mode
else
  printf 'NOT_RUN verify_live_state rejection cases (needs root)\n'
fi

printf 'FIXTURES pass=%d fail=%d\n' "$pass" "$fail"
exit "$fail"
