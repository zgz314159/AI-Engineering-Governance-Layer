#!/usr/bin/env python3
"""AEGL central promotion gate + apply — the ONE implementation.

Full-stack promote freezes the **candidate tip commit** (full OID + tree OID) and
classifies that frozen tree — never a mutable branch name, never a worktree re-read
at apply time:

* :func:`freeze_candidate_commit` requires a clean worktree and returns
  ``(commit_oid, tree_oid)`` for ``HEAD``.
* :func:`classify_tree` classifies the frozen tree (``base``→``tree``): generated/
  secret paths, oversized blobs, symlink/path escapes and deletions; ignored-file
  presence is still checked on the worktree.
* :func:`apply_to_ref` fast-forwards a bound ``refs/heads/*`` to the approved commit
  via compare-and-swap ``update-ref`` when the registered target OID is unchanged and
  is an ancestor of the candidate — so ``main`` contains the candidate's history.

:func:`candidate_tree` / :func:`materialize_commit` remain for filter-free tree
inspection and legacy helpers; they are not the full-stack promote path.

A failed check, a changed target tip or a non-fast-forward leaves the target unchanged.
Candidate code is never executed here.

CLI: ``manifest`` · ``changes`` · ``tree`` · ``validate``.
"""

from __future__ import annotations

import json
import os
import re
import stat
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
# Disable hooks, monitors and attribute-driven clean/smudge filters for every git call.
GIT_HARDEN = [
    "-c", "core.hooksPath=/dev/null",
    "-c", "core.fsmonitor=false",
    "-c", "core.attributesFile=/dev/null",
]


def projects_root() -> str:
    return os.path.realpath(os.environ.get("PROJECTS_ROOT") or DEFAULT_PROJECTS_ROOT)


def _safe_directory_args(repo: str) -> list:
    """Command-level ``safe.directory`` for exact trusted paths only (no globs).

    Cross-UID Git (broker as aegl-promote on a zhong-owned worktree/repo) must not
    rely on user global config or ``safe.directory=*``.
    """
    paths = []
    try:
        paths.append(os.path.realpath(repo))
    except OSError:
        return []
    git_path = os.path.join(repo, ".git")
    try:
        if os.path.isfile(git_path):
            with open(git_path, encoding="utf-8") as handle:
                line = handle.readline().strip()
            if line.startswith("gitdir:"):
                gitdir = line.split(":", 1)[1].strip()
                if not os.path.isabs(gitdir):
                    gitdir = os.path.normpath(os.path.join(repo, gitdir))
                paths.append(os.path.realpath(gitdir))
                # Common object store: <repo>/.git  (parent of worktrees/<name>)
                common = os.path.realpath(os.path.join(gitdir, "..", ".."))
                if os.path.isdir(common):
                    paths.append(common)
        elif os.path.isdir(git_path):
            paths.append(os.path.realpath(git_path))
    except OSError:
        pass
    args = []
    seen = set()
    for path in paths:
        if path in seen:
            continue
        seen.add(path)
        args += ["-c", "safe.directory=%s" % path]
    return args


def _git(repo: str, *args, env=None, input_text=None, check=False) -> subprocess.CompletedProcess:
    merged = dict(GIT_ENV)
    if env:
        merged.update(env)
    return subprocess.run(
        ["git", "-C", repo, *_safe_directory_args(repo), *GIT_HARDEN, *args],
        capture_output=True, text=True, env=merged, input=input_text, check=check,
    )


def candidate_manifest(wt: str) -> str:
    script = (
        'cd "$1" && find . -name .git -prune -o -type f -print0 2>/dev/null '
        "| sort -z | xargs -0 -r sha256sum 2>/dev/null"
    )
    return subprocess.run(["bash", "-c", script, "_", wt], capture_output=True, text=True).stdout


def ignored_files(wt: str) -> list:
    return [
        p for p in _git(wt, "ls-files", "--others", "--ignored", "--exclude-standard").stdout.splitlines() if p
    ]


def changes_from_base(wt: str, base: str) -> list:
    rows = {}
    for line in _git(wt, "diff", "--name-status", "--no-renames", base).stdout.splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            rows[parts[-1]] = {"status": parts[0], "path": parts[-1]}
    for path in _git(wt, "ls-files", "--others", "--exclude-standard").stdout.splitlines():
        rows.setdefault(path, {"status": "??", "path": path})
    for path in ignored_files(wt):
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


