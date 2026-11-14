#!/usr/bin/env bash
# prepare.sh — SYSTEM-E2E-003 trusted preparation (NO send, NO model, NO execution).
#
#   sudo bash prepare.sh                 # full preparation, stops at PREP_COMPLETE
#        bash prepare.sh --verify-only   # source/hash/identity checks only (no writes, no root)
#
# The full mode verifies every pinned source byte, refuses an existing identity or scene,
# creates the disposable worktree, compiles this authored contract with the same pinned
# compiler, installs the package under the trusted contract root, registers the task with
# the installed root-only registry tool and stops. It never sends, waits, runs a round,
# calls a model or passes --execute. Any failure stops with PREP_FAILED and changes nothing
# beyond what it already reported; nothing is deleted, retried or overwritten.
set -uo pipefail

TASK_ID="SYSTEM-E2E-003"
STACK="/var/tmp/IAP-CONTROL-DEV/stack"
IAP="/home/zhong/AndroidStudioProjects/ImageAnalysisFactory"
TASK_ROOT="/var/tmp/$TASK_ID"
WORKTREE="$TASK_ROOT/project"
SCRATCH="$TASK_ROOT/scratch"
PKG_PARENT="/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts"
PKG_DEST="$PKG_PARENT/$TASK_ID"
REGISTRY="/var/lib/aegl-model/registry.json"
REGISTER="/usr/local/lib/aegl-model-task/bin/aegl-model-task"
AI_USER="aegl-ai"
OPERATOR="zhong"

STACK_COMMIT="73024141b8f2153ee9a7299832f58ddf08356039"
IAP_BASE="177680708739a72a0d70bc6a9664245b00a2ef08"
SOURCE_PINS_SHA="bde7693e5da60ddc77aa169af74167a96c3b4debf9ffa8fe178dc23a5303a16d"
INPUTS_SHA="509cbc0f44d8294d4059a77397c4bfae95071caabb64844ce2f2ff3cc260eec6"
CONTRACT_MANIFEST_SHA="ed644f2089040f504b877000f8efa64760492eb6b6a4a49408504397f06cc52a"
CONTRACT_PROMPT_SHA="efe8d7f2754bf1d01da8f806b3c88e3cbc254939b40c931cc59dc7f30bdda377"
LAUNCHER="/usr/local/lib/aegl-model/aegl-hermes-sandbox"
LAUNCHER_PREDECESSOR_SHA="b807a1b8274a41505a755016b155dc46e352e32fb4c67c5fee50551606e1ffe3"
LAUNCHER_CANDIDATE_SHA="03c575ccd86f5d1492fc32a750852e9db7f673818736bd86c5e2c8398a0bffca"
DIAG_ROOT="/var/tmp/aegl-diag"
DIAG_SINK="$DIAG_ROOT/$TASK_ID"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_SRC="$SRC/contract/$TASK_ID"
CURRENT_STAGE=""
VERIFY_ONLY=0
STAGE=""
PREP_ROOT=""

say() { printf '%s\n' "$*"; }
die() {
  printf 'PREP_FAILED stage=%s reason=%s: %s\n' "${CURRENT_STAGE:-none}" "$1" "${2:-}" >&2
  exit 1
}
sha() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }
need() { command -v "$1" >/dev/null 2>&1 || die missing_tool "$1"; }

# One command-level exact safe.directory for the queried repository. The rc and the
# combined output are captured separately; callers must check GIT_RC before judging.
GIT_OUT=""
GIT_RC=0
git_capture() { # <repository-dir> <git args...>
  local dir="$1"; shift
  GIT_OUT="$(git -c safe.directory="$dir" -C "$dir" "$@" 2>&1)"
  GIT_RC=$?
}
git_capture_worktree() { # <worktree-dir> <common-repository-dir> <git args...>
  local wt="$1" common="$2"; shift 2
  GIT_OUT="$(git -c safe.directory="$wt" -c safe.directory="$common" -C "$wt" "$@" 2>&1)"
  GIT_RC=$?
}

