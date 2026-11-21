#!/usr/bin/env bash
# prepare.sh — CAL-WPF-001 trusted preparation (NO send, NO model, NO execution).
#
#   bash prepare.sh --check     # unprivileged pre-check; no trusted/registry/worktree writes
#   sudo env -i HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
#     LANG=C.UTF-8 bash /var/tmp/IAP-CONTROL-DEV/aegl/recovery/calendar_wpf_001/prepare.sh
#
# Root mode verifies the frozen contract and worktree, chowns the disposable worktree and
# scratch to aegl-ai, installs the contract package into the trusted contract root,
# registers the task with the installed root-only tool, runs the real
# contract_executor.gate as the operator, and stops at PREP_COMPLETE. It never sends a
# message, calls a model, runs a round or passes --execute.
set -euo pipefail

TASK_ID="CAL-WPF-001"
PROJECT_NAME="OfflineTaskCalendar_WPF"
TASK_ROOT="/var/tmp/RILI-WPF-V2/CAL-001"
WORKTREE="$TASK_ROOT/project"
SCRATCH="$TASK_ROOT/scratch"
PROJECT="/home/zhong/EXE/OfflineTaskCalendar_WPF"
CONTRACT_SRC="$TASK_ROOT/contract-final"
PKG_DEST="/var/lib/aegl-model/trusted/OfflineTaskCalendar_WPF/reports/contracts/$TASK_ID"
REGISTRY="/var/lib/aegl-model/registry.json"
REGISTER="/usr/local/lib/aegl-model-task/bin/aegl-model-task"
STACK="/var/tmp/IAP-CONTROL-DEV/stack"
BRIDGE_DIR="/home/zhong/.local/state/google-android-agent-stack/bridge"
AI_USER="aegl-ai"
OPERATOR="zhong"
BASE_COMMIT="fdcb91a5465e4f1f7d69e9dda1d901cb7999dd50"
MANIFEST_SHA="639ed1fec89a9af7f67b0bb080c169aeb91ab3adb2b0d8c394f99c21fb83d105"
DIAGNOSTICS=0
CHECK_ONLY=0
LAUNCHER=/usr/local/lib/aegl-model/aegl-hermes-sandbox
LAUNCHER_BODY_SHA=0c8aafde79be9b2564ef771d97ed78982aa5887790da50d84147b2d2d19174ec
DIAG_CHECKED_LAUNCHER_SHA=""
WRAPPER=/usr/local/lib/aegl-bridge/run_registered_task
WRAPPER_PREDECESSOR_SHA=5ed0b06db96b48297e562277149b0e7f66d0314c96279c6d7e2365b772a9c5ca
WRAPPER_SOURCE_SHA=e8b90a5a995795555ef077482f0a80cc14a6249815e1c182decca4444e398725
SUMMARY_SOURCE_SHA=5a3f3923fa186cc8770e5b6ef806627ca53895ab183051dd41e9c8ad520b84eb
AEGL_SRC=/var/tmp/IAP-CONTROL-DEV/aegl