def _blob_entry(wt: str, rel: str):
    """(mode, blob_sha) for one worktree path, hashed WITHOUT applying any filter."""
    ap = os.path.join(wt, rel)
    st = os.lstat(ap)
    if stat.S_ISLNK(st.st_mode):
        target = os.readlink(ap)
        sha = _git(wt, "hash-object", "-w", "--no-filters", "--stdin", input_text=target).stdout.strip()
        return "120000", sha
    sha = _git(wt, "hash-object", "-w", "--no-filters", "--", ap).stdout.strip()
    mode = "100755" if (st.st_mode & 0o111) else "100644"
    return mode, sha


def candidate_tree(wt: str, base: str, tmpdir: str | None = None) -> str:
    """A frozen Git tree bound to the candidate (contents, symlink targets, modes).

    Staged with ``hash-object --no-filters`` + ``update-index --cacheinfo`` so no
    untrusted clean filter, hook or fsmonitor runs.
    """
    owned = tmpdir is None
    tmpdir = tmpdir or tempfile.mkdtemp(prefix="aegl-tree-")
    index = os.path.join(tmpdir, "index")
    env = {"GIT_INDEX_FILE": index}
    try:
        if _git(wt, "read-tree", base, env=env).returncode != 0:
            raise RuntimeError("read-tree failed")
        paths = [p for p in _git(wt, "ls-files", "-co", "--exclude-standard", "-z").stdout.split("\0") if p]
        for rel in paths:
            if not os.path.lexists(os.path.join(wt, rel)):
                _git(wt, "update-index", "--force-remove", "--", rel, env=env)
                continue
            mode, sha = _blob_entry(wt, rel)
            if not sha:
                raise RuntimeError("hash-object failed for %s" % rel)
            if _git(wt, "update-index", "--add", "--cacheinfo", "%s,%s,%s" % (mode, sha, rel), env=env).returncode != 0:
                raise RuntimeError("update-index failed for %s" % rel)
        out = _git(wt, "write-tree", env=env)
        if out.returncode != 0:
            raise RuntimeError("write-tree failed")
        return out.stdout.strip()
    finally:
        if owned:
            import shutil

            shutil.rmtree(tmpdir, ignore_errors=True)


def _tree_entry(proj: str, tree: str, path: str):
    out = _git(proj, "ls-tree", "-z", tree, "--", path).stdout
    if not out:
        return None
    meta = out.split("\t", 1)[0].split()
    return meta[0], meta[2]  # mode, sha


def classify_tree(proj: str, base: str, tree: str, wt: str | None = None) -> list:
    """Classify the FROZEN tree (base→tree); also reject any ignored files present."""
    rejected = []
    if wt is not None and ignored_files(wt):
        rejected.append({"path": "", "status": "!!", "reject": "ignored_file_present"})
    for line in _git(proj, "diff", "--name-status", "--no-renames", base, tree).stdout.splitlines():
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        status, path = parts[0], parts[-1]
        reason = None
        if path.startswith("/") or ".." in path.split("/"):
            reason = "path_escape"
        elif GEN.search(path):
            reason = "generated_or_secret"
        elif "D" in status:
            reason = "deleted_project_body"
        else:
            entry = _tree_entry(proj, tree, path)
            if entry is None:
                reason = "path_escape"
            else:
                mode, sha = entry
                if mode == "120000":
                    target = _git(proj, "cat-file", "blob", sha).stdout
                    if target.startswith("/") or ".." in target.split("/"):
                        reason = "symlink_escape"
                else:
                    size = int((_git(proj, "cat-file", "-s", sha).stdout or "0").strip() or 0)
                    if size > 5_000_000:
                        reason = "oversize"
        if reason:
            rejected.append({"status": status, "path": path, "reject": reason})
    return rejected


def materialize_commit(proj: str, tree: str, base: str, tid: str) -> str:
    """Legacy helper: synthetic commit-tree snapshot (not used for full-stack promote)."""
    out = _git(proj, *FIXED_IDENT, "commit-tree", tree, "-p", base, "-m",
               "aegl-task(%s): approved candidate" % tid)
    if out.returncode != 0:
        raise RuntimeError("commit-tree failed")
    return out.stdout.strip()


def object_tree(proj: str, commit: str):
    out = _git(proj, "rev-parse", "--verify", "--quiet", "%s^{tree}" % commit)
    return out.stdout.strip() if out.returncode == 0 else None


def ref_oid(proj: str, ref: str):
    out = _git(proj, "rev-parse", "--verify", "--quiet", ref)
    return out.stdout.strip() if out.returncode == 0 else None


