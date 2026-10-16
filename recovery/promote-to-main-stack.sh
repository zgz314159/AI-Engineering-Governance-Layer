#!/usr/bin/env bash
# promote-to-main-stack.sh — one-shot authorized full-stack promote onto main.
#
# MUST be delivered from a fixed commit (never a mutable worktree as root):
#
#   TIP=<full-40-hex>
#   AEGL=/home/zhong/Projects/AI-Engineering-Governance-Layer
#   git -C "$AEGL" show "$TIP:recovery/promote-to-main-stack.sh" \
#     | sudo bash -s -- --repo "$AEGL" --commit "$TIP"
#
# --commit is the install source AND the promote candidate for the entire run.
# Branch tip movement never substitutes a different SHA; mismatch is a hard reject.
#
# Order: throwaway cross-UID preflight (no formal mutate) → gradle restore →
# broker+ACL install from the same --commit → external candidate →
# register/record (root) / promote (aegl-ai via SO_PEERCRED) → formal switch main.
# This path calls the broker client directly; it does not mint controller tokens.
set -euo pipefail

REPO=""; COMMIT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --commit) COMMIT="${2:-}"; shift 2 ;;
    *) printf 'STACK_ERROR: unknown option %s\n' "$1" >&2; exit 2 ;;
  esac
done

PIN=50e97c2cd7a37755bbfafc9c5b7cafaece252f6e
TASK_ID="capture-hook-classfix-promote"
BROKER_USER="aegl-promote"
AI_USER="aegl-ai"
OP_USER="zhong"
GRADLE_DIST_FILES=(
  dist/dependency-submission/main/index.js
  dist/dependency-submission/main/index.js.map
  dist/dependency-submission/post/index.js
  dist/dependency-submission/post/index.js.map
  dist/setup-gradle/main/index.js
  dist/setup-gradle/main/index.js.map
  dist/setup-gradle/post/index.js
  dist/setup-gradle/post/index.js.map
  dist/wrapper-validation/main/index.js
  dist/wrapper-validation/main/index.js.map
)
STACK_FILES=(
  recovery/promote-to-main-stack.sh
  recovery/install-broker.sh
  recovery/install-promote-target-acl.sh
  recovery/promotion_broker.py
  recovery/promotion_core.py
  bin/aegl-promote-broker
)

say(){ printf '%s\n' "$*"; }
fail(){ printf 'STACK_ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || fail "must run as root"
[ -n "$REPO" ] || fail "--repo is required"
[ -n "$COMMIT" ] || fail "--commit is required"
[ -d "$REPO/.git" ] || fail "--repo is not a git repository: $REPO"
case "$COMMIT" in [0-9a-f]*) : ;; *) fail "--commit must be full 40-hex" ;; esac
[ "${#COMMIT}" -eq 40 ] || fail "--commit must be full 40-hex (got ${#COMMIT})"
git -C "$REPO" cat-file -e "$COMMIT^{commit}" 2>/dev/null || fail "commit not in repo: $COMMIT"

AEGL="$REPO"
GA="$AEGL/upstream/gradle-actions"
BROKER_BIN=/usr/local/lib/aegl-promote/aegl-promote-broker
SOCK=/run/aegl-promote/broker.sock
export AEGL_BROKER_SOCKET="$SOCK"

# --------------------------------------------------------------------------- #
# 0. Throwaway preflight — before formal restore / service update / project ACL
# --------------------------------------------------------------------------- #
say "== 0. Throwaway cross-UID preflight (no formal mutate) =="
for t in git setfacl runuser python3; do
  command -v "$t" >/dev/null 2>&1 || fail "missing tool: $t"
done
id "$OP_USER" >/dev/null 2>&1 || fail "missing operator user: $OP_USER"
id "$BROKER_USER" >/dev/null 2>&1 || fail "missing broker user: $BROKER_USER (install broker first)"
id "$AI_USER" >/dev/null 2>&1 || fail "missing AI user: $AI_USER"
for f in "${STACK_FILES[@]}"; do
  git -C "$AEGL" cat-file -e "$COMMIT:$f" 2>/dev/null || fail "required path missing in --commit: $f"