stage_source() {
  CURRENT_STAGE=source
  for tool in python3 git sha256sum awk realpath setpriv setfacl stat grep; do need "$tool"; done
  [ -d "$CONTRACT_SRC" ] || die contract_source_missing "$CONTRACT_SRC"
  [ "$(sha "$SRC/SOURCE.sha256")" = "$SOURCE_PINS_SHA" ] || die source_pin_tampered "$SRC/SOURCE.sha256"
  ( cd "$SRC" && sha256sum --strict -c SOURCE.sha256 >/dev/null ) || die source_hash_mismatch "SOURCE.sha256"
  [ "$(sha "$CONTRACT_SRC/inputs/INPUTS.sha256")" = "$INPUTS_SHA" ] || die inputs_pin_tampered "INPUTS.sha256"
  ( cd "$CONTRACT_SRC/inputs" && sha256sum --strict -c INPUTS.sha256 >/dev/null ) || die input_hash_mismatch "INPUTS.sha256"
  [ -d "$STACK/.git" ] || die stack_missing "$STACK"
  git_capture "$STACK" rev-parse HEAD
  [ "$GIT_RC" -eq 0 ] || die git_query_failed "stack rev-parse HEAD rc=$GIT_RC output=$GIT_OUT"
  [ "$GIT_OUT" = "$STACK_COMMIT" ] || die stack_commit_mismatch "$GIT_OUT"
  git_capture "$STACK" status --porcelain -- specification/compiler specification/contracts specification/tests/fixtures/valid_package specification/VERSION
  [ "$GIT_RC" -eq 0 ] || die git_query_failed "stack status rc=$GIT_RC output=$GIT_OUT"
  [ -z "$GIT_OUT" ] || die stack_source_dirty "$GIT_OUT"
  [ -d "$IAP/.git" ] || die project_missing "$IAP"
  git_capture "$IAP" rev-parse HEAD
  [ "$GIT_RC" -eq 0 ] || die git_query_failed "project rev-parse HEAD rc=$GIT_RC output=$GIT_OUT"
  [ "$GIT_OUT" = "$IAP_BASE" ] || die project_base_mismatch "$GIT_OUT"
  git_capture "$IAP" status --porcelain
  [ "$GIT_RC" -eq 0 ] || die git_query_failed "project status rc=$GIT_RC output=$GIT_OUT"
  [ -z "$GIT_OUT" ] || die project_dirty "$GIT_OUT"
  [ -f "$REGISTER" ] && [ -x "$REGISTER" ] || die register_missing "$REGISTER"
  [ -f "$REGISTRY" ] || die registry_missing "$REGISTRY"
  say "SOURCE_OK stack=$STACK_COMMIT project=$IAP_BASE inputs=$(wc -l < "$CONTRACT_SRC/inputs/INPUTS.sha256")"
}

stage_preflight() {
  CURRENT_STAGE=preflight
  python3 -B - "$REGISTRY" "$TASK_ID" <<'PY'
import json, sys
try:
    registry = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(4)
raise SystemExit(3 if sys.argv[2] in registry else 0)
PY
  local identity_rc=$?
  case "$identity_rc" in
    0) ;;
    3) die identity_used "$TASK_ID is already registered (no overwrite, no cleanup, no retry)" ;;
    *) die registry_query_failed "registry query rc=$identity_rc" ;;
  esac
  local op_home bridge journal
  op_home="$(operator_home)" || die operator_missing "$OPERATOR"
  journal="$op_home/.local/state/google-android-agent-stack/bridge/journal.jsonl"
  [ -f "$journal" ] || die journal_missing "$journal"
  python3 -B - "$journal" "$TASK_ID" <<'PY'
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
  local journal_rc=$?
  case "$journal_rc" in
    0) ;;
    3) die identity_used "$TASK_ID already appears in the bridge journal" ;;
    *) die journal_query_failed "journal query rc=$journal_rc" ;;
  esac
  bridge="$op_home/.local/state/google-android-agent-stack/bridge"
  [ -f "$bridge/state.json" ] || die bridge_state_missing "$bridge/state.json"
  python3 -B - "$bridge/state.json" <<'PY'
import json, sys
try:
    status = json.load(open(sys.argv[1], encoding="utf-8")).get("status", "")
except Exception:
    raise SystemExit(4)
