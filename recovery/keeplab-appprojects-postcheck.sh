#!/usr/bin/env bash
# keeplab-appprojects-postcheck.sh — operator-identity post checks after KeepLab move.
# Must NOT run as root (refuses). Does not mutate the host.
set -euo pipefail

AEGL="${AEGL:-/home/zhong/Projects/AI-Engineering-Governance-Layer}"
STACK="${STACK:-/home/zhong/Projects/Google-Android-Agent-Development-Stack}"
DST="${DST:-/home/zhong/AppProjects/KeepLab-Relay}"
PROJECTS_ROOT="${PROJECTS_ROOT:-/home/zhong/Projects}"
AEGL_BUSINESS_ROOT="${AEGL_BUSINESS_ROOT:-/home/zhong/AppProjects}"

say(){ printf '%s\n' "$*"; }
die(){ printf 'STOP_AT=%s\nPOSTCHECK_ERROR: %s\n' "$1" "$2" >&2; exit 1; }

[ "$(id -u)" != 0 ] || die must_not_be_root "postcheck refuses root (use runuser -u zhong)"
[ -d "$DST/.git" ] || [ -f "$DST/.git" ] || die dst_missing "DST missing: $DST"
[ ! -e /home/zhong/Projects/KeepLab-Relay ] || die old_path_present "old Projects/KeepLab-Relay still present"

resolved=""
if [ -d "$AEGL_BUSINESS_ROOT/KeepLab-Relay" ]; then resolved="$AEGL_BUSINESS_ROOT/KeepLab-Relay"
elif [ -d "$PROJECTS_ROOT/KeepLab-Relay" ]; then resolved="$PROJECTS_ROOT/KeepLab-Relay"
else die resolve_fail "KeepLab unresolved"; fi
[ "$resolved" = "$DST" ] || die resolve_mismatch "resolved=$resolved want=$DST"
say "TASK_RESOLVE_OK=$resolved"

kr="$(PROJECTS_ROOT="$PROJECTS_ROOT" AEGL_BUSINESS_ROOT="$AEGL_BUSINESS_ROOT" \
  "$AEGL/bin/aegl-recovery" doctor 2>/dev/null | grep '^keeplab=' || true)"
say "RECOVERY_KEEPLAB=$kr"
printf '%s\n' "$kr" | grep -q "keeplab=$DST" || die recovery_mismatch "doctor keeplab != $DST"

guard="$STACK/orchestration/hermes/evaluation_adapter/contract_guard.py"
[ -f "$guard" ] || die guard_missing "$guard"
python3 - "$guard" "$DST" "$AEGL_BUSINESS_ROOT" "$PROJECTS_ROOT" <<'PY' || die guard_failed "contract_guard check failed"
import importlib.util, os, sys
guard_path, keeplab, business, projects = sys.argv[1:5]
os.environ["AEGL_BUSINESS_ROOT"] = business
os.environ["PROJECTS_ROOT"] = projects
spec = importlib.util.spec_from_file_location("contract_guard", guard_path)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
pkg = os.path.join(keeplab, "specs", "p0b-close-benchmarkability")
assert os.path.isdir(pkg), pkg
loaded = mod.load_contract(pkg)
assert loaded["integrity"] == "MANIFEST_OK", loaded["integrity"]
root = loaded["source_root"]
assert root == os.path.realpath(projects), "source_root must remain Projects: %r" % (root,)
assert "$" not in root and "`" not in root, root
rel = mod.project_rel(os.path.join(keeplab, "benchmark", "x.txt"))
assert rel == "KeepLab-Relay/benchmark/x.txt", rel
# Stack sibling still under Projects source_root boundary
srel = mod.project_rel(os.path.join(projects, "Google-Android-Agent-Development-Stack", "README.md"))
assert srel == "Google-Android-Agent-Development-Stack/README.md" or srel is not None
print("GUARD_INTEGRITY=MANIFEST_OK")
print("GUARD_SOURCE_ROOT=%s" % root)
print("GUARD_KEEPLAB_REL_OK=%s" % rel)
PY

say "POSTCHECK_OK=1"