done
BRANCH_TIP="$(git -C "$AEGL" rev-parse --verify plan/capture-hook-classfix)"
[ "$BRANCH_TIP" = "$COMMIT" ] \
  || fail "plan/capture-hook-classfix is $BRANCH_TIP; --commit is $COMMIT (refusing tip substitution)"

PRE=""
EXT=""
cleanup_all(){
  if [ -n "${EXT:-}" ] && [ -d "$EXT" ]; then
    git -C "$AEGL" worktree remove --force "$EXT/wt" 2>/dev/null || true
    chmod -R u+w "$EXT" 2>/dev/null || true
    rm -rf "$EXT"
  fi
  if [ -n "${PRE:-}" ] && [ -d "$PRE" ]; then
    chmod -R u+w "$PRE" 2>/dev/null || true
    rm -rf "$PRE"
  fi
}
trap cleanup_all EXIT

PRE="$(mktemp -d /var/tmp/aegl-stack-preflight-XXXXXX)" || fail "mktemp preflight failed"
chmod 0750 "$PRE"
chown root:root "$PRE"
# Operator creates the throwaway repo; broker only gets ACL on this PRE tree.
setfacl -m "u:${OP_USER}:rwx" "$PRE"
runuser -u "$OP_USER" -- git -c "safe.directory=$PRE/repo" init -q "$PRE/repo"
runuser -u "$OP_USER" -- bash -c "echo pre > '$PRE/repo/README.md'"
runuser -u "$OP_USER" -- git -c "safe.directory=$PRE/repo" -C "$PRE/repo" add -A
runuser -u "$OP_USER" -- git -c "safe.directory=$PRE/repo" -C "$PRE/repo" \
  -c user.email=t@t -c user.name=t commit -qm preflight
PRE_HEAD="$(runuser -u "$OP_USER" -- git -c "safe.directory=$PRE/repo" -C "$PRE/repo" rev-parse HEAD)"
[ "${#PRE_HEAD}" -eq 40 ] || fail "preflight repo head missing"
# aegl-promote: traverse + read only inside PRE (not /var/tmp broadly, not AEGL).
setfacl -m "u:${BROKER_USER}:--x" "$PRE"
setfacl -R -m "u:${BROKER_USER}:r-X" "$PRE/repo"
BROKER_HEAD="$(runuser -u "$BROKER_USER" -- git \
  -c "safe.directory=$PRE/repo" \
  -c "core.hooksPath=/dev/null" \
  -c "core.fsmonitor=false" \
  -c "core.attributesFile=/dev/null" \
  -C "$PRE/repo" rev-parse --verify HEAD 2>/dev/null)" \
  || fail "aegl-promote cannot rev-parse throwaway repo (ACL/safe.directory)"
[ "$BROKER_HEAD" = "$PRE_HEAD" ] || fail "aegl-promote saw unexpected head"
BROKER_ST_RC=0
BROKER_ST_OUT="$(runuser -u "$BROKER_USER" -- git \
  -c "safe.directory=$PRE/repo" \
  -c "core.hooksPath=/dev/null" \
  -c "core.fsmonitor=false" \
  -c "core.attributesFile=/dev/null" \
  -C "$PRE/repo" status --porcelain 2>/dev/null)" || BROKER_ST_RC=$?
[ "$BROKER_ST_RC" = 0 ] || fail "aegl-promote git status failed in throwaway (rc=$BROKER_ST_RC)"
[ -z "$BROKER_ST_OUT" ] || fail "throwaway repo unexpectedly dirty"
# aegl-ai: only what promote needs — reach the broker socket (group), not PRE/AEGL.
if [ -S "$SOCK" ]; then
  runuser -u "$AI_USER" -- test -S "$SOCK" \
    || fail "aegl-ai cannot access broker socket $SOCK"
else
  say "  note: broker socket absent until step D (identity/group check only)"
  id -nG "$AI_USER" | tr ' ' '\n' | grep -qx aegl-broker \
    || fail "aegl-ai not in aegl-broker group (cannot request promote)"
