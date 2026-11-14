# SYSTEM-E2E-003 — two-call authoring draft with trusted preparation

The authored inputs are unchanged from commit `da68d0b` (one consolidated read, one
ordered execution). This directory now also carries the derived preparation entry and
acceptance checker. `SYSTEM-E2E-001`/`002` and their history are untouched.

## Fixed values

| Item | Value |
| --- | --- |
| Task id | `SYSTEM-E2E-003` |
| Fixture id | `FIXTURE-B1-CONTRACT` |
| Stack / generator | `specification/compiler` at `73024141b8f2153ee9a7299832f58ddf08356039` |
| `SOURCE.sha256` | `bde7693e5da60ddc77aa169af74167a96c3b4debf9ffa8fe178dc23a5303a16d` |
| `INPUTS.sha256` | `509cbc0f44d8294d4059a77397c4bfae95071caabb64844ce2f2ff3cc260eec6` |
| Compiled manifest | `ed644f2089040f504b877000f8efa64760492eb6b6a4a49408504397f06cc52a` |
| Generated prompt | `efe8d7f2754bf1d01da8f806b3c88e3cbc254939b40c931cc59dc7f30bdda377` |
| Preparation entry | `prepare.sh` = `d9769cb2ec6efca4289c7205ed7d3094eb389659868d80cb9e55d35adbf3f9ed` |
| Acceptance checker | `accept.py` = `4c4a129163b15b881602019826490e8969596bfa21b4deca028132d28be338a2` |
| Dependency pins | `DEPENDENCY-PINS.sha256` = `cc0de6a92d08ba45e2069142c51ad748ef3d2def21c806e371671a52d65164e6` |
| Launcher predecessor | `b807a1b8274a41505a755016b155dc46e352e32fb4c67c5fee50551606e1ffe3` |
| Launcher candidate | `03c575ccd86f5d1492fc32a750852e9db7f673818736bd86c5e2c8398a0bffca` |

The candidate changes only `DIAG_ENABLED_TASKS`, appending `SYSTEM-E2E-003` after
`SYSTEM-E2E-002`; every old entry and every other byte is preserved. Broker, observer,
guard, helper and wrapper are unchanged and pinned. The sink
`/var/tmp/aegl-diag/SYSTEM-E2E-003` is outside `/run/aegl-model/$TASK`, so the launcher's
`rm -rf "$RUN"` does not remove it. `--check` still creates no model-task sink.

## Trusted preparation (NOT RUN this round)

