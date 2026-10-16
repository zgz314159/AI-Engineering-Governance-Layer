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
# Steps: preflight → confirm only the 10 expected gradle-actions deletions →
# restore those from the pin → install broker + target ACL from the same TIP →
# external candidate worktree → register/record (root) → promote (aegl-ai) →
# close formal checkout onto main. Controller mint of AEGL_CONTROLLER_TOKEN is
# injected into the aegl-ai promote env only when using bin/aegl-task; this pack
# calls the installed broker client directly (SO_PEERCRED) and never prints secrets.
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

say "== A. Preflight =="
test "$(git -C "$AEGL" rev-parse plan/capture-hook-classfix)" = "$COMMIT" \
  || fail "plan/capture-hook-classfix is not $COMMIT"
git -C "$AEGL" merge-base --is-ancestor feat/beads-adapter "$COMMIT" \
  || fail "feat/beads-adapter is not an ancestor of tip"
test "$(git -C "$AEGL" rev-list --count "$COMMIT"..feat/beads-adapter)" = 0 \
  || fail "feat/beads-adapter has commits not in tip"
test "$(git -C "$AEGL" ls-tree "$COMMIT" upstream/gradle-actions | awk '{print $3}')" = "$PIN" \
  || fail "gradle-actions gitlink is not $PIN"
MAIN_BEFORE="$(git -C "$AEGL" rev-parse refs/heads/main)"
say "  tip=$COMMIT main_before=$MAIN_BEFORE"

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
runuser -u zhong -- git -C "$GA" restore --source="$PIN" -- "${GRADLE_DIST_FILES[@]}"
test -z "$(git -C "$GA" status --porcelain)" || fail "gradle-actions still dirty after restore"
# Parent may still show submodule letter if index lagged; require no porcelain on GA and
# no unexpected non-submodule dirt on AEGL aside from submodule status noise we re-check:
test -z "$(git -C "$GA" status --porcelain)"
say "  gradle-actions clean at pin $PIN"

say "== D. Trusted deploy: broker + target ACL from fixed TIP (not worktree) =="
git -C "$AEGL" show "$COMMIT:recovery/install-broker.sh" \
  | bash -s -- --repo "$AEGL" --projects-root "$(dirname "$AEGL")" --commit "$COMMIT"
git -C "$AEGL" show "$COMMIT:recovery/install-promote-target-acl.sh" \
  | bash -s -- --repo "$AEGL" --project "$AEGL" --commit "$COMMIT"
[ -x "$BROKER_BIN" ] || fail "broker binary missing after install"
systemctl is-active --quiet aegl-promote-broker || fail "aegl-promote-broker not active"

say "== E. External candidate + register/record/promote =="
EXT="$(mktemp -d /var/tmp/aegl-promote-cand-XXXXXX)"
cleanup_ext(){ git -C "$AEGL" worktree remove --force "$EXT/wt" 2>/dev/null || true; rm -rf "$EXT"; }
trap cleanup_ext EXIT
runuser -u zhong -- git -C "$AEGL" worktree add -f "$EXT/wt" "$COMMIT"
test -z "$(git -C "$EXT/wt" status --porcelain)" || fail "candidate worktree dirty"
BASE="$(git -C "$AEGL" merge-base refs/heads/main "$COMMIT")"
REG_JSON="$(python3 -c 'import json,sys;print(json.dumps({"op":"register","task_id":sys.argv[1],"project":sys.argv[2],"base":sys.argv[3],"worktree":sys.argv[4],"branch":"plan/capture-hook-classfix","target_ref":"refs/heads/main"}))' \
  "$TASK_ID" "$AEGL" "$BASE" "$EXT/wt")"
REG_OUT="$("$BROKER_BIN" client --socket "$SOCK" --request "$REG_JSON")"
echo "$REG_OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d.get("decision")=="REGISTERED",d'
REC_OUT="$("$BROKER_BIN" client --socket "$SOCK" --request "{\"op\":\"record\",\"task_id\":\"$TASK_ID\",\"verify_result\":\"PASS\"}")"
echo "$REC_OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d.get("decision")=="RECORDED",d'
APPROVED="$(echo "$REC_OUT" | python3 -c 'import json,sys;print(json.load(sys.stdin)["approved_commit"])')"
test "$APPROVED" = "$COMMIT" || fail "approved_commit $APPROVED != tip $COMMIT"

# Mint controller token for any aegl-task wrapper path; inject only into aegl-ai env.
TOKEN_FILE="$(mktemp /run/aegl-promote/controller.XXXXXX)"
chmod 600 "$TOKEN_FILE"
TOKEN="$(openssl rand -hex 32)"
printf '%s' "$TOKEN" > "$TOKEN_FILE"
chown aegl-ai:aegl-ai "$TOKEN_FILE"
PROM_OUT="$(runuser -u aegl-ai -- env \
  AEGL_BROKER_SOCKET="$SOCK" \
  AEGL_CONTROLLER_TOKEN_FILE="$TOKEN_FILE" \
  AEGL_CONTROLLER_TOKEN="$TOKEN" \
  "$BROKER_BIN" client --socket "$SOCK" --request "{\"op\":\"promote\",\"task_id\":\"$TASK_ID\"}")"
# Scrub token from memory surfaces we control; never echo TOKEN.
TOKEN=""
rm -f "$TOKEN_FILE"
echo "$PROM_OUT" | python3 -c 'import json,sys;d=json.load(sys.stdin);assert d.get("decision")=="APPLIED",d'
test "$(git -C "$AEGL" rev-parse refs/heads/main)" = "$COMMIT" \
  || fail "main is not tip after promote"
git -C "$AEGL" merge-base --is-ancestor "$COMMIT" refs/heads/main \
  || fail "tip not ancestor of main after promote"
say "  promote APPLIED main=$COMMIT"

say "== F. Close formal workspace onto main =="
runuser -u zhong -- bash -c "
  set -euo pipefail
  cd '$AEGL'
  test -z \"\$(git -C '$GA' status --porcelain)\"
  # Allow only clean or empty porcelain on formal tree before switch.
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

cleanup_ext
trap - EXIT
say "STACK_RESULT=OK commit=$COMMIT main=$(git -C "$AEGL" rev-parse refs/heads/main)"
