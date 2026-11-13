# SYSTEM-E2E-002 — diagnostic-located compile-loop acceptance

One disposable task derived from SYSTEM-E2E-001's authored inputs. It keeps the same
fixture, compiler, schemas, input hashes, business steps and frozen acceptance, and adds
only the existing task-scoped diagnostic entry for this identity.

## Fixed identity and sources

| Item | Value |
| --- | --- |
| Task id | `SYSTEM-E2E-002` |
| Fixture id | `FIXTURE-B1-CONTRACT` |
| Stack source | `/var/tmp/IAP-CONTROL-DEV/stack` at `73024141b8f2153ee9a7299832f58ddf08356039` |
| Fixture / compiler / schemas | identical bytes to SYSTEM-E2E-001 (`INPUTS.sha256` = `509cbc0f44d8294d4059a77397c4bfae95071caabb64844ce2f2ff3cc260eec6`) |
| Authored contract | `SOURCE.sha256` = `8c7012078c51fb4d7cb423173c4d344515e3d7a2673dfbeb2096c8fcaf8337f7` |
| Compiled manifest | `f776f04c05f2c515e49f171c019485b4200529b2887f75628388f6ed5eedf168` (fixed package basename `SYSTEM-E2E-002`) |
| Project binding | `ImageAnalysisFactory`, base `177680708739a72a0d70bc6a9664245b00a2ef08` |
| Scene | `/var/tmp/SYSTEM-E2E-002` (`project/`, `scratch/`) |
| Contract install | `/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/SYSTEM-E2E-002` |
| Diagnostic sink | `/var/tmp/aegl-diag/SYSTEM-E2E-002` |
| Budget | 120 s task, 10 s wrapper grace, one execution, no retry |

## Existing diagnostics only

The installed launcher already derives the sink from the task id and writes it outside the
run directory. The candidate adds exactly one token to `DIAG_ENABLED_TASKS`:

```text
-IAP-SMOKE-008 "
+IAP-SMOKE-008 SYSTEM-E2E-002 "
```

Predecessor `/usr/local/lib/aegl-model/aegl-hermes-sandbox`
`0bcb76d1bc4366691d9eb8cd38333bdb4a9d963c28213de21d63accf4d8c733a`;
candidate `b807a1b8274a41505a755016b155dc46e352e32fb4c67c5fee50551606e1ffe3`.
All existing entries are preserved; every other byte is unchanged. Broker, observer,
guard, helpers and wrapper are unchanged and pinned in `DEPENDENCY-PINS.sha256`
(`cc0de6a92d08ba45e2069142c51ad748ef3d2def21c806e371671a52d65164e6`).

The sink is created by the launcher as root:root 0700 and is not under
`/run/aegl-model/$TASK`, so the launcher's `rm -rf "$RUN"` cleanup does not remove it.
`--check` still clears `DIAG_ENABLED_TASKS` and creates no model-task sink.

Persisted records (when the real run happens):

- `events.jsonl`: launcher prep phases; broker request/upstream/model phases; model tool
  request sequence; guard call/verdict; tool pre/post observation with fixed classes,
  status, duration and exit code. No bodies, headers, credentials, prompts or environment.
- `guard-capture.jsonl`: controller-side guard verdict, request correlation, operation,
  target and request arguments, with `_recorded`; no tool stdout/stderr bodies.

Still not observable: raw tool stdout/stderr, full command output, model reasoning/prompt
text, network payloads/headers/credentials, and any event where the hook/socket failed
(a missing post is UNKNOWN, never proof the tool did not run). Diagnostics are observational
only: guard remains pre-authorization, hooks remain diagnostics, and neither proves success.

## Trusted preparation (NOT RUN this round)