raise SystemExit(0 if status in ("WAITING_FOR_GPT", "IDLE") else 3)
PY
  local bridge_rc=$?
  case "$bridge_rc" in
    0) ;;
    3) die bridge_active "bridge is not idle (expected WAITING_FOR_GPT/IDLE)" ;;
    *) die bridge_state_unreadable "state query rc=$bridge_rc" ;;
  esac
  [ ! -e "$bridge/pending_result.json" ] || die bridge_pending "$bridge/pending_result.json"
  for path in "$TASK_ROOT" "$PKG_DEST" "$TASK_ROOT.tmp" "$PKG_DEST.tmp" "$DIAG_SINK"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      die scene_exists "$path exists or is a link (preserved; no overwrite, no cleanup, no retry)"
    fi
  done
  git_capture "$IAP" worktree list --porcelain
  [ "$GIT_RC" -eq 0 ] || die git_query_failed "worktree list rc=$GIT_RC output=$GIT_OUT"
  if printf '%s\n' "$GIT_OUT" | grep -qxF -- "worktree $WORKTREE"; then
    die worktree_registered "the worktree is already registered (preserved; no prune)"
  fi
  stage_diag_check
  say "PREFLIGHT_OK identity_unused=1 scene_absent=1 bridge_idle=1 sink_absent=1"
}

require_root() { [ "$(id -u)" -eq 0 ] || die not_root "full preparation requires root"; }

operator_home() {
  python3 -B -c 'import pwd,sys; print(pwd.getpwnam(sys.argv[1]).pw_dir)' "$OPERATOR"
}

operator_git() { # <worktree> <git args...>; runs as the Bridge user with exact safe.directory
  local wt="$1"; shift
  local op_uid op_gid op_home
  op_uid="$(id -u "$OPERATOR" 2>/dev/null)" || return 1
  op_gid="$(id -g "$OPERATOR" 2>/dev/null)" || return 1
  op_home="$(operator_home)" || return 1
  setpriv --reuid="$op_uid" --regid="$op_gid" --clear-groups --no-new-privs -- \
    env -i HOME="$op_home" PATH="/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
      git -c safe.directory="$wt" -c safe.directory="$IAP" -C "$wt" "$@" 2>&1
}

