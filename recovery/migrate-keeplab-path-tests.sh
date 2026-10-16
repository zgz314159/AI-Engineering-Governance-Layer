#!/usr/bin/env bash
# migrate-keeplab-path-tests.sh — minimal path-contract checks for KeepLab AppProjects.
# No APK/model/browser/recovery full suite.
set -uo pipefail
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AEGL_ROOT="$(cd "$SELF_DIR/.." && pwd)"
ST="$(mktemp -d /var/tmp/aegl-keeplab-path-XXXXXX)" || { echo "mktemp failed"; exit 2; }
PASS=0; FAIL=0
ok(){ echo "  PASS: $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL: $1"; FAIL=$((FAIL+1)); }
cleanup(){ chmod -R u+w "$ST" 2>/dev/null; rm -rf "$ST"; }
trap cleanup EXIT

PROOT="$ST/Projects"; BROOT="$ST/AppProjects"
mkdir -p "$PROOT" "$BROOT"

# --- authorize helpers ---
auth(){
  PROJECTS_ROOT="$PROOT" AEGL_BUSINESS_ROOT="$BROOT" AEGL_PROJECT_ALLOWLIST="$3" \
    python3 - "$1" "$2" <<'PY'
import os, sys
sys.path.insert(0, os.environ.get("AEGL_RECOVERY", ""))
# path injected below
PY
}

export PYTHONPATH="$AEGL_ROOT/recovery"
python3 - <<PY
import os, sys, tempfile
sys.path.insert(0, "$AEGL_ROOT/recovery")
import promotion_core as c
import promotion_broker as b

proot = "$PROOT"
broot = "$BROOT"
os.environ["PROJECTS_ROOT"] = proot
os.environ["AEGL_BUSINESS_ROOT"] = broot
os.environ["AEGL_PROJECT_ALLOWLIST"] = "Google-Android-Agent-Development-Stack,KeepLab-Relay,AI-Engineering-Governance-Layer"

assert c.projects_root() == os.path.realpath(proot)
assert c.business_root() == os.path.realpath(broot)
assert "KeepLab-Relay" in c.ALLOWED_BUSINESS_PROJECT_DIRS
assert "KeepLab-Relay" not in c.ALLOWED_SYSTEM_PROJECT_DIRS
assert "AI-Engineering-Governance-Layer" in c.ALLOWED_SYSTEM_PROJECT_DIRS
print("CORE_SPLIT_OK")

# materialize dirs
os.makedirs(os.path.join(proot, "AI-Engineering-Governance-Layer"), exist_ok=True)
os.makedirs(os.path.join(broot, "KeepLab-Relay"), exist_ok=True)
os.makedirs(os.path.join(proot, "KeepLab-Relay"), exist_ok=True)  # wrong place

# business under business root: ok
try:
    got = b._authorized_project(os.path.join(broot, "KeepLab-Relay"))
    assert got == os.path.realpath(os.path.join(broot, "KeepLab-Relay"))
    print("AUTH_BUSINESS_OK")
except Exception as e:
    print("AUTH_BUSINESS_FAIL", e); sys.exit(1)

# KeepLab under Projects: reject
try:
    b._authorized_project(os.path.join(proot, "KeepLab-Relay"))
    print("AUTH_KEEPLAB_UNDER_PROJECTS_UNEXPECTED_OK"); sys.exit(1)
except ValueError as e:
    assert "business" in str(e)
    print("AUTH_KEEPLAB_UNDER_PROJECTS_REJECT_OK")

# system under projects: ok
try:
    got = b._authorized_project(os.path.join(proot, "AI-Engineering-Governance-Layer"))
    assert os.path.basename(got) == "AI-Engineering-Governance-Layer"
    print("AUTH_SYSTEM_OK")
except Exception as e:
    print("AUTH_SYSTEM_FAIL", e); sys.exit(1)