fi
# Negative: aegl-ai must not write the throwaway candidate tree.
if runuser -u "$AI_USER" -- touch "$PRE/repo/.ai-probe" 2>/dev/null; then
  rm -f "$PRE/repo/.ai-probe"
  fail "aegl-ai can write throwaway repo — ACL too broad"
fi
chmod -R u+w "$PRE" 2>/dev/null || true
rm -rf "$PRE"
PRE=""
say "  preflight OK commit=$COMMIT (throwaway cleaned)"

# --------------------------------------------------------------------------- #
# A–F formal path — still pinned to the same --commit
# --------------------------------------------------------------------------- #
say "== A. Commit bind (exact --commit; no tip elevate) =="
git -C "$AEGL" merge-base --is-ancestor feat/beads-adapter "$COMMIT" \
  || fail "feat/beads-adapter is not an ancestor of --commit"
test "$(git -C "$AEGL" rev-list --count "$COMMIT"..feat/beads-adapter)" = 0 \
  || fail "feat/beads-adapter has commits not in --commit"
test "$(git -C "$AEGL" ls-tree "$COMMIT" upstream/gradle-actions | awk '{print $3}')" = "$PIN" \
  || fail "gradle-actions gitlink is not $PIN"
MAIN_BEFORE="$(git -C "$AEGL" rev-parse refs/heads/main)"
say "  commit=$COMMIT main_before=$MAIN_BEFORE"

say "== B. Confirm only the 10 expected gradle-actions deletions =="
[ -d "$GA/.git" ] || [ -f "$GA/.git" ] || fail "gradle-actions checkout missing"
mapfile -t DIRT < <(git -C "$GA" status --porcelain)
if [ "${#DIRT[@]}" -eq 0 ]; then
  say "  working tree already clean (restore may be a no-op)"
else
  [ "${#DIRT[@]}" -eq 10 ] || fail "unexpected dirt count=${#DIRT[@]} (want 0 or 10); aborting"
  for line in "${DIRT[@]}"; do
    case "$line" in
      " D dist/"*) : ;;
      *) fail "unexpected dirt line (abort): $line" ;;
    esac
  done
  for f in "${GRADLE_DIST_FILES[@]}"; do
    printf '%s\n' "${DIRT[@]}" | grep -qx " D $f" || fail "missing expected deletion: $f"
  done
  say "  exactly 10 expected deletions confirmed"
fi

say "== C. Restore pinned gradle-actions dist (formal tree; pin only) =="
runuser -u "$OP_USER" -- git -C "$GA" restore --source="$PIN" -- "${GRADLE_DIST_FILES[@]}"
test -z "$(git -C "$GA" status --porcelain)" || fail "gradle-actions still dirty after restore"
say "  gradle-actions clean at pin $PIN"

say "== D. Trusted deploy: broker + target ACL from fixed --commit (not worktree) =="
git -C "$AEGL" show "$COMMIT:recovery/install-broker.sh" \
  | bash -s -- --repo "$AEGL" --projects-root "$(dirname "$AEGL")" --commit "$COMMIT"
git -C "$AEGL" show "$COMMIT:recovery/install-promote-target-acl.sh" \
  | bash -s -- --repo "$AEGL" --project "$AEGL" --commit "$COMMIT"
[ -x "$BROKER_BIN" ] || fail "broker binary missing after install"
systemctl is-active --quiet aegl-promote-broker || fail "aegl-promote-broker not active"
runuser -u "$AI_USER" -- test -S "$SOCK" || fail "aegl-ai cannot access $SOCK after install"

say "== E. External candidate + register/record/promote =="
EXT="$(mktemp -d /var/tmp/aegl-promote-cand-XXXXXX)" || fail "mktemp candidate failed"
chmod 0750 "$EXT"
chown root:root "$EXT"
setfacl -m "u:${OP_USER}:rwx" "$EXT"
runuser -u "$OP_USER" -- git -C "$AEGL" worktree add -f "$EXT/wt" "$COMMIT"
# aegl-promote must freeze the candidate (service UID); scope ACL to this EXT + wt gitdir.
setfacl -m "u:${BROKER_USER}:--x" "$EXT"
setfacl -R -m "u:${BROKER_USER}:r-X" "$EXT/wt"
WT_GITDIR="$(runuser -u "$OP_USER" -- git -c "safe.directory=$EXT/wt" -C "$EXT/wt" rev-parse --absolute-git-dir)"
[ -n "$WT_GITDIR" ] && [ -d "$WT_GITDIR" ] || fail "candidate gitdir missing"
setfacl -R -m "u:${BROKER_USER}:r-X" "$WT_GITDIR"
# aegl-ai: socket only — no grant on EXT.
if runuser -u "$AI_USER" -- touch "$EXT/wt/.ai-probe" 2>/dev/null; then
  rm -f "$EXT/wt/.ai-probe"
  fail "aegl-ai can write candidate worktree — ACL too broad"
