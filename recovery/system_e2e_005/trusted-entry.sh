#!/usr/bin/env bash
# trusted-entry.sh — SYSTEM-E2E-005 outer trusted entry (NO send, NO round, NO model).
#
#   sudo env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
#     LANG=C.UTF-8 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
#     bash /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_005/trusted-entry.sh
#
# Same outer shape as the 003/004 entry: copy the installation entry and every declared
# member into a root-private stage, verify each against a fixed hash, refuse links and
# undeclared members, run the pre-install gates, install ONLY the launcher candidate derived
# from the fixed predecessor, then run the staged prepare.sh and stop at its PREP_COMPLETE.
#
# The two reviewed transport fixes must already be installed: the dependency pins below are
# the post-install hashes and this entry fails closed before touching the launcher otherwise.
# Nothing is deleted, retried, rolled back or overwritten on failure.
set -euo pipefail
umask 077

SRC=/var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_005
BASE=/var/lib/aegl-model/prep-entry
TASK=SYSTEM-E2E-005
IAP=/home/zhong/AndroidStudioProjects/ImageAnalysisFactory
REGISTRY=/var/lib/aegl-model/registry.json
BRIDGE=/home/zhong/.local/state/google-android-agent-stack/bridge
JOURNAL="$BRIDGE/journal.jsonl"
STATE="$BRIDGE/state.json"
PENDING="$BRIDGE/pending_result.json"
STACK_BRIDGE=/var/tmp/IAP-CONTROL-DEV/stack/orchestration/hermes/bridge
RUN_ROOT=/run/aegl-model
TASK_ROOT=/var/tmp/SYSTEM-E2E-005
PKG_DEST=/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/SYSTEM-E2E-005
DIAG_ROOT=/var/tmp/aegl-diag
DIAG_SINK="$DIAG_ROOT/$TASK"
L=/usr/local/lib/aegl-model/aegl-hermes-sandbox
PREPARE_SHA=80fa5f09f94b4c559601f06d51795915b3167a1c16abb9887e2708ffd3a4c869
ACCEPT_SHA=9de90cdccbe160d0d2d6ec7d543deae7a8c8c872867d38071b05cfc313e09ebc
SOURCE_SHA=c04ead8893e324738ee28ab1cdc03f5ca5065e2b509abf1fb82f0cc5365e4b03
DEPS_SHA=d04358440144ae8a05657e057fe3bd608f48407f41b30e827cb17acfded89fd9
PRED_SHA=def13354e27797af82535c2bd1c9bbcb4acde4b6abec0004e2ce53fd2fe45ba6
CAND_SHA=a7c75e2d8277b0ebdcb7b467a7375ad1863086828f4a01e5bce55664e36865d3
MANIFEST_SHA=c5cf4264e3311cb6b28fbb411de8fa049aca55b11c9bb40f8b0b6f643944e036
PROMPT_SHA=57eb8fd879f56f28cebae1ead1458b4addeedc8c1684c693518dd6b9fb7507cc
AUX_COUNT=5

STAGE=""
LOG=""
fail() { echo "ENTRY_FAIL $1" >&2; exit 1; }
sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
OP_UID="$(id -u zhong 2>/dev/null)" || fail operator_missing
OP_GID="$(id -g zhong 2>/dev/null)" || fail operator_missing
OP_HOME="$(python3 -B -c 'import pwd,sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' zhong)" || fail operator_missing

[ "$(id -u)" -eq 0 ] || fail not_root

check_active() {
  local rc=0 entries prc=0
  if [ -e "$RUN_ROOT" ] || [ -L "$RUN_ROOT" ]; then
    [ ! -L "$RUN_ROOT" ] || fail run_dir_link
    [ -d "$RUN_ROOT" ] || fail run_dir_type
    entries="$(ls -A "$RUN_ROOT" 2>&1)" || rc=$?
    [ "$rc" -eq 0 ] || fail run_dir_unreadable
    [ -z "$entries" ] || fail run_dir_not_empty
  fi
  pgrep -f 'run_registered_task|aegl-hermes-sandbox|model_broker\.py|aegl-model-broker' >/dev/null 2>&1 || prc=$?
  case "$prc" in
    1) ;;
    0) fail active_task ;;
    *) fail process_probe_failed ;;
  esac
}