```bash
sudo env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  bash -s <<'ENTRY'
set -euo pipefail
umask 077
SRC=/var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_003
BASE=/var/lib/aegl-model/prep-entry
TASK=SYSTEM-E2E-003
IAP=/home/zhong/AndroidStudioProjects/ImageAnalysisFactory
REGISTRY=/var/lib/aegl-model/registry.json
BRIDGE=/home/zhong/.local/state/google-android-agent-stack/bridge
JOURNAL="$BRIDGE/journal.jsonl"
STATE="$BRIDGE/state.json"
PENDING="$BRIDGE/pending_result.json"
STACK_BRIDGE=/var/tmp/IAP-CONTROL-DEV/stack/orchestration/hermes/bridge
RUN_ROOT=/run/aegl-model
TASK_ROOT=/var/tmp/SYSTEM-E2E-003
PKG_DEST=/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/SYSTEM-E2E-003
DIAG_ROOT=/var/tmp/aegl-diag
DIAG_SINK="$DIAG_ROOT/$TASK"
L=/usr/local/lib/aegl-model/aegl-hermes-sandbox
PREPARE_SHA=d9769cb2ec6efca4289c7205ed7d3094eb389659868d80cb9e55d35adbf3f9ed
ACCEPT_SHA=4c4a129163b15b881602019826490e8969596bfa21b4deca028132d28be338a2
SOURCE_SHA=bde7693e5da60ddc77aa169af74167a96c3b4debf9ffa8fe178dc23a5303a16d
DEPS_SHA=cc0de6a92d08ba45e2069142c51ad748ef3d2def21c806e371671a52d65164e6
PRED_SHA=b807a1b8274a41505a755016b155dc46e352e32fb4c67c5fee50551606e1ffe3
CAND_SHA=03c575ccd86f5d1492fc32a750852e9db7f673818736bd86c5e2c8398a0bffca
MANIFEST_SHA=ed644f2089040f504b877000f8efa64760492eb6b6a4a49408504397f06cc52a
PROMPT_SHA=efe8d7f2754bf1d01da8f806b3c88e3cbc254939b40c931cc59dc7f30bdda377
fail() { echo "ENTRY_FAIL $1" >&2; exit 1; }
sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
OP_UID="$(id -u zhong 2>/dev/null)" || fail operator_missing
OP_GID="$(id -g zhong 2>/dev/null)" || fail operator_missing
OP_HOME="$(python3 -B -c 'import pwd,sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' zhong)" || fail operator_missing

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
  ( cd "$STAGE" && sha256sum --strict -c DEPENDENCY-PINS.sha256 ) >/dev/null 2>&1 || fail dependency_hash
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

confirm_prep() {
  [ -f "$LOG" ] || fail prep_log_missing
  local expected
  expected="PREP_COMPLETE task=$TASK contract=$PKG_DEST manifest_sha256=$MANIFEST_SHA prompt_sha256=$PROMPT_SHA diag_sink=$DIAG_SINK launcher_sha256=$CAND_SHA"
  grep -Fxq -- "$expected" "$LOG" || fail prep_marker_mismatch
  echo "SYSTEM_E2E_003_PREP_CONFIRMED"
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

[ ! -L "$BASE" ] || fail base_link
[ ! -e "$BASE" ] || [ -d "$BASE" ] || fail base_type
install -d -m 0700 -o root -g root "$BASE" || fail base_dir
STAGE="$(mktemp -d "$BASE/$TASK.XXXXXX")" || fail stage
echo "ROOT_STAGE=$STAGE"
LOG="$STAGE/prep.log"

for f in prepare.sh accept.py SOURCE.sha256 DEPENDENCY-PINS.sha256; do
  [ -f "$SRC/$f" ] && [ ! -L "$SRC/$f" ] || fail "missing_or_link $f"
done
cp --no-dereference -- "$SRC/prepare.sh" "$STAGE/prepare.sh"
cp --no-dereference -- "$SRC/accept.py" "$STAGE/accept.py"
cp --no-dereference -- "$SRC/SOURCE.sha256" "$STAGE/SOURCE.sha256"
cp --no-dereference -- "$SRC/DEPENDENCY-PINS.sha256" "$STAGE/DEPENDENCY-PINS.sha256"
printf '%s  accept.py\n%s  prepare.sh\n%s  SOURCE.sha256\n%s  DEPENDENCY-PINS.sha256\n' \
  "$ACCEPT_SHA" "$PREPARE_SHA" "$SOURCE_SHA" "$DEPS_SHA" \
  | ( cd "$STAGE" && sha256sum --strict -c - ) || fail entry_hash
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
( cd "$STAGE" && find . -type f -printf '%P\n' | sort ) > "$ACTUAL"
diff -u "$EXPECTED" "$ACTUAL" || fail undeclared_or_missing
rm -- "$EXPECTED" "$ACTUAL"

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
assert data.count(b'SYSTEM-E2E-002 "') == 1
new = data.replace(b'SYSTEM-E2E-002 "', b'SYSTEM-E2E-002 SYSTEM-E2E-003 "', 1)
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
grep -qF 'SYSTEM-E2E-003 ' "$L" || fail diag_entry_missing

set +e
bash "$STAGE/prepare.sh" 2>&1 | tee "$LOG"
pipeline_rc=("${PIPESTATUS[@]}")
set -e
finish_prep "${pipeline_rc[0]}" "${pipeline_rc[1]}"
ENTRY
```

`prepare.sh` re-checks identity/scene/sink, creates the worktree with correct metadata
modes, runs the four zhong Git queries before install/registration, verifies the
diagnostic wiring, compiles and verifies both fixed hashes, registers the task, and runs
the actual `contract_executor.gate`. It stops at `PREP_COMPLETE`; no send, round, model or
`--execute`.

## Success markers

