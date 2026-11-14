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
fail() { echo "ENTRY_FAIL $1" >&2; exit 1; }
sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

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

[ -f "$STATE" ] || fail bridge_state_missing
status="$(python3 -B -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8")).get("status",""))' "$STATE")" \
  || fail bridge_state_unreadable
case "$status" in
  WAITING_FOR_GPT|IDLE) ;;
  *) fail "bridge_not_idle $status" ;;
esac
[ ! -e "$PENDING" ] || fail bridge_pending

for p in "$TASK_ROOT" "$PKG_DEST" "$DIAG_SINK" "$TASK_ROOT.tmp" "$PKG_DEST.tmp"; do
  if [ -e "$p" ] || [ -L "$p" ]; then
    fail "scene_exists $p"
  fi
done
out=$(git -c safe.directory="$IAP" -C "$IAP" worktree list --porcelain 2>&1) || fail git_worktree
if printf '%s\n' "$out" | grep -qxF -- "worktree $TASK_ROOT/project"; then
  fail worktree_registered
fi

[ -d /run/aegl-model ] || fail run_dir_missing
run_rc=0
run_entries="$(ls -A /run/aegl-model 2>&1)" || run_rc=$?
[ "$run_rc" -eq 0 ] || fail "run_dir_unreadable rc=$run_rc $run_entries"
[ -z "$run_entries" ] || fail "run_dir_not_empty $run_entries"
prc=0
procs="$(pgrep -af 'aegl-hermes-sandbox|aegl-model-broker|run_registered_task' 2>&1)" || prc=$?
case "$prc" in
  1) ;;
  0) fail "active_process $procs" ;;
  *) fail "process_query_rc=$prc" ;;
esac

[ -f "$L" ] && [ ! -L "$L" ] || fail launcher_missing
[ "$(stat -c '%U:%G %a' "$L")" = "root:root 755" ] || fail "launcher_owner_mode $(stat -c '%U:%G %a' "$L")"
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
  ( cd "$STAGE" && sha256sum --strict -c DEPENDENCY-PINS.sha256 ) >/dev/null || fail dependency_before
  install -o root -g root -m 0755 "$STAGE/launcher.candidate" "$L.new" || fail launcher_stage
  [ "$(sha "$L.new")" = "$CAND_SHA" ] || fail launcher_new_hash
  mv -f "$L.new" "$L" || fail launcher_replace
  [ "$(sha "$L")" = "$CAND_SHA" ] || fail launcher_installed_hash
  ( cd "$STAGE" && sha256sum --strict -c DEPENDENCY-PINS.sha256 ) >/dev/null || fail dependency_after
else
  fail "launcher_unknown $cur"
fi
grep -qF 'SYSTEM-E2E-003 ' "$L" || fail diag_entry_missing

set +e
bash "$STAGE/prepare.sh" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "ROOT_ENTRY_EXIT=$rc LOG=$LOG STAGE=$STAGE"
exit "$rc"
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
```

Failure is `ENTRY_FAIL ...` or `PREP_FAILED stage=... reason=...`; the root copy and log
are retained. No retry, rollback, re-registration or repair.

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
- `prepare.sh --verify-only` as zhong stops at `stage=diag reason=launcher_hash` because
  the candidate is not installed yet; the root entry installs it first. This is the
  expected fail-closed gate, not a successful preparation.
- Identity: registry 17 entries with no 003; journal no 003; Bridge `WAITING_FOR_GPT`, no
  pending; scene/contract/worktree absent. The sink is UNKNOWN to zhong because
  `/var/tmp/aegl-diag` is root 0700; the root preparation checks it.
- NOT_RUN: root preparation, launcher replacement, registration, real
  contract_executor.gate, root/bwrap, guard admission, model behavior, and actual
  diagnostic event persistence.