check_bridge() {
  [ -f "$STATE" ] || fail bridge_state_missing
  local status brc=0
  status="$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("status",""))' "$STATE" 2>/dev/null)" \
    || fail bridge_state_unreadable
  case "$status" in
    WAITING_FOR_GPT|IDLE) ;;
    *) fail bridge_not_idle ;;
  esac
  if [ -e "$PENDING" ] || [ -L "$PENDING" ]; then
    fail bridge_pending
  fi
  setpriv --reuid="$OP_UID" --regid="$OP_GID" --clear-groups --no-new-privs -- \
    env -i HOME="$OP_HOME" PATH="/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
      PYTHONDONTWRITEBYTECODE=1 \
      python3 -B - "$STACK_BRIDGE" "$BRIDGE" <<'PY' >/dev/null 2>&1 || brc=$?
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import bridge_state as bs
try:
    entries = bs.unresolved_accepted(Path(sys.argv[2]))
except Exception:
    raise SystemExit(2)
raise SystemExit(0 if not entries else 3)
PY
  case "$brc" in
    0) ;;
    3) fail bridge_unresolved ;;
    *) fail bridge_check_failed ;;
  esac
}

check_launcher_trusted() {
  local path="$1"
  [ -f "$path" ] && [ ! -L "$path" ] || fail launcher_not_regular
  [ "$(stat -c '%U:%G %a' "$path")" = "root:root 755" ] || fail launcher_owner_mode
}

check_predecessor_unchanged() {
  [ -f "$L" ] && [ ! -L "$L" ] || fail launcher_not_regular
  [ "$(sha "$L")" = "$PRED_SHA" ] || fail launcher_predecessor_changed
  check_launcher_trusted "$L"
}

check_dependencies() {
  ( cd "$STAGE" && sha256sum --strict -c DEPENDENCY-PINS.sha256 ) >/dev/null 2>&1 \
    || fail dependency_hash "transport fixes not installed (expected model_broker b9ff6a51, shim 40e71b3d)"
  local line path frc fout
  while IFS= read -r line; do
    path="${line#*  }"
    [ -f "$path" ] && [ ! -L "$path" ] || fail dependency_missing
    [ "$(stat -c '%u' "$path" 2>/dev/null)" = "0" ] || fail dependency_owner
    frc=0
    fout="$(find "$path" -maxdepth 0 -perm /022 -print -quit 2>&1)" || frc=$?
    [ "$frc" -eq 0 ] || fail dependency_probe_failed
    [ -z "$fout" ] || fail dependency_writable
  done < "$STAGE/DEPENDENCY-PINS.sha256"
}

