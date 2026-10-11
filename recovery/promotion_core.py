#!/usr/bin/env python3
"""AEGL central promotion gate + apply — the ONE implementation.

Reused by ``bin/aegl-task`` (verify classification) and by the trust broker
(``recovery/promotion_broker.py``). No LLM, no network, no guessed content.

The gate re-classifies the candidate *at promotion time* (changed + untracked +
ignored), requires the candidate to be byte-identical to what was verified
(``modified_after_verify``), checks the project target is one of the allowed
project directories directly under the projects root, and only then applies the
diff (commit on the task branch, ``--no-ff`` merge into the project). A failed
validation never changes the target.

CLI:
    promotion_core.py classify <worktree> <out.json>       # print rejected count
    promotion_core.py validate <task_dir>                  # print JSON verdict
    promotion_core.py promote  <task_dir>                  # validate + apply; print JSON

Environment: ``PROJECTS_ROOT`` (defaults to the projects parent of this repo).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys

GEN = re.compile(
    r"(^|/)(build|\.gradle|\.kotlin|node_modules|\.cache|\.pytest_cache)/|"
    r"\.(apk|aab|class|pyc|log|png|jpe?g|keystore|pem|p12)$|"
    r"(^|/)secrets\.json$|(^|/)credentials\.json$|(^|/)\.env($|\.)"
)

# The only project targets a promotion may touch: a project directory whose name
# is in this set, located directly under PROJECTS_ROOT.
ALLOWED_PROJECT_DIRS = frozenset(
    {"Google-Android-Agent-Development-Stack", "KeepLab-Relay", "AI-Engineering-Governance-Layer"}
)

_HERE = os.path.dirname(os.path.abspath(__file__))
AEGL_ROOT = os.path.dirname(_HERE)
DEFAULT_PROJECTS_ROOT = os.path.dirname(AEGL_ROOT)


def projects_root() -> str:
    return os.path.realpath(os.environ.get("PROJECTS_ROOT") or DEFAULT_PROJECTS_ROOT)


def _run(args, **kw):
    return subprocess.run(args, capture_output=True, text=True, **kw)


def worktree_manifest(wt: str) -> str:
    """sha256 of every file in the worktree (excluding .git), order-independent."""
    script = (
        'cd "$1" && find . -name .git -prune -o -type f -print0 2>/dev/null '
        "| sort -z | xargs -0 -r sha256sum 2>/dev/null"
    )
    return _run(["bash", "-c", script, "_", wt]).stdout


def classify(wt: str) -> dict:
    """Classify every changed/untracked/ignored path. Returns changes + rejected."""
    st = _run(["git", "-C", wt, "status", "--porcelain", "--ignored"]).stdout
    rows = []
    for line in st.splitlines():
        code, path = line[:2], line[3:].strip()
        if path.startswith(".git") or path == ".git":
            continue
        rows.append({"status": code, "path": path})
    root = os.path.realpath(wt)

    def bad(r):
        p, code = r["path"], r["status"]
        if p.startswith("/") or ".." in p.split("/"):
            return "path_escape"
        if code.strip() == "!!":
            return "ignored_file_present"
        if GEN.search(p):
            return "generated_or_secret"
        fp = os.path.join(wt, p)
        if os.path.islink(fp) and not os.path.realpath(fp).startswith(root + os.sep):
            return "symlink_escape"
        if os.path.isfile(fp) and os.path.getsize(fp) > 5_000_000:
            return "oversize"
        if "D" in code:
            return "deleted_project_body"
        return None

    for r in rows:
        r["reject"] = bad(r)
    return {"changes": rows, "rejected": [r for r in rows if r["reject"]]}


def _load_task(task_dir: str) -> dict:
    path = os.path.join(task_dir, "task.json")
    if not os.path.isfile(path):
        raise ValueError("no task.json")
    data = json.load(open(path, encoding="utf-8"))
    for key in ("id", "project", "worktree", "branch"):
        if not data.get(key):
            raise ValueError("task.json missing %s" % key)
    return data


def _authorized_project(project: str) -> str:
    """The project target MUST be one of the allowed project dirs under the root."""
    proj = os.path.realpath(project)
    parent = os.path.dirname(proj)
    if parent != projects_root():
        raise ValueError("project is not directly under the projects root")
    if os.path.basename(proj) not in ALLOWED_PROJECT_DIRS:
        raise ValueError("project is not in the allowed set")
    return proj


def validate(task_dir: str) -> dict:
    task_dir = os.path.realpath(task_dir)
    try:
        task = _load_task(task_dir)
        proj = _authorized_project(task["project"])
    except ValueError as exc:
        return {"decision": "REJECTED", "reason": str(exc)}
    wt = os.path.realpath(task["worktree"])
    if not os.path.isdir(wt):
        return {"decision": "REJECTED", "reason": "worktree_missing"}
    try:
        status = open(os.path.join(task_dir, "verify.status"), encoding="utf-8").read().strip()
    except OSError:
        return {"decision": "REJECTED", "reason": "verify_not_passed"}
    if status != "PASS":
        return {"decision": "REJECTED", "reason": "verify_not_passed"}
    manifest_path = os.path.join(task_dir, "verify.manifest")
    if not os.path.isfile(manifest_path):
        return {"decision": "REJECTED", "reason": "no_verify_manifest"}
    if worktree_manifest(wt) != open(manifest_path, encoding="utf-8").read():
        return {"decision": "REJECTED", "reason": "modified_after_verify"}
    rejected = classify(wt)["rejected"]
    if rejected:
        reasons = sorted({r["reject"] for r in rejected})
        return {"decision": "REJECTED", "reason": "rejected_changes: " + ",".join(reasons)}
    layout = os.path.join(wt, "scripts", "verify-layout.sh")
    if os.path.isfile(layout):
        if _run(["bash", layout, "--root", wt, "--quiet"]).returncode != 0:
            return {"decision": "REJECTED", "reason": "layout"}
    return {
        "decision": "VALIDATED",
        "task_id": task["id"],
        "project": proj,
        "worktree": wt,
        "branch": task["branch"],
        "rejected": 0,
    }


def promote(task_dir: str) -> dict:
    """Re-validate, then apply the diff. A failed validation never changes the target."""
    verdict = validate(task_dir)
    if verdict["decision"] != "VALIDATED":
        return verdict
    wt, proj = verdict["worktree"], verdict["project"]
    branch, tid = verdict["branch"], verdict["task_id"]
    if _run(["git", "-C", wt, "add", "-A"]).returncode != 0:
        return {"decision": "FAILED", "reason": "git_add", "task_id": tid}
    if _run([
        "git", "-C", wt, "-c", "user.email=aegl@local.invalid", "-c", "user.name=AEGL Broker",
        "commit", "-qm", "aegl-task(%s): approved change" % tid,
    ]).returncode != 0:
        return {"decision": "FAILED", "reason": "git_commit", "task_id": tid}
    if _run([
        "git", "-C", proj, "-c", "user.email=aegl@local.invalid", "-c", "user.name=AEGL Broker",
        "merge", "--no-ff", "-m", "aegl-promote: %s" % tid, branch,
    ]).returncode != 0:
        return {"decision": "FAILED", "reason": "git_merge", "task_id": tid}
    return {"decision": "APPLIED", "task_id": tid, "project": proj, "worktree": wt}


def main(argv):
    if not argv:
        print(json.dumps({"error": "usage: classify|validate|promote"}))
        return 2
    cmd = argv[0]
    if cmd == "classify":
        if len(argv) != 3:
            print(json.dumps({"error": "usage: classify <worktree> <out.json>"}))
            return 2
        result = classify(argv[1])
        with open(argv[2], "w", encoding="utf-8") as handle:
            json.dump(result, handle, indent=2)
        print(len(result["rejected"]))
        return 0
    if cmd == "validate":
        print(json.dumps(validate(argv[1]), sort_keys=True))
        return 0
    if cmd == "promote":
        print(json.dumps(promote(argv[1]), sort_keys=True))
        return 0
    print(json.dumps({"error": "unknown command: %s" % cmd}))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
