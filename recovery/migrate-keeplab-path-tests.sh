#!/usr/bin/env bash
# migrate-keeplab-path-tests.sh — minimal path-contract / migrate-safety checks.
# No full broker suite, APK, model, or browser acceptance.
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

# --- 1) dual-root authorize + target refs ---------------------------------- #
export PYTHONPATH="$AEGL_ROOT/recovery"
python3 - <<PY
import os, sys
sys.path.insert(0, "$AEGL_ROOT/recovery")
import promotion_core as c
import promotion_broker as b

proot, broot = "$PROOT", "$BROOT"
os.environ["PROJECTS_ROOT"] = proot
os.environ["AEGL_BUSINESS_ROOT"] = broot
os.environ["AEGL_PROJECT_ALLOWLIST"] = "Google-Android-Agent-Development-Stack,KeepLab-Relay,AI-Engineering-Governance-Layer"
os.makedirs(os.path.join(proot, "AI-Engineering-Governance-Layer"), exist_ok=True)
os.makedirs(os.path.join(broot, "KeepLab-Relay"), exist_ok=True)
os.makedirs(os.path.join(proot, "KeepLab-Relay"), exist_ok=True)
assert c.target_ref_for("AI-Engineering-Governance-Layer") == "refs/heads/main"
assert c.target_ref_for("Google-Android-Agent-Development-Stack") == "refs/heads/master"
assert c.target_ref_for("KeepLab-Relay") == "refs/heads/master"
b._authorized_project(os.path.join(broot, "KeepLab-Relay"))
try:
    b._authorized_project(os.path.join(proot, "KeepLab-Relay")); raise SystemExit("keeplab under projects accepted")
except ValueError:
    pass
print("AUTH_AND_TARGET_OK")
PY
[ $? -eq 0 ] && ok "authorize + per-project target_ref" || no "authorize + target_ref"

# --- 2) task.json never eval'd; bad metadata hard-fails -------------------- #
MIG="$AEGL_ROOT/recovery/migrate-keeplab-to-appprojects.sh"
TASKS="$ST/zhong-state/aegl/tasks"
mkdir -p "$TASKS/good/worktree" "$TASKS/badmeta"
mkrepo(){ local d="$1"; rm -rf "$d"; mkdir -p "$d"; git -C "$d" init -q
  ( cd "$d" && echo x > r.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm t )
  git -C "$d" branch -M master; }
SRC_A="$ST/KeepLab-Relay"; mkrepo "$SRC_A"
rm -rf "$BROOT/KeepLab-Relay" "$BROOT/Kmeta" "$BROOT/K2" "$BROOT/K3"
# path with spaces / metacharacters in JSON — must not execute as shell
python3 - <<PY
import json, os
meta=os.path.join("$TASKS","good","task.json")
json.dump({"id":"t1","project":"$SRC_A","worktree":os.path.join("$TASKS","good","worktree"),
           "evil":"; touch $ST/PWNED; #"}, open(meta,"w"))
open(os.path.join("$TASKS","badmeta","task.json"),"w").write("{not json")
PY
OUT="$(HOME="$ST/root-home" AEGL_TASKS_ROOT="$TASKS" bash "$MIG" --src "$SRC_A" --dst "$BROOT/Kmeta" --dry-run 2>&1)" || rc=$?
rc=${rc:-0}
printf '%s\n' "$OUT" | grep -q 'STOP_AT=precheck_task_metadata_error' && [ "$rc" != 0 ] \
  && ok "bad task.json hard-stops (not silent idle)" || no "bad metadata ($rc $OUT)"
[ ! -e "$ST/PWNED" ] && ok "task.json fields not executed as shell" || no "task.json executed shell"

# --- 3) sudo HOME must not hide zhong tasks -------------------------------- #
rm -rf "$TASKS/badmeta"
# hit: project points at SRC
OUT2="$(HOME="$ST/root-home" AEGL_TASKS_ROOT="$TASKS" bash "$MIG" --src "$SRC_A" --dst "$BROOT/K2" --dry-run 2>&1)" || rc2=$?
rc2=${rc2:-0}
printf '%s\n' "$OUT2" | grep -q 'STOP_AT=precheck_active_keeplab_tasks' && [ "$rc2" != 0 ] \
  && ok "operator AEGL_TASKS_ROOT seen under fake sudo HOME" || no "tasks root ($rc2 $OUT2)"

