#!/usr/bin/env bash
# deploy-glue-tests.sh — targeted checks for stack deploy glue only.
# Does NOT re-run broker-tests (18) or promote-stack-tests (9).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
STACK="$AEGL_ROOT/recovery/promote-to-main-stack.sh"
CORE="$AEGL_ROOT/recovery/promotion_core.py"
ACL="$AEGL_ROOT/recovery/install-promote-target-acl.sh"

PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }

ST="$(mktemp -d /var/tmp/aegl-deploy-glue-XXXXXX)" || { echo "mktemp failed"; exit 2; }
cleanup(){ chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

# --- 1. no auto-elevate; mismatch must refuse --- #
if grep -nE 'elevating --commit|COMMIT="\$BRANCH_TIP"|COMMIT=\$BRANCH_TIP' "$STACK" >/dev/null; then
  no "stack script still contains tip elevation"
else
  ok "stack script has no tip elevation"
fi
grep -q 'refusing tip substitution' "$STACK" && ok "stack refuses tip mismatch" || no "missing tip mismatch reject"

# --- 2. no unused controller token on broker-client path --- #
if grep -nE 'CONTROLLER_TOKEN|openssl rand|controller\.' "$STACK" >/dev/null; then
  no "stack still mints unused controller token"
else
  ok "stack does not mint controller token for broker client path"
fi

# --- 3. ACL installer uses command-level safe.directory --- #
grep -q 'safe.directory=\$PROJ' "$ACL" && ok "ACL installer sets exact safe.directory" || no "ACL installer missing safe.directory"
grep -qE 'safe\.directory=\*|safe\.directory=\.' "$ACL" && no "ACL installer uses unsafe safe.directory glob" || ok "ACL installer has no safe.directory glob"

# --- 4. promotion_core: safe.directory on exact path + status rc check --- #
python3 - "$CORE" "$ST" <<'PY'
import os, sys, subprocess, tempfile, shutil
core_path, st = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.dirname(core_path))
import promotion_core as pc

fails = []
# 4a. _safe_directory_args is exact realpaths, never '*'
args = pc._safe_directory_args(st)
if any("*" in a for a in args):
    fails.append("safe.directory contains glob")
# 4b. freeze clean repo
repo = os.path.join(st, "repo")
os.makedirs(repo)
subprocess.run(["git", "init", "-q", repo], check=True)
open(os.path.join(repo, "README.md"), "w").write("x\n")
subprocess.run(["git", "-C", repo, "add", "-A"], check=True)
subprocess.run(["git", "-C", repo, "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "t"], check=True)
try:
    c, t = pc.freeze_candidate_commit(repo)
    assert len(c) == 40 and len(t) == 40
except Exception as exc:
    fails.append("freeze clean failed: %s" % exc)
# 4c. dirty rejected
open(os.path.join(repo, "README.md"), "a").write("dirt\n")
try:
    pc.freeze_candidate_commit(repo)
    fails.append("dirty worktree not rejected")
except RuntimeError as exc:
    if "worktree_dirty" not in str(exc):
        fails.append("dirty reason=%s" % exc)
# restore clean
subprocess.run(["git", "-C", repo, "checkout", "--", "README.md"], check=True)
# 4d. status failure must not look clean (chmod away .git)
gitdir = os.path.join(repo, ".git")
mode = os.stat(gitdir).st_mode & 0o777
os.chmod(gitdir, 0)
try:
    pc.freeze_candidate_commit(repo)
    fails.append("status failure treated as success")
except RuntimeError as exc:
    if "worktree_status_failed" not in str(exc) and "candidate_head_missing" not in str(exc):
        fails.append("status fail reason=%s" % exc)
finally:
    os.chmod(gitdir, mode)
# 4e. argv includes safe.directory=<realpath>
rp = os.path.realpath(repo)
safe_args = pc._safe_directory_args(repo)
if ("-c" not in safe_args) or (("safe.directory=%s" % rp) not in safe_args):
    fails.append("safe.directory missing exact repo path: %s" % safe_args)

sys.exit(1 if fails else 0)
PY
if [ $? -eq 0 ]; then ok "promotion_core safe.directory + status rc"; else no "promotion_core glue checks"; fi

# --- 5. stack early preflight ordering (before restore/ACL) --- #
i0="$(grep -n '== 0\. Throwaway' "$STACK" | head -1 | cut -d: -f1)"
iB="$(grep -n '== B\. Confirm only the 10' "$STACK" | head -1 | cut -d: -f1)"
iC="$(grep -n '== C\. Restore' "$STACK" | head -1 | cut -d: -f1)"
iD="$(grep -n '== D\. Trusted deploy' "$STACK" | head -1 | cut -d: -f1)"
if [ -n "$i0" ] && [ -n "$iB" ] && [ -n "$iC" ] && [ -n "$iD" ] \
   && [ "$i0" -lt "$iB" ] && [ "$iB" -lt "$iC" ] && [ "$iC" -lt "$iD" ]; then
  ok "preflight ordered before restore/ACL"
else
  no "preflight ordering wrong i0=$i0 iB=$iB iC=$iC iD=$iD"
fi

echo "DEPLOY_GLUE_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
