#!/usr/bin/env bash
# prepare.sh — SYSTEM-E2E-001 trusted preparation (NO send, NO model, NO execution).
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

TASK_ID="SYSTEM-E2E-001"
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
SOURCE_PINS_SHA="958c89103edc05df35997e4891ebfafde8101ab93871289f34091274c233c6a1"
INPUTS_SHA="509cbc0f44d8294d4059a77397c4bfae95071caabb64844ce2f2ff3cc260eec6"

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTRACT_SRC="$SRC/contract/$TASK_ID"
CURRENT_STAGE=""
VERIFY_ONLY=0
STAGE=""

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
  for tool in python3 git sha256sum awk realpath setpriv setfacl; do need "$tool"; done
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
  for path in "$TASK_ROOT" "$PKG_DEST" "$TASK_ROOT.tmp" "$PKG_DEST.tmp"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      die scene_exists "$path exists or is a link (preserved; no overwrite, no cleanup, no retry)"
    fi
  done
  git_capture "$IAP" worktree list --porcelain
  [ "$GIT_RC" -eq 0 ] || die git_query_failed "worktree list rc=$GIT_RC output=$GIT_OUT"
  if printf '%s\n' "$GIT_OUT" | grep -qxF -- "worktree $WORKTREE"; then
    die worktree_registered "the worktree is already registered (preserved; no prune)"
  fi
  say "PREFLIGHT_OK identity_unused=1 scene_absent=1"
}

require_root() { [ "$(id -u)" -eq 0 ] || die not_root "full preparation requires root"; }

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
  git_capture "$IAP" worktree add --detach "$WORKTREE" "$IAP_BASE"
  [ "$GIT_RC" -eq 0 ] || die worktree_add "rc=$GIT_RC output=$GIT_OUT"
  chown -R "$AI_USER:$AI_USER" "$WORKTREE" || die worktree_chown "$WORKTREE"
  chmod -R u=rwX,go=rX "$WORKTREE" || die worktree_chmod "$WORKTREE"
  install -d -o "$AI_USER" -g "$AI_USER" -m 0750 "$SCRATCH" || die scratch "$SCRATCH"
  if command -v setfacl >/dev/null 2>&1; then
    setfacl -m u:"$AI_USER":x "$TASK_ROOT" || die acl_ai "$TASK_ROOT"
    if [ "$OPERATOR" != "root" ]; then
      setfacl -m u:"$OPERATOR":x "$TASK_ROOT" || die acl_operator "$TASK_ROOT"
    fi
  else
    die setfacl_missing "ACL support is required for task-root traversal"
  fi
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
  STAGE="$(mktemp -d /var/tmp/.${TASK_ID}-prep.XXXXXX)" || die stage "mktemp"
  cp -a "$CONTRACT_SRC"/. "$STAGE"/ || die stage_copy "$STAGE"
  export PYTHONDONTWRITEBYTECODE=1
  python3 -B "$STAGE/inputs/compiler/hash_manifest.py" "$STAGE" || die compile_manifest "$STAGE"
  python3 -B "$STAGE/inputs/compiler/build_contract.py" "$STAGE" || die compile_contract "$STAGE"
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
  say "COMPILE_OK package=$STAGE manifest_sha256=$(sha "$STAGE/manifest.json")"
}

stage_install() {
  CURRENT_STAGE=install
  require_root
  local manifest_sha installed_sha
  manifest_sha="$(sha "$STAGE/manifest.json")"
  install -d -m 0755 -o root -g root "$PKG_DEST" || die package_dir "$PKG_DEST"
  cp -a "$STAGE"/. "$PKG_DEST"/ || die package_copy "$PKG_DEST"
  chown -R root:root "$PKG_DEST" || die package_chown "$PKG_DEST"
  chmod -R u=rwX,go=rX "$PKG_DEST" || die package_chmod "$PKG_DEST"
  installed_sha="$(sha "$PKG_DEST/manifest.json")"
  [ "$installed_sha" = "$manifest_sha" ] || die package_hash "$installed_sha != $manifest_sha"
  [ -z "$(find "$PKG_DEST" -perm /022 -print -quit 2>/dev/null)" ] || die package_writable "group/other-writable member"
  write_pin "$manifest_sha" || die pin_final "$TASK_ROOT/INPUTS-PIN.json"
  say "INSTALL_OK contract=$PKG_DEST manifest_sha256=$manifest_sha"
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
  stage_register
  say "PREP_COMPLETE task=$TASK_ID contract=$PKG_DEST manifest_sha256=$(sha "$PKG_DEST/manifest.json")"
  say "WORKTREE=$WORKTREE SCRATCH=$SCRATCH STAGE_RETAINED=$STAGE"
  say "NEXT: no model was called and nothing was sent. A real run needs a separate one-execution approval."
}

main "$@"
