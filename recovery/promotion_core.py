#!/usr/bin/env python3
"""AEGL central promotion gate + apply — the ONE implementation.

The gate works on the trust boundary, not on the AI-writable task directory:

* it compares the *actual candidate worktree* against a **trusted baseline commit**
  (``base``) — covering committed, staged, unstaged, untracked and ignored paths —
  rather than trusting ``git status`` alone;
* it pins the exact candidate content with :func:`candidate_digest` so the bytes
  approved at verify time are the bytes applied (no swap of files or branch);
* it **never executes candidate code** (a project ``verify-layout.sh`` is not run
  here); layout/tests run in the restricted sandbox, not as the broker identity;
* git operations disable hooks and unrelated exec entry points.

A failed validation never changes the target.

CLI:
    promotion_core.py manifest <worktree>
    promotion_core.py digest   <worktree> <base> <branch>
    promotion_core.py changes  <worktree> <base> <out.json>
    promotion_core.py validate <worktree> <base> <branch>
"""

from __future__ import annotations

import hashlib
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

# The only project targets a promotion may touch: a directory whose name is in this
# set and that sits directly under the projects root.
ALLOWED_PROJECT_DIRS = frozenset(
    {"Google-Android-Agent-Development-Stack", "KeepLab-Relay", "AI-Engineering-Governance-Layer"}
)

_HERE = os.path.dirname(os.path.abspath(__file__))
AEGL_ROOT = os.path.dirname(_HERE)
DEFAULT_PROJECTS_ROOT = os.path.dirname(AEGL_ROOT)

# Environment for git: no system/global config, no interactive prompts, no HOME config.
GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_TERMINAL_PROMPT": "0",
    "HOME": "/nonexistent",
}
# Disable hooks and monitors for every git invocation (no untrusted exec entry points).
GIT_HARDEN = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]


def projects_root() -> str:
    return os.path.realpath(os.environ.get("PROJECTS_ROOT") or DEFAULT_PROJECTS_ROOT)


def _git(wt: str, *args, check=False) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", wt, *GIT_HARDEN, *args], capture_output=True, text=True, env=GIT_ENV, check=check
    )


def candidate_manifest(wt: str) -> str:
    """sha256 of every worktree file (excluding .git), order-independent."""
    script = (
        'cd "$1" && find . -name .git -prune -o -type f -print0 2>/dev/null '
        "| sort -z | xargs -0 -r sha256sum 2>/dev/null"
    )
    return subprocess.run(["bash", "-c", script, "_", wt], capture_output=True, text=True).stdout


def candidate_digest(wt: str, base: str, branch: str) -> str:
    """Pin the exact candidate: baseline commit + branch + file manifest."""
    payload = json.dumps(
        {"base": base, "branch": branch, "manifest": candidate_manifest(wt)},
        sort_keys=True, separators=(",", ":"),
    )
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()


def changes_from_base(wt: str, base: str) -> list:
    """Every path that differs between the trusted baseline and the candidate worktree.

    Covers committed, staged, unstaged (``git diff <base>``), untracked and ignored.
    """
    rows = {}
    diff = _git(wt, "diff", "--name-status", "--no-renames", base)
    for line in diff.stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            rows[parts[-1]] = {"status": parts[0], "path": parts[-1]}
    for path in _git(wt, "ls-files", "--others", "--exclude-standard").stdout.splitlines():
        rows.setdefault(path, {"status": "??", "path": path})
    for path in _git(wt, "ls-files", "--others", "--ignored", "--exclude-standard").stdout.splitlines():
        rows.setdefault(path, {"status": "!!", "path": path})
    return [rows[k] for k in sorted(rows)]


def classify_rows(wt: str, rows: list) -> list:
    root = os.path.realpath(wt)

    def bad(row):
        p, code = row["path"], row["status"]
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

    rejected = []
    for row in rows:
        row = dict(row)
        row["reject"] = bad(row)
        if row["reject"]:
            rejected.append(row)
    return rejected


def validate_candidate(wt: str, base: str, branch: str) -> dict:
    """Pure content/gate validation. Never runs candidate code, never writes the target."""
    if not os.path.isdir(wt):
        return {"decision": "REJECTED", "reason": "worktree_missing"}
    if _git(wt, "rev-parse", "--verify", "--quiet", base).returncode != 0:
        return {"decision": "REJECTED", "reason": "unknown_baseline"}
    head_branch = _git(wt, "rev-parse", "--abbrev-ref", "HEAD").stdout.strip()
    if branch and head_branch != branch:
        return {"decision": "REJECTED", "reason": "branch_swapped"}
    rows = changes_from_base(wt, base)
    rejected = classify_rows(wt, rows)
    if rejected:
        reasons = sorted({r["reject"] for r in rejected})
        return {"decision": "REJECTED", "reason": "rejected_changes: " + ",".join(reasons)}
    return {
        "decision": "VALIDATED",
        "base": base,
        "branch": head_branch,
        "candidate_digest": candidate_digest(wt, base, head_branch),
        "changed_paths": len(rows),
    }


def apply(proj: str, wt: str, branch: str, tid: str) -> dict:
    """Apply the approved diff with hooks and untrusted exec entry points disabled."""
    ident = ["-c", "user.email=aegl@local.invalid", "-c", "user.name=AEGL Broker"]
    if _git(wt, *ident, "add", "-A").returncode != 0:
        return {"decision": "FAILED", "reason": "git_add"}
    if _git(wt, *ident, "commit", "-q", "--no-verify", "-m", "aegl-task(%s): approved change" % tid).returncode != 0:
        return {"decision": "FAILED", "reason": "git_commit"}
    if _git(proj, *ident, "merge", "--no-ff", "--no-verify", "-m", "aegl-promote: %s" % tid, branch).returncode != 0:
        return {"decision": "FAILED", "reason": "git_merge"}
    return {"decision": "APPLIED", "task_id": tid, "project": proj, "worktree": wt}


def main(argv):
    if len(argv) < 2:
        print(json.dumps({"error": "usage: manifest|digest|changes|validate"}))
        return 2
    cmd = argv[0]
    if cmd == "manifest":
        print(candidate_manifest(argv[1]), end="")
        return 0
    if cmd == "digest":
        print(candidate_digest(argv[1], argv[2], argv[3] if len(argv) > 3 else ""))
        return 0
    if cmd == "changes":
        rows = changes_from_base(argv[1], argv[2])
        rejected = classify_rows(argv[1], rows)
        with open(argv[3], "w", encoding="utf-8") as handle:
            json.dump({"changes": rows, "rejected": rejected}, handle, indent=2)
        print(len(rejected))
        return 0
    if cmd == "validate":
        print(json.dumps(validate_candidate(argv[1], argv[2], argv[3] if len(argv) > 3 else ""), sort_keys=True))
        return 0
    print(json.dumps({"error": "unknown command: %s" % cmd}))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