fi
ST_RC=0
ST_OUT="$(runuser -u "$OP_USER" -- git -c "safe.directory=$EXT/wt" -C "$EXT/wt" status --porcelain 2>/dev/null)" || ST_RC=$?
[ "$ST_RC" = 0 ] || fail "candidate git status failed (rc=$ST_RC); refusing to treat as clean"
[ -z "$ST_OUT" ] || fail "candidate worktree dirty"
BASE="$(git -C "$AEGL" merge-base refs/heads/main "$COMMIT")"
REG_JSON="$(python3 -c 'import json,sys;print(json.dumps({"op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],"worktree":sys.argv[4],"branch":"plan/capture-hook-classfix","target_ref":"refs/heads/main"}))' \
  "$TASK_ID" "$AEGL" "$BASE" "$EXT/wt")"
REG_OUT="$("$BROKER_BIN" client --socket "$SOCK" --request "$REG_JSON")"
echo "$REG_OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d.get("decision")=="REGISTERED",d'
REC_OUT="$("$BROKER_BIN" client --socket "$SOCK" --request "{\"op\":\"record\",\"task_id\":\"$TASK_ID\",\"verify_result\":\"PASS\"}")"
echo "$REC_OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d.get("decision")=="RECORDED",d'
APPROVED="$(echo "$REC_OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["approved_commit"])')"
test "$APPROVED" = "$COMMIT" || fail "approved_commit $APPROVED != --commit $COMMIT"

# Promote as aegl-ai via SO_PEERCRED only — no controller token on this path.
PROM_OUT="$(runuser -u "$AI_USER" -- env AEGL_BROKER_SOCKET="$SOCK" \
  "$BROKER_BIN" client --socket "$SOCK" --request "{\"op\":\"promote\",\"task_id\":\"$TASK_ID\"}")"
echo "$PROM_OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d.get("decision")=="APPLIED",d'
test "$(git -C "$AEGL" rev-parse refs/heads/main)" = "$COMMIT" \
  || fail "main is not --commit after promote"
git -C "$AEGL" merge-base --is-ancestor "$COMMIT" refs/heads/main \
  || fail "--commit not ancestor of main after promote"
say "  promote APPLIED main=$COMMIT"

say "== F. Close formal workspace onto main =="
runuser -u "$OP_USER" -- bash -c "
  set -euo pipefail
  cd '$AEGL'
  test -z \"\$(git -C '$GA' status --porcelain)\"
  porcelain=\"\$(git status --porcelain)\"
  if [ -n \"\$porcelain\" ]; then
    echo \"STACK_ERROR: formal tree dirty before switch:\" >&2
    printf '%s\n' \"\$porcelain\" >&2
    exit 1
  fi
  git merge-base --is-ancestor feat/beads-adapter main
  git merge-base --is-ancestor '$COMMIT' main
  git switch main
  test \"\$(git rev-parse --abbrev-ref HEAD)\" = main
  test \"\$(git rev-parse HEAD)\" = '$COMMIT'
  test -z \"\$(git status --porcelain)\"
  git -C upstream/gradle-actions rev-parse HEAD | grep -qx '$PIN'
  test -f upstream/gradle-actions/dist/setup-gradle/main/index.js
"
say "  formal HEAD=main @$COMMIT clean"

# Success cleanup (trap also covers failure paths).
cleanup_all
trap - EXIT
EXT=""; PRE=""
say "STACK_RESULT=OK commit=$COMMIT main=$(git -C "$AEGL" rev-parse refs/heads/main)"
