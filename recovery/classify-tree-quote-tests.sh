#!/usr/bin/env bash
# Focused regression: classify_tree must keep literal paths from git -z output
# (systemd unit names with \x2d must not become path_escape via C-quote display).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok(){ printf '  PASS: %s\n' "$*"; PASS=$((PASS+1)); }
no(){ printf '  FAIL: %s\n' "$*"; FAIL=$((FAIL+1)); }

T="$(mktemp -d /var/tmp/aegl-classify-quote-XXXXXX)"
cleanup(){ rm -rf "$T"; }
trap cleanup EXIT

python3 - "$ROOT" "$T" <<'PY'
import json, os, subprocess, sys, tempfile

root, td = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(root, "recovery"))
import promotion_core as c

def git(*a, check=True):
    return subprocess.run(["git", "-C", td, *a], capture_output=True, text=True, check=check)

git("init", "-b", "main")
git("config", "user.email", "t@t")
git("config", "user.name", "t")
os.makedirs(os.path.join(td, "recovery/parent-entry-bind/units"), exist_ok=True)
open(os.path.join(td, "README"), "w").write("base\n")
git("add", "README")
git("commit", "-m", "base")
base = git("rev-parse", "HEAD").stdout.strip()

# Three real pack unit filenames (literal backslash-x2d in the name).
real_units = [
    r"home-zhong-Projects-AI\x2dEngineering\x2dGovernance\x2dLayer.mount",
    r"home-zhong-Projects-Google\x2dAndroid\x2dAgent\x2dDevelopment\x2dStack.mount",
    r"home-zhong-AppProjects-KeepLab\x2dRelay.mount",
]
for n in real_units:
    open(os.path.join(td, "recovery/parent-entry-bind/units", n), "w").write("[Mount]\nWhat=x\nWhere=x\n")

# Space / quote / backslash names (literal path components).
extra = [
    "path with spaces.txt",
    'quote"name.txt',
    r"back\slash.txt",
]
for n in extra:
    open(os.path.join(td, n), "w").write("ok\n")

git("add", "-A")
git("commit", "-m", "named")
tip = git("rev-parse", "HEAD").stdout.strip()
tree = git("rev-parse", "HEAD^{tree}").stdout.strip()

# Non -z output is quoted (documents the bug class); -z must be used by classifier.
raw = git("diff", "--name-status", "--no-renames", base, tip).stdout
assert '"' in raw or "\\\\" in raw, raw

rej = c.classify_tree(td, base, tree, td)
bad = [r for r in rej if r.get("reject") == "path_escape"]
results = {
    "real_units_path_escape": len(bad),
    "rejected": rej,
    "parsed_ok_paths": [],
}
# Ensure all real unit paths classified without path_escape and are findable in tree.
for n in real_units:
    rel = "recovery/parent-entry-bind/units/" + n
    ent = c._tree_entry(td, tree, rel)
    results["parsed_ok_paths"].append({"path": rel, "entry": ent is not None})
    if any(r.get("path") == rel and r.get("reject") == "path_escape" for r in rej):
        results["real_units_path_escape"] += 1

# Absolute path / .. escape still rejected (synthetic row via classify_rows).
esc = c.classify_rows(td, [
    {"status": "A", "path": "/etc/passwd"},
    {"status": "A", "path": "foo/../../etc/passwd"},
])
results["abs_escape"] = any(r["reject"] == "path_escape" for r in esc if r["path"].startswith("/"))
results["dotdot_escape"] = any(r["reject"] == "path_escape" for r in esc if ".." in r["path"])

# changes_from_base must also keep literal names (not quoted display).
rows = c.changes_from_base(td, base)
paths = {r["path"] for r in rows}
results["changes_has_real_unit"] = all(
    ("recovery/parent-entry-bind/units/" + n) in paths for n in real_units
)
results["changes_has_space"] = "path with spaces.txt" in paths
results["changes_has_backslash"] = r"back\slash.txt" in paths

# Git failure must not look like empty success.
failed = False
try:
    c._git_ok(td, "diff", "--name-status", "-z", "no-such-ref-abc", tip)
except RuntimeError:
    failed = True
results["git_fail_raises"] = failed

open(os.path.join(td, "results.json"), "w", encoding="utf-8").write(json.dumps(results, indent=2))
print(json.dumps(results, indent=2))
PY

python3 - "$T/results.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
sys.exit(0 if (
    r["real_units_path_escape"] == 0
    and all(p["entry"] for p in r["parsed_ok_paths"])
    and r["abs_escape"] and r["dotdot_escape"]
    and r["changes_has_real_unit"] and r["changes_has_space"] and r["changes_has_backslash"]
    and r["git_fail_raises"]
    and not r["rejected"]
) else 1)
PY
rc=$?
if [ "$rc" = 0 ]; then ok "classify_tree NUL paths + escapes + git fail-closed"
else no "classify_tree quote/NUL regression"; fi

echo "CLASSIFY_TREE_QUOTE_TESTS passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