say(){ printf '%s\n' "$*"; }
die(){ printf 'PREP_FAILED: %s\n' "$*" >&2; exit 1; }
sha(){ sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
need(){ command -v "$1" >/dev/null 2>&1 || die "missing tool: $1"; }

diagnostics_check(){
  # The root-owned task list is configuration; every other launcher byte stays pinned.
  python3 -B - "$LAUNCHER" "$REGISTRY" "$LAUNCHER_BODY_SHA" <<'PY' || die "diagnostic launcher code/config validation failed"
# DIAG_CONFIG_VALIDATOR_BEGIN
from pathlib import Path
import hashlib,json,re,sys
path,registry,expected=sys.argv[1:]
text=Path(path).read_text()
lines=[line for line in text.splitlines(keepends=True) if line.startswith('DIAG_ENABLED_TASKS="')]
if len(lines)!=1 or not re.fullmatch(r'DIAG_ENABLED_TASKS=" (?:[A-Za-z0-9._-]{1,64} )+"\n',lines[0]):
    raise SystemExit('invalid diagnostic task configuration')
tasks=lines[0].split('"')[1].split()
baseline='BRIDGE-DIAG-003 BRIDGE-VERIFY-004 BRIDGE-VERIFY-007 BRIDGE-VERIFY-008 IAP-SMOKE-003 IAP-SMOKE-004 IAP-SMOKE-005 IAP-SMOKE-006 IAP-SMOKE-007 IAP-SMOKE-008 SYSTEM-E2E-002 SYSTEM-E2E-003 SYSTEM-E2E-004 SYSTEM-E2E-005'.split()
if len(tasks)!=len(set(tasks)) or tasks[:len(baseline)]!=baseline:
    raise SystemExit('diagnostic baseline changed or duplicate task')
registered=json.loads(Path(registry).read_text())
if any(task not in registered for task in tasks[len(baseline):]):
    raise SystemExit('unregistered diagnostic task')
normalized=text.replace(lines[0],'DIAG_ENABLED_TASKS="<REGISTERED_TASK_CONFIG>"\n',1)
if hashlib.sha256(normalized.encode()).hexdigest()!=expected:
    raise SystemExit('diagnostic launcher code changed')
# DIAG_CONFIG_VALIDATOR_END
PY
  DIAG_CHECKED_LAUNCHER_SHA="$(sha "$LAUNCHER")"
  [ "$(sha "$WRAPPER")" = "$WRAPPER_PREDECESSOR_SHA" ] || [ "$(sha "$WRAPPER")" = "$WRAPPER_SOURCE_SHA" ] || die "diagnostic wrapper version changed"
  [ "$(sha "$STACK/orchestration/hermes/bridge/run_registered_task")" = "$WRAPPER_SOURCE_SHA" ] || die "diagnostic wrapper source changed"
  [ "$(sha "$AEGL_SRC/recovery/iap_diag_summary.py")" = "$SUMMARY_SOURCE_SHA" ] || die "diagnostic summary source changed"
  local helper=/usr/local/lib/aegl-model/iap_diag_summary.py p
  [ ! -L "$helper" ] || die "diagnostic helper destination is a link"
  [ ! -e "$helper" ] || [ "$(sha "$helper")" = "$SUMMARY_SOURCE_SHA" ] || die "diagnostic helper destination differs"
  [ ! -e "$helper" ] || [ "$(stat -c '%U:%G %a' "$helper")" = 'root:root 644' ] || die "diagnostic helper owner/mode"
  bash -n "$STACK/orchestration/hermes/bridge/run_registered_task" || die "wrapper syntax"
  for p in "$LAUNCHER" "$WRAPPER"; do
    [ ! -L "$p" ] && [ "$(stat -c '%U:%G %a' "$p")" = 'root:root 755' ] || die "diagnostic installed entry owner/mode"
    [ ! -L "$(dirname "$p")" ] && [ "$(stat -c '%U:%G %a' "$(dirname "$p")")" = 'root:root 755' ] || die "diagnostic installed parent owner/mode"
  done
  if [ "$(id -u)" -eq 0 ]; then
    [ ! -L /var/tmp/aegl-diag ] && [ "$(stat -c '%U:%G %a' /var/tmp/aegl-diag)" = 'root:root 700' ] || die "diagnostic root owner/mode"
    [ ! -e "/var/tmp/aegl-diag/$TASK_ID" ] && [ ! -L "/var/tmp/aegl-diag/$TASK_ID" ] || die "diagnostic sink already exists"
  else
    say "DIAG_SINK_STATE=UNKNOWN_REQUIRES_ROOT task=$TASK_ID"
  fi
  say "DIAG_INPUTS_OK task=$TASK_ID"
}

diagnostics_install(){
  diagnostics_check
  local candidate helper=/usr/local/lib/aegl-model/iap_diag_summary.py
  candidate="$(mktemp "$LAUNCHER.calendar.XXXXXX")" || die "diagnostic candidate file"
  python3 -B - "$LAUNCHER" "$candidate" "$TASK_ID" <<'PY' || die "diagnostic allowlist update"
from pathlib import Path
import sys
src,dst,task=sys.argv[1:]
text=Path(src).read_text()
lines=[line for line in text.splitlines(keepends=True) if line.startswith('DIAG_ENABLED_TASKS="')]
if len(lines)!=1 or not lines[0].endswith(' "\n') or (' '+task+' ') in lines[0]:
    raise SystemExit('unexpected diagnostic allowlist')
line=lines[0]
Path(dst).write_text(text.replace(line,line[:-3]+' '+task+' "\n',1))
PY
  bash -n "$candidate" || die "diagnostic launcher candidate syntax"
  chmod 0755 "$candidate" || die "diagnostic candidate mode"
  chown root:root "$candidate" || die "diagnostic candidate owner"
  [ "$(sha "$LAUNCHER")" = "$DIAG_CHECKED_LAUNCHER_SHA" ] || die "diagnostic launcher changed during prepare"
  mv -T -- "$candidate" "$LAUNCHER" || die "diagnostic launcher install"
  if [ "$(sha "$WRAPPER")" = "$WRAPPER_SOURCE_SHA" ] && [ "$(sha "$helper")" = "$SUMMARY_SOURCE_SHA" ]; then
    say "DIAG_ENABLED task=$TASK_ID sink=/var/tmp/aegl-diag/$TASK_ID wrapper_sha256=$WRAPPER_SOURCE_SHA components=REUSED"
    return
  fi
  [ ! -e "$helper.new" ] && [ ! -L "$helper.new" ] || die "diagnostic helper temporary exists"
  install -o root -g root -m 0644 "$AEGL_SRC/recovery/iap_diag_summary.py" "$helper.new" || die "diagnostic helper stage"
  [ ! -e "$WRAPPER.new" ] && [ ! -L "$WRAPPER.new" ] || die "diagnostic wrapper temporary exists"
  install -o root -g root -m 0755 "$STACK/orchestration/hermes/bridge/run_registered_task" "$WRAPPER.new" || die "diagnostic wrapper stage"
  [ "$(sha "$WRAPPER.new")" = "$WRAPPER_SOURCE_SHA" ] && [ "$(sha "$helper.new")" = "$SUMMARY_SOURCE_SHA" ] || die "diagnostic staged content mismatch"
  mv -T -- "$helper.new" "$helper" || die "diagnostic helper install"
  mv -T -- "$WRAPPER.new" "$WRAPPER" || die "diagnostic wrapper install"
  say "DIAG_ENABLED task=$TASK_ID sink=/var/tmp/aegl-diag/$TASK_ID wrapper_sha256=$WRAPPER_SOURCE_SHA"
}

require_check(){
  [ -d "$TASK_ROOT" ] && [ ! -L "$TASK_ROOT" ] || die "task root missing or a link: $TASK_ROOT"
  [ -d "$WORKTREE" ] && [ ! -L "$WORKTREE" ] || die "worktree missing or a link: $WORKTREE"
  [ -d "$SCRATCH" ] && [ ! -L "$SCRATCH" ] || die "scratch missing or a link: $SCRATCH"
  [ -d "$PROJECT/.git" ] || die "formal project git missing: $PROJECT/.git"
  [ -d "$CONTRACT_SRC" ] && [ ! -L "$CONTRACT_SRC" ] || die "contract source missing: $CONTRACT_SRC"
  [ "$(sha "$CONTRACT_SRC/manifest.json")" = "$MANIFEST_SHA" ] || die "manifest hash mismatch in $CONTRACT_SRC"
  [ -f "$CONTRACT_SRC/READY.json" ] || die "READY.json missing in $CONTRACT_SRC"

  local head status common gitdir base_head
  head="$(git -c safe.directory="$WORKTREE" -C "$WORKTREE" rev-parse HEAD 2>/dev/null)" || die "git rev-parse failed"
  base_head="$(git -c safe.directory="$PROJECT" -C "$PROJECT" rev-parse "$BASE_COMMIT" 2>&1)" \
    || die "root git query failed for $PROJECT: $base_head"
  [ "$head" = "$base_head" ] || die "worktree HEAD $head is not base $BASE_COMMIT"
  git -c safe.directory="$WORKTREE" -C "$WORKTREE" rev-parse --verify "$BASE_COMMIT^{commit}" >/dev/null 2>&1 \
    || die "base commit not found: $BASE_COMMIT"
  status="$(git -c safe.directory="$WORKTREE" -C "$WORKTREE" status --porcelain 2>/dev/null)" || die "git status failed"
  [ -z "$status" ] || die "worktree is not clean: $status"
  common="$(git -c safe.directory="$WORKTREE" -C "$WORKTREE" rev-parse --git-common-dir 2>/dev/null)" || die "git common-dir failed"
  case "$common" in /*) ;; *) common="$WORKTREE/$common" ;; esac
  [ "$(realpath -e "$common")" = "$(realpath -e "$PROJECT/.git")" ] || die "worktree common dir is not $PROJECT/.git"
  gitdir="$(git -c safe.directory="$WORKTREE" -C "$WORKTREE" rev-parse --absolute-git-dir 2>/dev/null)" || die "git dir failed"
  case "$gitdir" in "$PROJECT"/.git/worktrees/*) ;; *) die "git dir is not under $PROJECT/.git/worktrees: $gitdir" ;; esac

  [ -x "$REGISTER" ] || die "registry CLI missing: $REGISTER"
  [ -f "$REGISTRY" ] || die "registry missing: $REGISTRY"

  python3 -B - "$REGISTRY" "$TASK_ID" <<'PY' || die "task id already registered"
import json, sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception as exc:
    raise SystemExit(f"registry unreadable: {exc}")
raise SystemExit(3 if sys.argv[2] in data else 0)
PY
  [ -f "$BRIDGE_DIR/journal.jsonl" ] || die "bridge journal missing"
  python3 -B - "$BRIDGE_DIR/journal.jsonl" "$TASK_ID" <<'PY' || die "task id already appears in the journal"
import json, sys
try:
    for line in open(sys.argv[1], encoding="utf-8"):
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("task_id") == sys.argv[2]:
            raise SystemExit(3)
except OSError as exc:
    raise SystemExit(f"journal unreadable: {exc}")
raise SystemExit(0)
PY
  python3 -B - "$BRIDGE_DIR/state.json" <<'PY' || die "bridge is not idle"
import json, sys
try:
    status = json.load(open(sys.argv[1], encoding="utf-8")).get("status", "")
except Exception as exc:
    raise SystemExit(f"state unreadable: {exc}")
raise SystemExit(0 if status in ("WAITING_FOR_GPT", "IDLE") else 3)
PY
  [ ! -e "$BRIDGE_DIR/pending_result.json" ] || die "bridge has a pending result"
  [ ! -e "$PKG_DEST" ] || die "trusted contract destination already exists: $PKG_DEST"
  [ ! -e "$PKG_DEST.tmp" ] || die "trusted contract temp exists: $PKG_DEST.tmp"

  python3 -B "$STACK/specification/compiler/validate_package.py" "$CONTRACT_SRC" --project-root "$TASK_ROOT" >/dev/null \
    || die "contract validator did not return READY"
  [ "$(python3 -B -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$CONTRACT_SRC/validation-report.json")" = "READY" ] \
    || die "validation-report is not READY"

  python3 -B - "$STACK/orchestration/hermes/bridge" "$CONTRACT_SRC" "$PKG_DEST" "$WORKTREE" "$TASK_ROOT" "$PROJECT_NAME" <<'PY' \
    || die "binding validation failed"
import json, os, sys
sys.path.insert(0, sys.argv[1])
import projects
pkg, expected_pkg, worktree, task_root, name = sys.argv[2:7]
binding = projects.binding_for(name)
if binding is None:
    raise SystemExit("binding missing")
context = json.load(open(os.path.join(pkg, "project-context.json"), encoding="utf-8"))
verdict = projects.validate_project(
    name,
    package_real=expected_pkg,
    contract_root=binding["contract_root"],
    context_project=context.get("project"),
    context_source_root=context.get("source_root"),
    context_allowed_paths=context.get("allowed_paths"),
    worktree=worktree,
    binding=binding,
)
if not verdict.get("ok"):
    raise SystemExit(verdict)
if os.path.realpath(context.get("source_root")) != os.path.realpath(task_root):
    raise SystemExit("source_root != task root")
print("BINDING_OK project=%s worktree=%s package=%s" % (name, worktree, expected_pkg))
PY

  say "CHECK_OK task=$TASK_ID base=$BASE_COMMIT manifest=$MANIFEST_SHA worktree=$WORKTREE contract=$CONTRACT_SRC"
}

operator_home(){ python3 -B -c 'import pwd,sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' "$OPERATOR"; }

as_operator(){
  local home; home="$(operator_home)" || die "operator missing"
  setpriv --reuid="$(id -u "$OPERATOR")" --regid="$(id -g "$OPERATOR")" --clear-groups --no-new-privs -- \
    env -i HOME="$home" PATH="/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
      PYTHONDONTWRITEBYTECODE=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
      "$@"
}

root_prepare(){
  [ "$(id -u)" -eq 0 ] || die "root mode requires root"
  for tool in git sha256sum realpath setpriv setfacl stat python3; do need "$tool"; done
  require_check
  if [ "$DIAGNOSTICS" -eq 1 ]; then diagnostics_install; fi

  local gitdir
  gitdir="$(git -c safe.directory="$WORKTREE" -C "$WORKTREE" rev-parse --absolute-git-dir 2>&1)" \
    || die "worktree git dir query failed: $gitdir"
  [ -d "$gitdir" ] || die "worktree git dir missing: $gitdir"
  chown -R "$AI_USER:$AI_USER" "$WORKTREE" || die "worktree chown failed"
  chmod -R u=rwX,go=rX "$WORKTREE" || die "worktree chmod failed"
  install -d -o "$AI_USER" -g "$AI_USER" -m 0750 "$SCRATCH" || die "scratch create failed"
  chown "$AI_USER:$AI_USER" "$SCRATCH" || die "scratch chown failed"
  chmod 0755 "$gitdir" || die "git dir chmod failed"
  for meta in gitdir commondir HEAD index ORIG_HEAD; do
    [ ! -e "$gitdir/$meta" ] || chmod 0644 "$gitdir/$meta" || die "git metadata chmod failed: $meta"
  done
  for meta in logs refs; do
    [ ! -e "$gitdir/$meta" ] || chmod 0755 "$gitdir/$meta" || die "git metadata chmod failed: $meta"
  done
  [ ! -e "$gitdir/logs/HEAD" ] || chmod 0644 "$gitdir/logs/HEAD" || die "git log chmod failed"
  setfacl -m u:"$AI_USER":x "$TASK_ROOT" || die "ACL for aegl-ai failed"
  setfacl -m u:"$OPERATOR":x "$TASK_ROOT" || die "ACL for operator failed"

  local ai_uid ai_gid
  ai_uid="$(id -u "$AI_USER")"; ai_gid="$(id -g "$AI_USER")"
  setpriv --reuid="$ai_uid" --regid="$ai_gid" --clear-groups --no-new-privs -- \
    python3 -I -c 'import os,sys; sys.exit(0 if os.access(sys.argv[1], os.W_OK) and os.access(sys.argv[2], os.W_OK) else 1)' \
    "$WORKTREE" "$SCRATCH" || die "$AI_USER cannot write worktree/scratch"
  local expected_head
  expected_head="$(git -c safe.directory="$PROJECT" -C "$PROJECT" rev-parse "$BASE_COMMIT" 2>&1)" \
    || die "root git query failed for $PROJECT: $expected_head"
  as_operator git -c safe.directory="$WORKTREE" -c safe.directory="$PROJECT" -C "$WORKTREE" rev-parse HEAD \
    | grep -qx "$expected_head" || die "operator cannot read worktree at base"
  as_operator python3 -I -c 'import sys; [open(p, "rb").close() for p in sys.argv[1:]]' \
    "$WORKTREE/src/TaskCalendar.Infrastructure/Import/TaskImportService.cs" || die "operator cannot read source"

  install -d -m 0755 -o root -g root "$(dirname "$PKG_DEST")" || die "trusted parent create failed"
  install -d -m 0755 -o root -g root "$PKG_DEST" || die "trusted package create failed"
  cp -a "$CONTRACT_SRC"/. "$PKG_DEST"/ || die "contract copy failed"
  chown -R root:root "$PKG_DEST" || die "contract chown failed"
  chmod -R u=rwX,go=rX "$PKG_DEST" || die "contract chmod failed"
  [ -z "$(find "$PKG_DEST" -perm /022 -print -quit)" ] || die "contract package has group/other writable members"
  [ "$(sha "$PKG_DEST/manifest.json")" = "$MANIFEST_SHA" ] || die "installed manifest hash mismatch"

  "$REGISTER" register \
    --task-id "$TASK_ID" \
    --worktree "$WORKTREE" \
    --scratch "$SCRATCH" \
    --project "$PROJECT" \
    --contract-package "$PKG_DEST" || die "register failed"

  python3 -B - "$REGISTRY" "$TASK_ID" "$WORKTREE" "$SCRATCH" "$PROJECT" "$PKG_DEST" <<'PY' || die "registry verification failed"
import json, os, sys
registry, task, worktree, scratch, project, contract = sys.argv[1:7]
entry = json.load(open(registry, encoding="utf-8")).get(task)
want = {"worktree": worktree, "scratch": scratch, "project": project, "contract_package": contract}
assert isinstance(entry, dict) and set(entry) == set(want), "unexpected entry"
for key, value in want.items():
    assert os.path.realpath(entry[key]) == os.path.realpath(value), key
print("REGISTER_OK task=%s" % task)
PY

  local out
  out="$(as_operator python3 -B - "$STACK/orchestration/hermes/bridge" "$PKG_DEST" "$MANIFEST_SHA" "$PROJECT_NAME" "$TASK_ID" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import contract_executor as ce
try:
    result = ce.gate(sys.argv[2], sys.argv[3], project=sys.argv[4], task_id=sys.argv[5])
    print("GATE_PASS " + result["project"] + " " + result["manifest_sha256"])
except ce.GateError as exc:
    print("GATE_REJECTED " + exc.code + ": " + exc.message)
    raise SystemExit(1)
PY
)" || die "gate failed: $out"
  say "GATE_OK $out"
  say "PREP_COMPLETE task=$TASK_ID project=$PROJECT_NAME worktree=$WORKTREE scratch=$SCRATCH contract=$PKG_DEST manifest_sha256=$MANIFEST_SHA"
  say "NEXT: no message was sent and no model was called. Execution requires an applicable unconsumed user authorization."
}

# Reuse the existing preparation path for a new explicitly authorized calendar
# slice. Arguments are data only; no source/eval, no copied per-task preparer.
# --task TASK_ID TASK_ROOT BASE_COMMIT MANIFEST_SHA [--check]
if [ "${1:-}" = "--task" ]; then
  [ "$#" -ge 5 ] && [ "$#" -le 7 ] || die "--task needs TASK_ID TASK_ROOT BASE_COMMIT MANIFEST_SHA [--diagnostics] [--check]"
  TASK_ID="$2"; TASK_ROOT="$3"; BASE_COMMIT="$4"; MANIFEST_SHA="$5"
  [[ "$TASK_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "invalid task id"
  [[ "$BASE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "base must be a full commit id"
  [[ "$MANIFEST_SHA" =~ ^[0-9a-f]{64}$ ]] || die "manifest must be a SHA-256"
  [[ "$TASK_ROOT" =~ ^/var/tmp/RILI-WPF-V2/[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "task root outside approved calendar base"
  [ "$TASK_ROOT" = "$(realpath -e "$TASK_ROOT")" ] || die "task root must be canonical"
  WORKTREE="$TASK_ROOT/project"; SCRATCH="$TASK_ROOT/scratch"
  CONTRACT_SRC="$TASK_ROOT/contract-final"
  PKG_DEST="/var/lib/aegl-model/trusted/OfflineTaskCalendar_WPF/reports/contracts/$TASK_ID"
  shift 5
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) [ "$CHECK_ONLY" -eq 0 ] || die "duplicate --check"; CHECK_ONLY=1 ;;
    --diagnostics) [ "$DIAGNOSTICS" -eq 0 ] || die "duplicate --diagnostics"; DIAGNOSTICS=1 ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done
if [ "$CHECK_ONLY" -eq 1 ]; then
  require_check
  if [ "$DIAGNOSTICS" -eq 1 ]; then diagnostics_check; fi
else
  root_prepare
fi