# default operator home layout without AEGL_TASKS_ROOT
OPHOME="$ST/home-zhong"; mkdir -p "$OPHOME/.local/state/aegl/tasks/t9"
# rewrite getent? script uses getent passwd zhong — real zhong home. Instead set AEGL_STATE_HOME.
rm -f "$TASKS/good/task.json"
OUT3="$(HOME="$ST/root-home" AEGL_STATE_HOME="$OPHOME/.local/state/aegl" bash "$MIG" \
  --src "$SRC_A" --dst "$BROOT/K3" --dry-run 2>&1)" || true
printf '%s\n' "$OUT3" | grep -q "TASKS_ROOT=$OPHOME/.local/state/aegl/tasks" \
  && ok "AEGL_STATE_HOME resolves under sudo HOME" || no "state home ($OUT3)"

# --- 4) migrate same-fs + resume-post surface ------------------------------ #
rm -rf "$BROOT/KeepLab-Relay"
mkdir -p "$ST/empty-tasks"
OUT4="$(HOME="$ST/root-home" AEGL_TASKS_ROOT="$ST/empty-tasks" bash "$MIG" \
  --src "$SRC_A" --dst "$BROOT/KeepLab-Relay" --phase all --no-require-patches 2>&1)" && rc4=0 || rc4=$?
printf '%s\n' "$OUT4" | grep -q 'MIGRATE_RESULT=OK' && [ ! -e "$SRC_A" ] && [ -d "$BROOT/KeepLab-Relay/.git" ] \
  && ok "migrate move preserves git" || no "migrate move ($rc4 $OUT4)"

OUT5="$(bash "$MIG" --src "$SRC_A" --dst "$BROOT/KeepLab-Relay" --phase all --no-require-patches 2>&1)" && rc5=0 || rc5=$?
printf '%s\n' "$OUT5" | grep -qE 'STOP_AT=precheck_already_moved|STOP_AT=precheck_src_missing|STOP_AT=precheck_dst_exists' \
  && ok "re-run after move refuses move phase" || no "rerun refuse ($rc5 $OUT5)"

OUT6="$(bash "$MIG" --resume-post --src "$SRC_A" --dst "$BROOT/KeepLab-Relay" --no-require-patches 2>&1)" && rc6=0 || rc6=$?
printf '%s\n' "$OUT6" | grep -q 'STOP_AT=complete' \
  && ok "resume-post runs without requiring SRC" || no "resume-post ($rc6 $OUT6)"

# --- 5) no eval; guard source_root expansion (Stack isolation tip if present) --- #
if grep -nE '^[[:space:]]*eval[[:space:]]|^[[:space:]]*eval\$' "$MIG"; then
  no "migrate script still contains eval"
else
  ok "migrate script has no eval"
fi

GUARD_CAND=(
  /home/zhong/.local/state/aegl/tasks/keeplab-migrate-stack-*/worktree/orchestration/hermes/evaluation_adapter/contract_guard.py
)
GUARD=""
for g in "${GUARD_CAND[@]}"; do
  for f in $g; do [ -f "$f" ] && GUARD="$f" && break 2; done
done
if [ -n "$GUARD" ]; then
  mkdir -p "$BROOT/KeepLab-Relay/specs/p0b-close-benchmarkability"
  # minimal package for load if real package missing at throwaway keeplab — use real KeepLab package when present
  REAL_PKG=""
  for cand in /home/zhong/Projects/KeepLab-Relay/specs/p0b-close-benchmarkability \
              /home/zhong/AppProjects/KeepLab-Relay/specs/p0b-close-benchmarkability; do
    [ -f "$cand/project-context.json" ] && REAL_PKG="$cand" && break
  done
  if [ -n "$REAL_PKG" ]; then
    python3 - "$GUARD" "$REAL_PKG" "$BROOT" "$PROOT" <<'PY' && ok "guard expands source_root token" || no "guard source_root"
import importlib.util, os, sys
guard_path, pkg, business, projects = sys.argv[1:5]
os.environ["AEGL_BUSINESS_ROOT"] = business
os.environ["PROJECTS_ROOT"] = projects
spec = importlib.util.spec_from_file_location("cg", guard_path)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
loaded = mod.load_contract(pkg)
assert "$" not in loaded["source_root"], loaded["source_root"]
assert loaded["source_root"] == os.path.realpath(projects), loaded["source_root"]
print("SOURCE_ROOT", loaded["source_root"])
PY
  else
    ok "guard source_root skipped (no real package on host)"
  fi
else
  no "stack guard candidate missing"
fi

echo "KEEPLAB_PATH_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