def is_ancestor(proj: str, maybe_ancestor: str, commit: str) -> bool:
    return _git(proj, "merge-base", "--is-ancestor", maybe_ancestor, commit).returncode == 0


def freeze_candidate_commit(wt: str) -> tuple:
    """Freeze the candidate tip: full commit OID + tree OID.

    Requires a clean worktree whose HEAD commit is the candidate. Dirty or
    uncommitted content is rejected — promotion applies that exact commit's
    history, never a commit-tree snapshot of a mutable tree.
    """
    head = _git(wt, "rev-parse", "--verify", "--quiet", "HEAD")
    if head.returncode != 0 or len(head.stdout.strip()) != 40:
        raise RuntimeError("candidate_head_missing")
    commit = head.stdout.strip()
    status = _git(wt, "status", "--porcelain")
    if status.returncode != 0:
        # Never treat a failed Git check (e.g. safe.directory / EACCES) as clean.
        raise RuntimeError("worktree_status_failed")
    if status.stdout.strip():
        raise RuntimeError("worktree_dirty")
    tree = object_tree(wt, commit)
    if not tree or len(tree) != 40:
        raise RuntimeError("candidate_tree_missing")
    return commit, tree


def apply_to_ref(proj: str, commit: str, target_ref: str, expected_oid: str, tid: str) -> dict:
    """Fast-forward ``target_ref`` to the approved commit when history allows.

    Uses compare-and-swap ``update-ref`` so a changed tip is refused. Does not
    checkout, switch branches, or merge into whatever HEAD the formal tree has.
    After a successful apply, ``commit`` is reachable from ``target_ref``.
    """
    if _git(proj, "cat-file", "-e", "%s^{commit}" % commit).returncode != 0:
        return {"decision": "FAILED", "reason": "object_missing"}
    if not isinstance(target_ref, str) or not target_ref.startswith("refs/heads/"):
        return {"decision": "FAILED", "reason": "invalid_target_ref"}
    if not isinstance(expected_oid, str) or len(expected_oid) != 40:
        return {"decision": "FAILED", "reason": "invalid_expected_oid"}
    current = ref_oid(proj, target_ref)
    if current is None:
        return {"decision": "FAILED", "reason": "target_ref_missing"}
    if current != expected_oid:
        return {"decision": "REJECTED", "reason": "target_changed",
                "expected": expected_oid, "actual": current}
    if current == commit:
        return {"decision": "APPLIED", "task_id": tid, "project": proj,
                "commit": commit, "target_ref": target_ref, "mode": "already"}
    if not is_ancestor(proj, current, commit):
        return {"decision": "FAILED", "reason": "not_fast_forward",
                "target": current, "commit": commit}
    # CAS: fail if target moved between the check above and the write.
    upd = _git(proj, "update-ref", target_ref, commit, expected_oid)
    if upd.returncode != 0:
        again = ref_oid(proj, target_ref)
        if again and again != expected_oid:
            return {"decision": "REJECTED", "reason": "target_changed",
                    "expected": expected_oid, "actual": again}
        return {"decision": "FAILED", "reason": "update_ref",
                "detail": (upd.stderr or upd.stdout or "").strip()}
    new_tip = ref_oid(proj, target_ref)
    if new_tip != commit:
        return {"decision": "FAILED", "reason": "post_apply_mismatch",
                "expected": commit, "actual": new_tip}
    if not is_ancestor(proj, commit, new_tip) and new_tip != commit:
        return {"decision": "FAILED", "reason": "history_not_preserved"}
    return {"decision": "APPLIED", "task_id": tid, "project": proj,
            "commit": commit, "target_ref": target_ref, "mode": "fast_forward"}


def apply_object(proj: str, commit: str, tid: str) -> dict:
    """Backward-compat shim — full-stack promote must call :func:`apply_to_ref`."""
    return {"decision": "FAILED", "reason": "apply_object_requires_target_bind"}


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
        with open(argv[3], "w", encoding="utf-8") as handle:
            json.dump({"changes": rows, "rejected": classify_rows(argv[1], rows)}, handle, indent=2)
        print(len(classify_rows(argv[1], rows)))
        return 0
    if cmd == "validate":
        rows = classify_rows(argv[1], changes_from_base(argv[1], argv[2]))
        print(json.dumps({"decision": "REJECTED" if rows else "VALIDATED",
                          "rejected": sorted({r["reject"] for r in rows})}, sort_keys=True))
        return 0
    print(json.dumps({"error": "unknown command: %s" % cmd}))
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