```bash
sudo env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  LANG=C.UTF-8 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
  bash -s <<'ENTRY'
set -euo pipefail
umask 077
SRC=/var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_002
BASE=/var/lib/aegl-model/prep-entry
TASK=SYSTEM-E2E-002
IAP=/home/zhong/AndroidStudioProjects/ImageAnalysisFactory
REGISTRY=/var/lib/aegl-model/registry.json
BRIDGE=/home/zhong/.local/state/google-android-agent-stack/bridge
JOURNAL="$BRIDGE/journal.jsonl"
STATE="$BRIDGE/state.json"
PENDING="$BRIDGE/pending_result.json"
TASK_ROOT=/var/tmp/SYSTEM-E2E-002
PKG_DEST=/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/SYSTEM-E2E-002
DIAG_ROOT=/var/tmp/aegl-diag
DIAG_SINK="$DIAG_ROOT/$TASK"
L=/usr/local/lib/aegl-model/aegl-hermes-sandbox
PREPARE_SHA=6f6254bdd0dbdea731dd7d4aaee1e6ae91ef08e7b8158fd3e4103c8c654fe9e7
ACCEPT_SHA=f51918250e654a7d7d22054d49acdb835bf8aad1b06c720d5730a3c43dc214d1
SOURCE_SHA=8c7012078c51fb4d7cb423173c4d344515e3d7a2673dfbeb2096c8fcaf8337f7
DEPS_SHA=cc0de6a92d08ba45e2069142c51ad748ef3d2def21c806e371671a52d65164e6
PRED_SHA=0bcb76d1bc4366691d9eb8cd38333bdb4a9d963c28213de21d63accf4d8c733a
CAND_SHA=b807a1b8274a41505a755016b155dc46e352e32fb4c67c5fee50551606e1ffe3

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

[ -f "$L" ] && [ ! -L "$L" ] || fail launcher_missing
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
assert data.count(b'IAP-SMOKE-008 "') == 1
new = data.replace(b'IAP-SMOKE-008 "', b'IAP-SMOKE-008 SYSTEM-E2E-002 "', 1)
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
grep -qF 'SYSTEM-E2E-002 ' "$L" || fail diag_entry_missing

set +e
bash "$STAGE/prepare.sh" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
set -e
echo "ROOT_ENTRY_EXIT=$rc LOG=$LOG STAGE=$STAGE"
exit "$rc"
ENTRY
```

`prepare.sh` re-checks identity/scene/sink, creates the worktree with correct metadata
modes, runs the four real zhong Git queries before install/registration, verifies the
diagnostic wiring, registers the task and runs the actual `contract_executor.gate`. It
stops at `PREP_COMPLETE`; it does not send, wait, run a round or call a model.

## Markers

```text
ROOT_STAGE=<root-private stage>
LAUNCHER_STATE=predecessor|candidate
GATE_OK GATE_PASS ImageAnalysisFactory <manifest sha>
PREP_COMPLETE task=SYSTEM-E2E-002 contract=<path> manifest_sha256=f776f0... diag_sink=/var/tmp/aegl-diag/SYSTEM-E2E-002 launcher_sha256=b807a1...
WORKTREE=/var/tmp/SYSTEM-E2E-002/project SCRATCH=/var/tmp/SYSTEM-E2E-002/scratch PKG_STAGE=<path> STAGE_RETAINED=<path>
ROOT_ENTRY_EXIT=0 LOG=<ROOT_STAGE>/prep.log STAGE=<ROOT_STAGE>
```

Failure is `ENTRY_FAIL ...` or `PREP_FAILED stage=... reason=...`; the stage and log are
kept. There is no automatic retry, rollback, re-registration or repair.

## Host acceptance (after the real execution, not this round)

```bash
python3 -B /var/tmp/IAP-CONTROL-DEV/aegl/recovery/system_e2e_002/accept.py
```

It keeps the frozen `FIXTURE-B1-CONTRACT` / 8 / 1 / 1 / READY / 0 checks and the authored
member set, exact five gates, input hashes, registry and Git binding checks.

## NOT_RUN this round

- Full root preparation and launcher installation.
- Real launcher/`bwrap`/Hermes execution and any diagnostic event persistence.
- `--check` under the new launcher, and the real `contract_executor.gate` (the gate runs
  only inside the delivered preparation command after registration).
- Sending, round, model calls, recover, host acceptance of a new run.