check_aux_modes() { # the copied auxiliary scripts must satisfy prepare.sh's 0644 gate
  local dir="$STAGE/contract/$TASK/inputs/checks" i path n=0
  [ -d "$dir" ] && [ ! -L "$dir" ] || fail aux_dir
  for path in "$dir"/*; do
    [ -e "$path" ] || continue
    n=$((n + 1))
  done
  [ "$n" -eq "$AUX_COUNT" ] || fail aux_count "$n != $AUX_COUNT"
  for i in "$dir"/*.py; do
    [ -f "$i" ] && [ ! -L "$i" ] || fail aux_state "not a regular file"
    [ "$(stat -c '%a' "$i")" = "644" ] || fail aux_mode "$(basename "$i") $(stat -c '%a' "$i")"
  done
}

confirm_prep() {
  [ -f "$LOG" ] || fail prep_log_missing
  local expected
  expected="PREP_COMPLETE task=$TASK contract=$PKG_DEST manifest_sha256=$MANIFEST_SHA prompt_sha256=$PROMPT_SHA diag_sink=$DIAG_SINK launcher_sha256=$CAND_SHA"
  grep -Fxq -- "$expected" "$LOG" || fail prep_marker_mismatch
  echo "SYSTEM_E2E_005_PREP_CONFIRMED"
}

finish_prep() {
  local prep_rc="$1" tee_rc="$2"
  echo "ROOT_ENTRY_EXIT=$prep_rc TEE_EXIT=$tee_rc LOG=$LOG STAGE=$STAGE"
  if [ "$prep_rc" -ne 0 ] || [ "$tee_rc" -ne 0 ]; then
    echo "ENTRY_FAIL prep_or_log_failed prep_rc=$prep_rc tee_rc=$tee_rc" >&2
    if [ "$prep_rc" -ne 0 ]; then exit "$prep_rc"; else exit "$tee_rc"; fi
  fi
  confirm_prep
}

# --- root-private stage ---------------------------------------------------------------
[ ! -L "$BASE" ] || fail base_link
[ ! -e "$BASE" ] || [ -d "$BASE" ] || fail base_type
install -d -m 0700 -o root -g root "$BASE" || fail base_dir
STAGE="$(mktemp -d "$BASE/$TASK.XXXXXX")" || fail stage
echo "ROOT_STAGE=$STAGE"
LOG="$STAGE/prep.log"

# --- copy the installation entry + the four fixed files, then verify them --------------
# The entry cannot embed a hash of itself. What it can prove is that the staged copy is
# byte-identical to the file this process is actually running: capture that now, before any
# copy, and compare afterwards. The authoritative digest for the operator's own pre-run
# check is published in README.md.
RUNNING_SELF="$(realpath -e "$0" 2>/dev/null)" || fail entry_self_state
[ -f "$RUNNING_SELF" ] && [ ! -L "$RUNNING_SELF" ] || fail entry_self_state
RUNNING_SHA="$(sha "$RUNNING_SELF")"
[ -n "$RUNNING_SHA" ] || fail entry_self_hash
for f in trusted-entry.sh prepare.sh accept.py SOURCE.sha256 DEPENDENCY-PINS.sha256; do
  [ -f "$SRC/$f" ] && [ ! -L "$SRC/$f" ] || fail "missing_or_link $f"
done
for f in trusted-entry.sh prepare.sh accept.py SOURCE.sha256 DEPENDENCY-PINS.sha256; do
  cp --no-dereference -- "$SRC/$f" "$STAGE/$f"
done
printf '%s  accept.py\n%s  prepare.sh\n%s  SOURCE.sha256\n%s  DEPENDENCY-PINS.sha256\n' \
  "$ACCEPT_SHA" "$PREPARE_SHA" "$SOURCE_SHA" "$DEPS_SHA" \
  | ( cd "$STAGE" && sha256sum --strict -c - ) || fail entry_hash
[ "$(sha "$STAGE/trusted-entry.sh")" = "$RUNNING_SHA" ] || fail entry_copy_mismatch

# --- copy every declared member, refusing links and undeclared files -------------------
( cd "$SRC" && sha256sum --strict -c SOURCE.sha256 ) >/dev/null || fail source_members
EXPECTED="$STAGE.expected"; ACTUAL="$STAGE.actual"
printf '%s\n' SOURCE.sha256 accept.py prepare.sh DEPENDENCY-PINS.sha256 > "$EXPECTED"
while IFS= read -r line; do
  rel="${line#*  }"
  case "$rel" in
    ''|/*|*..*) fail "bad_member $rel" ;;
  esac
  [ -f "$SRC/$rel" ] && [ ! -L "$SRC/$rel" ] || fail "member $rel"
  mkdir -p "$STAGE/$(dirname "$rel")"
  cp --no-dereference -- "$SRC/$rel" "$STAGE/$rel"
  printf '%s\n' "$rel" >> "$EXPECTED"
done < "$STAGE/SOURCE.sha256"
( cd "$STAGE" && sha256sum --strict -c SOURCE.sha256 ) >/dev/null || fail copied_members
[ -z "$(find "$STAGE" -type l -print -quit)" ] || fail symlink_in_stage
sort -o "$EXPECTED" "$EXPECTED"
# trusted-entry.sh is this round's outer launcher, not a declared contract member; it is
# verified separately by the running-copy check below, so it is excluded from the member set.
( cd "$STAGE" && find . -type f -printf '%P\n' | grep -vxF trusted-entry.sh | sort ) > "$ACTUAL"
diff -u "$EXPECTED" "$ACTUAL" || fail undeclared_or_missing
rm -- "$EXPECTED" "$ACTUAL"

# `umask 077` above makes plain `cp` produce 0600. prepare.sh's auxiliary-input gate
# requires 0644 on the five scripts, and every copied member is root-owned read-only
# content, so the mode is normalised here rather than weakening that gate.
find "$STAGE" -type f ! -type l -exec chmod 0644 -- {} + || fail stage_chmod
[ "$(sha "$STAGE/prepare.sh")" = "$PREPARE_SHA" ] || fail staged_prepare_hash
[ "$(sha "$STAGE/accept.py")" = "$ACCEPT_SHA" ] || fail staged_accept_hash
[ "$(sha "$STAGE/trusted-entry.sh")" = "$RUNNING_SHA" ] || fail staged_entry_hash
check_aux_modes
echo "ENTRY_COPY_OK stage=$STAGE members=$(wc -l < "$STAGE/SOURCE.sha256")"

# --- pre-install gates: identity, scene, bridge, activity, run dir ---------------------
rc=0
python3 -B - "$REGISTRY" "$TASK" <<'PY' || rc=$?
import json, sys
try:
    registry = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(4)
raise SystemExit(3 if sys.argv[2] in registry else 0)
PY
case "$rc" in
  0) ;;
  3) fail identity_used ;;
  *) fail registry_query ;;
esac

rc=0
python3 -B - "$JOURNAL" "$TASK" <<'PY' || rc=$?
import json, sys
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        try:
            record = json.loads(line)
        except Exception:
            continue
        if record.get("task_id") == sys.argv[2]:
            raise SystemExit(3)
except OSError:
    raise SystemExit(4)
raise SystemExit(0)
PY
case "$rc" in
  0) ;;
  3) fail identity_used_journal ;;
  *) fail journal_query ;;
esac

check_bridge

for p in "$TASK_ROOT" "$PKG_DEST" "$DIAG_SINK" "$TASK_ROOT.tmp" "$PKG_DEST.tmp"; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    fail "scene_exists $p"
  fi
done
out=$(git -c safe.directory="$IAP" -C "$IAP" worktree list --porcelain 2>&1) || fail git_worktree
if printf '%s\n' "$out" | grep -qxF -- "worktree $TASK_ROOT/project"; then
  fail worktree_registered
fi

check_active
check_launcher_trusted "$L"
check_dependencies
echo "PREFLIGHT_OK identity_unused=1 scene_absent=1 bridge_idle=1 sink_absent=1"

# --- launcher: derive ONLY the 005 candidate from the fixed predecessor ----------------
cur="$(sha "$L")"
if [ "$cur" = "$CAND_SHA" ]; then
  echo "LAUNCHER_STATE=candidate"
elif [ "$cur" = "$PRED_SHA" ]; then
  echo "LAUNCHER_STATE=predecessor"
  [ ! -e "$L.new" ] && [ ! -L "$L.new" ] || fail launcher_staging_exists
  python3 -B - "$L" "$STAGE/launcher.candidate" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
assert data.count(b'SYSTEM-E2E-004 "') == 1
new = data.replace(b'SYSTEM-E2E-004 "', b'SYSTEM-E2E-004 SYSTEM-E2E-005 "', 1)
lines = data.splitlines(keepends=True)
new_lines = new.splitlines(keepends=True)
assert len(lines) == len(new_lines)
assert sum(1 for a, b in zip(lines, new_lines) if a != b) == 1
open(dst, "wb").write(new)
PY
  [ "$(sha "$STAGE/launcher.candidate")" = "$CAND_SHA" ] || fail candidate_hash
  install -o root -g root -m 0755 "$STAGE/launcher.candidate" "$L.new" || fail launcher_stage
  check_predecessor_unchanged
  check_launcher_trusted "$L.new"
  [ "$(sha "$L.new")" = "$CAND_SHA" ] || fail launcher_new_hash
  check_dependencies
  check_active
  mv -f "$L.new" "$L" || fail launcher_replace
  check_launcher_trusted "$L"
  [ "$(sha "$L")" = "$CAND_SHA" ] || fail launcher_installed_hash
  check_dependencies
else
  fail launcher_unknown
fi
grep -qF 'SYSTEM-E2E-005 ' "$L" || fail diag_entry_missing

# --- run prepare.sh FROM THE ROOT-PRIVATE COPY, keep both real exit codes --------------
set +e
bash "$STAGE/prepare.sh" 2>&1 | tee "$LOG"
pipeline_rc=("${PIPESTATUS[@]}")
set -e
finish_prep "${pipeline_rc[0]}" "${pipeline_rc[1]}"