```text
ROOT_STAGE=<root-private stage>
LAUNCHER_STATE=predecessor|candidate
PREFLIGHT_OK identity_unused=1 scene_absent=1 bridge_idle=1 sink_absent=1
SCENE_OK worktree=/var/tmp/SYSTEM-E2E-003/project scratch=/var/tmp/SYSTEM-E2E-003/scratch
BRIDGE_GIT_OK operator=zhong toplevel=/var/tmp/SYSTEM-E2E-003/project ...
DIAG_OK task=SYSTEM-E2E-003 sink=/var/tmp/aegl-diag/SYSTEM-E2E-003 launcher=03c575...
COMPILE_OK ... manifest_sha256=ed644f... prompt_sha256=efe8d7...
INSTALL_OK ... manifest_sha256=ed644f... prompt_sha256=efe8d7...
REGISTER_OK task=SYSTEM-E2E-003
GATE_OK GATE_PASS ImageAnalysisFactory ed644f...
PREP_COMPLETE task=SYSTEM-E2E-003 contract=... manifest_sha256=ed644f... prompt_sha256=efe8d7... diag_sink=/var/tmp/aegl-diag/SYSTEM-E2E-003 launcher_sha256=03c575...
WORKTREE=/var/tmp/SYSTEM-E2E-003/project SCRATCH=/var/tmp/SYSTEM-E2E-003/scratch PKG_STAGE=<path> STAGE_RETAINED=<path>
ROOT_ENTRY_EXIT=0 LOG=<ROOT_STAGE>/prep.log STAGE=<ROOT_STAGE>
SYSTEM_E2E_003_PREP_CONFIRMED
```

`SYSTEM_E2E_003_PREP_CONFIRMED` is printed only when prepare and tee both exit 0 and the
log contains the exact `PREP_COMPLETE` line with `task=SYSTEM-E2E-003`, the fixed contract
path, `manifest_sha256=ed644f…`, `prompt_sha256=efe8d7…`,
`diag_sink=/var/tmp/aegl-diag/SYSTEM-E2E-003` and `launcher_sha256=03c575…`.

Failure is `ENTRY_FAIL ...` or `PREP_FAILED stage=... reason=...`; the root copy and log
are retained. Active-task/run-directory failures use fixed categories (`active_task`,
`run_dir_*`, `process_probe_failed`) without process arguments. No retry, rollback,
re-registration or repair.

## Acceptance (after an authorized execution, not this round)

```bash
python3 -B /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_003/accept.py
```

The checker is the 002 implementation with only `TASK_ID`/paths changed; the frozen
member set, five gates, values, input hashes, registry and Git binding checks are
unchanged.

## Offline / NOT_RUN

- Authoring inputs: `SOURCE.sha256` and `INPUTS.sha256` checks pass; the fixture,
  compiler and schemas are identical to 002; manifest `ed644f…` and prompt `efe8d7…`
  reproduce deterministically.
- Candidate launcher: one-line append only; predecessor `b807a1…`, candidate `03c575…`;
  DIAG/sink/observer/guard wiring strings present; dependencies pinned.
- New gate functions were exercised along the entry path:
  - `check_active`: empty/absent `/run/aegl-model` passes; non-empty, symlink, probe
    failure and a live `model_broker.py` process stop with fixed categories; no process
    arguments are printed.
  - `check_bridge`: dangling `pending_result.json` stops; active status stops; the real
    `bridge_state.unresolved_accepted` returns 0 on the current journal, while a synthetic
    ACCEPTED without terminal returns 1 and maps to `bridge_unresolved`. The real
    root+setpriv path is NOT_RUN; a test-double setpriv exercised the mapping only.
  - Launcher: installed predecessor passes trusted checks; a changed hash, symlink or
    wrong owner stops; real dependency pins pass and a wrong hash stops. The pre-`mv`
    block re-checks predecessor hash/owner/mode, candidate hash/owner/mode, dependencies
    and active tasks.
  - Closure: prepare failure, tee failure, missing log and wrong/missing marker all stop;
    the exact marker prints `SYSTEM_E2E_003_PREP_CONFIRMED`.
- `prepare.sh --verify-only` as zhong stops at `stage=diag reason=launcher_hash` because
  the candidate is not installed yet; the root entry installs it first. This is the
  expected fail-closed gate, not a successful preparation.
- Identity: registry 17 entries with no 003; journal no 003; Bridge `WAITING_FOR_GPT`, no
  pending; scene/contract/worktree absent. The sink is UNKNOWN to zhong because
  `/var/tmp/aegl-diag` is root 0700; the root preparation checks it.
- NOT_RUN: root preparation, real setpriv/bwrap, launcher replacement, registration, real
  contract_executor.gate, guard admission, model behavior, and actual diagnostic event
  persistence.
