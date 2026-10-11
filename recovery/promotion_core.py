#!/usr/bin/env python3
"""AEGL central promotion gate + apply — the ONE implementation.

The gate does not re-collect content from the AI-writable worktree when it applies.
Instead it builds a **broker-controlled, deterministic Git object** that binds the
complete candidate (file contents, symlink targets and Git file modes via a Git tree),
and applies exactly that object:

* :func:`candidate_tree` stages the worktree against the trusted baseline ``base`` into
  a *private temp index* and writes a tree object (mode + symlink target included);
* :func:`materialize_commit` turns that tree into a commit object in the project object
  database with a fixed identity/date (deterministic);
* :func:`apply_object` merges that exact commit — never a mutable branch name, never a
  worktree re-read.

The gate never executes candidate code (a project ``verify-layout.sh`` is not run here),
and git operations disable hooks and other untrusted exec entry points. A failed check,
a swapped candidate or an inconsistent object all leave the target unchanged.

CLI: ``manifest`` · ``changes`` · ``tree`` · ``validate`` (see ``main``).
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile

GEN = re.compile(
    r"(^|/)(build|\.gradle|\.kotlin|node_modules|\.cache|\.pytest_cache)/|"
    r"\.(apk|aab|class|pyc|log|png|jpe?g|keystore|pem|p12)$|"
    r"(^|/)secrets\.json$|(^|/)credentials\.json$|(^|/)\.env($|\.)"
)

ALLOWED_PROJECT_DIRS = frozenset(
    {"Google-Android-Agent-Development-Stack", "KeepLab-Relay", "AI-Engineering-Governance-Layer"}
)

_HERE = os.path.dirname(os.path.abspath(__file__))
AEGL_ROOT = os.path.dirname(_HERE)
DEFAULT_PROJECTS_ROOT = os.path.dirname(AEGL_ROOT)

FIXED_IDENT = ["-c", "user.email=aegl@local.invalid", "-c", "user.name=AEGL Broker"]
FIXED_DATE = "2000-01-01T00:00:00+0000"
GIT_ENV = {
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_TERMINAL_PROMPT": "0",
    "HOME": "/nonexistent",
    "GIT_AUTHOR_DATE": FIXED_DATE,
    "GIT_COMMITTER_DATE": FIXED_DATE,
}
# Disable hooks and monitors for every git invocation (no untrusted exec entry points).
GIT_HARDEN = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]


def projects_root() -> str:
    return os.path.realpath(os.environ.get("PROJECTS_ROOT") or DEFAULT_PROJECTS_ROOT)


def _git(repo: str, *args, env=None, check=False) -> subprocess.CompletedProcess:
    merged = dict(GIT_ENV)
    if env:
        merged.update(env)
    return subprocess.run(
        ["git", "-C", repo, *GIT_HARDEN, *args], capture_output=True, text=True, env=merged, check=check
    )


def candidate_manifest(wt: str) -> str:
    script = (
        'cd "$1" && find . -name .git -prune -o -type f -print0 2>/dev/null '
        "| sort -z | xargs -0 -r sha256sum 2>/dev/null"
    )
    return subprocess.run(["bash", "-c", script, "_", wt], capture_output=True, text=True).stdout


def changes_from_base(wt: str, base: str) -> list:
    """Every path that differs between the baseline and the *current* worktree files."""
    rows = {}
    for line in _git(wt, "diff", "--name-status", "--no-renames", base).stdout.splitlines():
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


def candidate_tree(wt: str, base: str, tmpdir: str | None = None) -> str:
    """A Git tree binding the complete candidate (contents, symlink targets, modes)."""
    owned = tmpdir is None
    tmpdir = tmpdir or tempfile.mkdtemp(prefix="aegl-cand-")
    index = os.path.join(tmpdir, "index")
    env = {"GIT_INDEX_FILE": index}
    try:
        if _git(wt, "read-tree", base, env=env).returncode != 0:
            raise RuntimeError("read-tree failed")
        if _git(wt, "add", "-A", env=env).returncode != 0:
            raise RuntimeError("add failed")
        out = _git(wt, "write-tree", env=env)
        if out.returncode != 0:
            raise RuntimeError("write-tree failed")
        return out.stdout.strip()
    finally:
        if owned:
            import shutil

            shutil.rmtree(tmpdir, ignore_errors=True)


def materialize_commit(proj: str, tree: str, base: str, tid: str) -> str:
    """Turn the approved tree into a commit object in the project object DB (deterministic)."""
    out = _git(proj, *FIXED_IDENT, "commit-tree", tree, "-p", base, "-m",
               "aegl-task(%s): approved candidate" % tid)
    if out.returncode != 0:
        raise RuntimeError("commit-tree failed")
    return out.stdout.strip()


def object_tree(proj: str, commit: str) -> str | None:
    out = _git(proj, "rev-parse", "--verify", "--quiet", "%s^{tree}" % commit)
    return out.stdout.strip() if out.returncode == 0 else None


def apply_object(proj: str, commit: str, tid: str) -> dict:
    """Apply exactly ``commit`` (a broker-built object) — no worktree re-read, no branch."""
    if _git(proj, "cat-file", "-e", "%s^{commit}" % commit).returncode != 0:
        return {"decision": "FAILED", "reason": "object_missing"}
    if _git(proj, *FIXED_IDENT, "merge", "--no-ff", "--no-verify",
            "-m", "aegl-promote: %s" % tid, commit).returncode != 0:
        return {"decision": "FAILED", "reason": "git_merge"}
    return {"decision": "APPLIED", "task_id": tid, "project": proj, "commit": commit}


def main(argv):
    if len(argv) < 2:
        print(json.dumps({"error": "usage: manifest|changes|tree|validate"}))
        return 2
    cmd = argv[0]
    if cmd == "manifest":
        print(candidate_manifest(argv[1]), end="")
        return 0
    if cmd == "tree":
        try:
            print(candidate_tree(argv[1], argv[2]))
        except RuntimeError as exc:
            print(json.dumps({"error": str(exc)}))
            return 1
        return 0
    if cmd == "changes":
        rows = changes_from_base(argv[1], argv[2])
        rejected = classify_rows(argv[1], rows)
        with open(argv[3], "w", encoding="utf-8") as handle:
            json.dump({"changes": rows, "rejected": rejected}, handle, indent=2)
        print(len(rejected))
        return 0
    if cmd == "validate":
        rows = changes_from_base(argv[1], argv[2])
        rejected = classify_rows(argv[1], rows)
        print(json.dumps({"decision": "REJECTED" if rejected else "VALIDATED",
                          "rejected": sorted({r["reject"] for r in rejected})}, sort_keys=True))
        return 0
    print(json.dumps({"error": "unknown command: %s" % cmd}))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