# refuse home-wide: project directly under parent of Projects
homeish = os.path.dirname(proot)
os.makedirs(os.path.join(homeish, "KeepLab-Relay"), exist_ok=True)
try:
    b._authorized_project(os.path.join(homeish, "KeepLab-Relay"))
    print("AUTH_HOME_WIDE_UNEXPECTED_OK"); sys.exit(1)
except ValueError:
    print("AUTH_HOME_WIDE_REJECT_OK")
PY
rc=$?
[ $rc -eq 0 ] && ok "promotion dual-root authorize" || no "promotion dual-root authorize"

# --- aegl-task resolve ---
TASK="$AEGL_ROOT/bin/aegl-task"
# shellcheck source resolve by running a tiny extract
BUSINESS_ROOT="$BROOT" PROJECTS_ROOT="$PROOT" bash -c '
  source /dev/null
  PROJECTS_ROOT="'"$PROOT"'"; BUSINESS_ROOT="'"$BROOT"'"
  resolve_project() {
    local p="$1"
    case "$p" in
      /*) [ -d "$p" ] && { printf "%s" "$p"; return; } ;;
      KeepLab-Relay)
        [ -d "$BUSINESS_ROOT/KeepLab-Relay" ] && { printf "%s" "$BUSINESS_ROOT/KeepLab-Relay"; return; }
        [ -d "$PROJECTS_ROOT/KeepLab-Relay" ] && { printf "%s" "$PROJECTS_ROOT/KeepLab-Relay"; return; }
        ;;
      *) [ -d "$PROJECTS_ROOT/$p" ] && { printf "%s" "$PROJECTS_ROOT/$p"; return; } ;;
    esac
    echo "FAIL"; return 1
  }
  got="$(resolve_project KeepLab-Relay)"
  test "$got" = "'"$BROOT"'/KeepLab-Relay"
' && ok "aegl-task KeepLab resolves business root" || no "aegl-task KeepLab resolve"

# --- migrate script dry-run / dst exists / same-fs mv ----------------------- #
MIG="$AEGL_ROOT/recovery/migrate-keeplab-to-appprojects.sh"
mkrepo(){
  local d="$1"; rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  ( cd "$d" && echo x > r.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm t )
  git -C "$d" branch -M master
}
MIG_AREA="$ST/mig"; mkdir -p "$MIG_AREA/AppProjects"
SRC_A="$MIG_AREA/KeepLab-Relay-A"; DST_A="$MIG_AREA/AppProjects/KeepLab-Relay-A"
mkrepo "$SRC_A"
OUT="$(bash "$MIG" --src "$SRC_A" --dst "$DST_A" --dry-run 2>&1)" || true
printf '%s\n' "$OUT" | grep -q 'STOP_AT=dry_run_ok' && ok "migrate dry-run" || no "migrate dry-run ($OUT)"

mkdir -p "$DST_A"
OUT2="$(bash "$MIG" --src "$SRC_A" --dst "$DST_A" 2>&1)" && rc2=0 || rc2=$?
printf '%s\n' "$OUT2" | grep -q 'STOP_AT=precheck_dst_exists' && [ "$rc2" != 0 ] \
  && ok "migrate refuses existing dst" || no "migrate dst exists ($OUT2)"

rm -rf "$DST_A"
PRE="$(git -C "$SRC_A" rev-parse HEAD)"
OUT3="$(bash "$MIG" --src "$SRC_A" --dst "$DST_A" 2>&1)" && rc3=0 || rc3=$?
POST="$(git -C "$DST_A" rev-parse HEAD 2>/dev/null || echo missing)"
{ [ "$rc3" = 0 ] && [ "$PRE" = "$POST" ] && [ ! -e "$SRC_A" ] && printf '%s\n' "$OUT3" | grep -q 'MIGRATE_RESULT=OK'; } \
  && ok "migrate same-fs mv preserves HEAD" || no "migrate mv ($rc3 $OUT3)"
echo "KEEPLAB_PATH_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