stage_bridge_git_check() { # <worktree> <git-dir>
  local wt="$1" git_dir="$2" out rc bad
  bad="$(setpriv --reuid="$(id -u "$OPERATOR")" --regid="$(id -g "$OPERATOR")" --clear-groups --no-new-privs -- \
    python3 -I -c 'import os,sys
bad=[]
for p in sys.argv[1:]:
    need = os.R_OK | os.X_OK if os.path.isdir(p) else os.R_OK
    if not os.access(p, need):
        bad.append(p)
print(" ".join(bad))
raise SystemExit(1 if bad else 0)' \
    "$wt" "$wt/.git" "$git_dir" "$git_dir/gitdir" "$git_dir/commondir" "$git_dir/HEAD")" \
    || die bridge_git_access "$OPERATOR cannot traverse/read: $bad"
  out="$(operator_git "$wt" rev-parse --show-toplevel)"; rc=$?
  [ "$rc" -eq 0 ] || die bridge_git_query "rev-parse --show-toplevel rc=$rc output=$out"
  [ "$out" = "$wt" ] || die bridge_git_toplevel "$out"
  out="$(operator_git "$wt" rev-parse --git-common-dir)"; rc=$?
  [ "$rc" -eq 0 ] || die bridge_git_query "rev-parse --git-common-dir rc=$rc output=$out"
  case "$out" in /*) ;; *) out="$wt/$out" ;; esac
  [ "$(realpath -e "$out" 2>/dev/null)" = "$(realpath -e "$IAP/.git" 2>/dev/null)" ] \
    || die bridge_git_common "$out"
  out="$(operator_git "$wt" rev-parse HEAD)"; rc=$?
  [ "$rc" -eq 0 ] || die bridge_git_query "rev-parse HEAD rc=$rc output=$out"
  [ "$out" = "$IAP_BASE" ] || die bridge_git_head "$out"
  out="$(operator_git "$wt" status --porcelain)"; rc=$?
  [ "$rc" -eq 0 ] || die bridge_git_query "status --porcelain rc=$rc output=$out"
  [ -z "$out" ] || die bridge_git_dirty "$out"
  say "BRIDGE_GIT_OK operator=$OPERATOR toplevel=$wt common=$IAP/.git head=$IAP_BASE status=clean"
}

stage_diag_check() {
  CURRENT_STAGE=diag
  [ -f "$LAUNCHER" ] && [ ! -L "$LAUNCHER" ] || die launcher_missing "$LAUNCHER"
  [ "$(sha "$LAUNCHER")" = "$LAUNCHER_CANDIDATE_SHA" ] || die launcher_hash "$(sha "$LAUNCHER")"
  python3 -B - "$LAUNCHER" "$TASK_ID" <<'PY' || die diag_line_mismatch "$LAUNCHER"
import sys
path, task = sys.argv[1], sys.argv[2]
line = ""
for raw in open(path, encoding="utf-8"):
    if raw.startswith('DIAG_ENABLED_TASKS="'):
        line = raw.rstrip("\n")
        break
expected = ('DIAG_ENABLED_TASKS=" BRIDGE-DIAG-003 BRIDGE-VERIFY-004 BRIDGE-VERIFY-007 '
            'BRIDGE-VERIFY-008 IAP-SMOKE-003 IAP-SMOKE-004 IAP-SMOKE-005 IAP-SMOKE-006 '
            'IAP-SMOKE-007 IAP-SMOKE-008 SYSTEM-E2E-002 ' + task + ' "')
assert line == expected, line
PY
  grep -qF '[ -n "$CHECK_CMD" ] && DIAG_ENABLED_TASKS=" "' "$LAUNCHER" || die check_clearing_missing
  grep -qF 'DIAG_ROOT=/var/tmp/aegl-diag' "$LAUNCHER" || die diag_root_missing
  grep -qF 'install -d -o root -g root -m 0700 -- "$DIAG_ROOT" "$DIAG_DIR"' "$LAUNCHER" || die diag_sink_creation_missing
  grep -qF 'export AEGL_DIAG_DIR="$DIAG_DIR"' "$LAUNCHER" || die diag_export_missing
  grep -qF 'AEGL_DIAG_DIR="${AEGL_DIAG_DIR:-}" AEGL_GUARD_EVIDENCE="${AEGL_TRIAL_EVIDENCE:-$AEGL_DIAG_DIR}"' "$LAUNCHER" || die diag_guard_wiring_missing
  grep -qF 'OBS_PRE_CMD="python3 $TOOL_CLIENT --socket $SOCK --event pre_tool_call' "$LAUNCHER" || die diag_observer_pre_missing
  grep -qF 'OBS_POST_CMD="python3 $TOOL_CLIENT --socket $SOCK --event post_tool_call' "$LAUNCHER" || die diag_observer_post_missing
  case "$DIAG_SINK" in /var/tmp/aegl-diag/*) ;; *) die diag_sink_path "$DIAG_SINK" ;; esac
  case "$DIAG_SINK" in /run/aegl-model/*) die diag_sink_under_run "$DIAG_SINK" ;; esac
  if [ -e "$DIAG_ROOT" ]; then
    [ "$(stat -c '%U:%G %a' "$DIAG_ROOT")" = "root:root 700" ] || die diag_root_perms "$(stat -c '%U:%G %a' "$DIAG_ROOT")"
  fi
  if [ -d "$DIAG_ROOT" ] && [ ! -x "$DIAG_ROOT" ]; then
    [ "$(id -u)" -eq 0 ] || die diag_sink_unknown "cannot traverse $DIAG_ROOT as $(id -un); sink state is UNKNOWN"
  fi
  if [ -e "$DIAG_SINK" ] || [ -L "$DIAG_SINK" ]; then
    die diag_sink_in_use "$DIAG_SINK exists or is a link (preserved)"
  fi
  ( cd "$SRC" && sha256sum --strict -c DEPENDENCY-PINS.sha256 >/dev/null ) || die dependency_pins_changed
  say "DIAG_OK task=$TASK_ID sink=$DIAG_SINK launcher=$LAUNCHER_CANDIDATE_SHA"
}

write_pin() { # <manifest_sha256>
  python3 -B - "$TASK_ROOT/INPUTS-PIN.json" "$TASK_ID" "$WORKTREE" "$SCRATCH" "$IAP" \
    "$PKG_DEST" "$1" "$INPUTS_SHA" "$STACK_COMMIT" "$IAP_BASE" <<'PY' || return 1
import json, os, sys
path, task_id, worktree, scratch, project, contract, manifest_sha, inputs_sha, stack_commit, iap_base = sys.argv[1:11]
data = {
    "task_id": task_id,
    "fixture_id": "FIXTURE-B1-CONTRACT",
    "worktree": worktree,
    "scratch": scratch,
    "project": project,
    "contract_package": contract,
    "contract_manifest_sha256": manifest_sha,
    "inputs_sha256": inputs_sha,
    "stack_commit": stack_commit,
    "iap_base_commit": iap_base,
}
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as handle:
    json.dump(data, handle, indent=2, sort_keys=True)
    handle.write("\n")
    handle.flush()
    os.fsync(handle.fileno())
os.chmod(tmp, 0o644)
os.replace(tmp, path)
PY
}

stage_scene() {
  CURRENT_STAGE=scene
  require_root
  install -d -m 0750 -o root -g root "$TASK_ROOT" || die task_root "$TASK_ROOT"
  write_pin "" || die pin_initial "$TASK_ROOT/INPUTS-PIN.json"
  local saved_umask wt_rc wt_out
  saved_umask="$(umask)"
  umask 022
  git_capture "$IAP" worktree add --detach "$WORKTREE" "$IAP_BASE"
  wt_rc="$GIT_RC"; wt_out="$GIT_OUT"
  umask "$saved_umask"
  [ "$wt_rc" -eq 0 ] || die worktree_add "rc=$wt_rc output=$wt_out"
  chown -R "$AI_USER:$AI_USER" "$WORKTREE" || die worktree_chown "$WORKTREE"
  chmod -R u=rwX,go=rX "$WORKTREE" || die worktree_chmod "$WORKTREE"
  git_capture_worktree "$WORKTREE" "$IAP" rev-parse --absolute-git-dir
  [ "$GIT_RC" -eq 0 ] || die git_query_failed "worktree absolute-git-dir rc=$GIT_RC output=$GIT_OUT"
  local git_dir="$GIT_OUT"
  case "$git_dir" in "$IAP"/.git/worktrees/*) ;; *) die worktree_gitdir "$git_dir" ;; esac
  [ -d "$git_dir" ] && [ ! -L "$git_dir" ] || die worktree_gitdir "$git_dir"
  chmod 0755 "$git_dir" || die gitdir_mode "$git_dir"
  local meta
  for meta in gitdir commondir HEAD index ORIG_HEAD; do
    [ ! -e "$git_dir/$meta" ] || chmod 0644 "$git_dir/$meta" || die gitdir_mode "$git_dir/$meta"
  done
  for meta in logs refs; do
    [ ! -e "$git_dir/$meta" ] || chmod 0755 "$git_dir/$meta" || die gitdir_mode "$git_dir/$meta"
  done
  [ ! -e "$git_dir/logs/HEAD" ] || chmod 0644 "$git_dir/logs/HEAD" || die gitdir_mode "$git_dir/logs/HEAD"
  install -d -o "$AI_USER" -g "$AI_USER" -m 0750 "$SCRATCH" || die scratch "$SCRATCH"
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m u:"$AI_USER":x "$TASK_ROOT" || die acl_ai "$TASK_ROOT"
    if [ "$OPERATOR" != "root" ]; then
      setfacl -m u:"$OPERATOR":x "$TASK_ROOT" || die acl_operator "$TASK_ROOT"
    fi
  else
    die setfacl_missing "ACL support is required for task-root traversal"
  fi
  stage_bridge_git_check "$WORKTREE" "$git_dir"
  local ai_uid ai_gid
  ai_uid="$(id -u "$AI_USER" 2>/dev/null)" || die ai_user_missing "$AI_USER"
  ai_gid="$(id -g "$AI_USER" 2>/dev/null)" || die ai_user_missing "$AI_USER"
  setpriv --reuid="$ai_uid" --regid="$ai_gid" --clear-groups --no-new-privs -- \
    python3 -I -c 'import os,sys; sys.exit(0 if os.access(sys.argv[1], os.W_OK) and os.access(sys.argv[2], os.W_OK) else 1)' \
    "$WORKTREE" "$SCRATCH" || die ai_permission "$AI_USER cannot write the worktree/scratch"
  git_capture_worktree "$WORKTREE" "$IAP" rev-parse HEAD
  [ "$GIT_RC" -eq 0 ] || die git_query_failed "worktree rev-parse HEAD rc=$GIT_RC output=$GIT_OUT"
  [ "$GIT_OUT" = "$IAP_BASE" ] || die worktree_head "$GIT_OUT"
  say "SCENE_OK worktree=$WORKTREE scratch=$SCRATCH"
}

stage_compile() {
  CURRENT_STAGE=compile
  PREP_ROOT="$(mktemp -d /var/tmp/.${TASK_ID}-prep.XXXXXX)" || die stage "mktemp"
  STAGE="$PREP_ROOT/$TASK_ID"
  mkdir -p "$STAGE" || die stage_dir "$STAGE"
  cp -a "$CONTRACT_SRC"/. "$STAGE"/ || die stage_copy "$STAGE"
  chown -R root:root "$STAGE" || die stage_owner "$STAGE"
  chmod -R u=rwX,go= "$STAGE" || die stage_mode "$STAGE"
  export PYTHONDONTWRITEBYTECODE=1
  python3 -B "$STAGE/inputs/compiler/hash_manifest.py" "$STAGE" || die compile_manifest "$STAGE"
  local manifest_sha prompt_sha
  manifest_sha="$(sha "$STAGE/manifest.json")"
  [ "$manifest_sha" = "$CONTRACT_MANIFEST_SHA" ] || die contract_manifest_hash "$manifest_sha"
  python3 -B "$STAGE/inputs/compiler/build_contract.py" "$STAGE" || die compile_contract "$STAGE"
  prompt_sha="$(sha "$STAGE/EXECUTOR-PROMPT.md")"
  [ "$prompt_sha" = "$CONTRACT_PROMPT_SHA" ] || die contract_prompt_hash "$prompt_sha"
  python3 -B "$STAGE/inputs/compiler/validate_package.py" "$STAGE" --project-root "$TASK_ROOT" \
    || die validate_package "$STAGE"
  python3 -B - "$STAGE" <<'PY' || die packaged_artifacts "$STAGE"
import hashlib, json, os, sys
pkg = sys.argv[1]
def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()
load = lambda name: json.load(open(os.path.join(pkg, name), encoding="utf-8"))
report = load("validation-report.json")
assert report.get("status") == "READY" and not report.get("errors"), "not READY"
gates = report.get("gates") or {}
assert gates and all(value == "PASS" for value in gates.values()), "gate not PASS"
assert load("READY.json").get("status") == "READY", "READY.json"
manifest = load("manifest.json")
for entry in manifest["entries"]:
    full = os.path.join(pkg, entry["path"])
    assert os.path.isfile(full) and sha(full) == entry["sha256"], entry["path"]
PY
  say "COMPILE_OK package=$STAGE manifest_sha256=$manifest_sha prompt_sha256=$prompt_sha"
}

stage_install() {
  CURRENT_STAGE=install
  require_root
  local manifest_sha installed_sha installed_prompt
  manifest_sha="$(sha "$STAGE/manifest.json")"
  install -d -m 0755 -o root -g root "$PKG_DEST" || die package_dir "$PKG_DEST"
  cp -a "$STAGE"/. "$PKG_DEST"/ || die package_copy "$PKG_DEST"
  chown -R root:root "$PKG_DEST" || die package_chown "$PKG_DEST"
  chmod -R u=rwX,go=rX "$PKG_DEST" || die package_chmod "$PKG_DEST"
  installed_sha="$(sha "$PKG_DEST/manifest.json")"
  [ "$installed_sha" = "$manifest_sha" ] || die package_hash "$installed_sha != $manifest_sha"
  [ "$installed_sha" = "$CONTRACT_MANIFEST_SHA" ] || die contract_manifest_hash "$installed_sha"
  installed_prompt="$(sha "$PKG_DEST/EXECUTOR-PROMPT.md")"
  [ "$installed_prompt" = "$CONTRACT_PROMPT_SHA" ] || die contract_prompt_hash "$installed_prompt"
  [ -z "$(find "$PKG_DEST" -perm /022 -print -quit 2>/dev/null)" ] || die package_writable "group/other-writable member"
  write_pin "$manifest_sha" || die pin_final "$TASK_ROOT/INPUTS-PIN.json"
  say "INSTALL_OK contract=$PKG_DEST manifest_sha256=$manifest_sha prompt_sha256=$installed_prompt"
}

stage_register() {
  CURRENT_STAGE=register
  require_root
  "$REGISTER" register \
    --task-id "$TASK_ID" \
    --worktree "$WORKTREE" \
    --scratch "$SCRATCH" \
    --project "$IAP" \
    --contract-package "$PKG_DEST" || die register_failed "$TASK_ID"
  python3 -B - "$REGISTRY" "$TASK_ID" "$WORKTREE" "$SCRATCH" "$IAP" "$PKG_DEST" <<'PY' \
    || die registry_verify "$TASK_ID"
import json, os, sys
registry, task, worktree, scratch, project, contract = sys.argv[1:7]
entry = json.load(open(registry, encoding="utf-8")).get(task)
assert isinstance(entry, dict), "not registered"
want = {"worktree": worktree, "scratch": scratch, "project": project, "contract_package": contract}
assert set(entry) == set(want), "unexpected registry fields"
for key, value in want.items():
    assert os.path.realpath(entry[key]) == os.path.realpath(value), key
PY
  say "REGISTER_OK task=$TASK_ID"
}

stage_gate() {
  CURRENT_STAGE=gate
  local manifest_sha op_uid op_gid op_home out rc
  manifest_sha="$(sha "$PKG_DEST/manifest.json")"
  [ "$manifest_sha" = "$CONTRACT_MANIFEST_SHA" ] || die contract_manifest_hash "$manifest_sha"
  op_uid="$(id -u "$OPERATOR" 2>/dev/null)" || die operator_missing "$OPERATOR"
  op_gid="$(id -g "$OPERATOR" 2>/dev/null)" || die operator_missing "$OPERATOR"
  op_home="$(operator_home)" || die operator_missing "$OPERATOR"
  out="$(setpriv --reuid="$op_uid" --regid="$op_gid" --clear-groups --no-new-privs -- \
    env -i HOME="$op_home" PATH="/usr/local/bin:/usr/bin:/bin" LANG=C.UTF-8 \
      PYTHONDONTWRITEBYTECODE=1 GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0 \
      python3 -B - "$STACK/orchestration/hermes/bridge" "$PKG_DEST" "$manifest_sha" "$TASK_ID" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import contract_executor as ce
try:
    result = ce.gate(sys.argv[2], sys.argv[3], project="ImageAnalysisFactory", task_id=sys.argv[4])
    print("GATE_PASS " + result["project"] + " " + result["manifest_sha256"])
except ce.GateError as exc:
    print("GATE_REJECTED " + exc.code + ": " + exc.message)
    raise SystemExit(1)
PY
)"; rc=$?
  [ "$rc" -eq 0 ] || die gate_failed "rc=$rc output=$out"
  say "GATE_OK $out"
}

main() {
  for arg in "$@"; do
    case "$arg" in
      --verify-only) VERIFY_ONLY=1 ;;
      -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
      *) die usage "unknown argument: $arg" ;;
    esac
  done
  stage_source
  stage_preflight
  if [ "$VERIFY_ONLY" -eq 1 ]; then
    say "VERIFY_ONLY=OK (no writes, no root, no model, nothing sent)"
    exit 0
  fi
  stage_scene
  stage_compile
  stage_install
  stage_diag_check
  stage_register
  stage_gate
  say "PREP_COMPLETE task=$TASK_ID contract=$PKG_DEST manifest_sha256=$CONTRACT_MANIFEST_SHA prompt_sha256=$CONTRACT_PROMPT_SHA diag_sink=$DIAG_SINK launcher_sha256=$LAUNCHER_CANDIDATE_SHA"
  say "WORKTREE=$WORKTREE SCRATCH=$SCRATCH PKG_STAGE=$STAGE STAGE_RETAINED=$PREP_ROOT"
  say "NEXT: no model was called and nothing was sent. A real run needs a separate one-execution approval."
}

main "$@"
