#!/usr/bin/env python3
import json
import multiprocessing
import os
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "recovery"))
import model_task_registry as mtr  # noqa: E402

TEST_BASE = "/var/tmp"


def _git(cwd, *args):
    subprocess.run(["git", "-c", "safe.directory=*", "-C", str(cwd), *args],
                   check=True, capture_output=True, text=True)


def make_tree(base: Path, name: str) -> dict:
    """A real formal git repo plus a real git worktree of it, with a contract package."""
    root = base / name
    for path in (root, root / "scratch", root / "contract"):
        path.mkdir(parents=True, exist_ok=True)
        os.chmod(path, 0o755)

    formal = root / "formal"
    formal.mkdir(parents=True, exist_ok=True)
    os.chmod(formal, 0o755)
    _git(formal, "init", "-q", "-b", "main")
    _git(formal, "config", "user.email", "contract@local")
    _git(formal, "config", "user.name", "contract")
    (formal / "README.md").write_text("baseline\n", encoding="utf-8")
    _git(formal, "add", "-A")
    _git(formal, "commit", "-q", "-m", "baseline")

    project = root / "project"
    _git(formal, "worktree", "add", "-q", "--detach", str(project), "HEAD")
    os.chmod(project, 0o755)

    ctx = root / "contract" / "project-context.json"
    impl = root / "contract" / "implementation-contract.json"
    ctx.write_text(json.dumps({"source_root": str(root)}), encoding="utf-8")
    impl.write_text(json.dumps({"allowed_paths": ["project/"]}), encoding="utf-8")
    os.chmod(ctx, 0o644)
    os.chmod(impl, 0o644)
    return {
        "worktree": str(project),
        "scratch": str(root / "scratch"),
        "project": str(formal),
        "contract_package": str(root / "contract"),
    }


def _worker(registry: str, task_id: str, tree: dict, ai_uid: int, queue) -> None:
    try:
        mtr.register(
            registry,
            task_id,
            worktree=tree["worktree"],
            scratch=tree["scratch"],
            project=tree["project"],
            contract_package=tree["contract_package"],
            ai_uid=ai_uid,
            trusted_uid=ai_uid,
            require_root_owner=False,
        )
        queue.put(("ok", task_id))
    except Exception as exc:  # noqa: BLE001 - report the rejection reason
        queue.put(("err", task_id, getattr(exc, "reason", type(exc).__name__)))


class RegistryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="aegl-model-task-test-", dir=TEST_BASE)
        self.base = Path(self.tmp.name)
        self.registry = self.base / "registry.json"
        self.registry.write_text("{}\n", encoding="utf-8")
        os.chmod(self.registry, 0o644)
        self.ai_uid = os.getuid()

    def tearDown(self):
        self.tmp.cleanup()

    def register(self, task_id: str, tree: dict, *, trusted_uid=None) -> dict:
        if trusted_uid is None:
            trusted_uid = self.ai_uid
        return mtr.register(
            str(self.registry),
            task_id,
            worktree=tree["worktree"],
            scratch=tree["scratch"],
            project=tree["project"],
            contract_package=tree["contract_package"],
            ai_uid=self.ai_uid,
            trusted_uid=trusted_uid,
            require_root_owner=False,
        )

    def test_add_preserves_existing(self):
        old = make_tree(self.base, "old")
        self.register("old", old)
        before = json.loads(self.registry.read_text(encoding="utf-8"))
        new = make_tree(self.base, "new")
        self.register("new", new)
        after = json.loads(self.registry.read_text(encoding="utf-8"))
        self.assertIn("old", after)
        self.assertIn("new", after)
        self.assertEqual(before["old"], after["old"])

    def test_duplicate_rejected_without_byte_change(self):
        tree = make_tree(self.base, "dup")
        self.register("dup", tree)
        before = self.registry.read_bytes()
        with self.assertRaises(mtr.ValidationError) as ctx:
            self.register("dup", tree)
        self.assertEqual(ctx.exception.reason, "duplicate_task_id")
        self.assertEqual(before, self.registry.read_bytes())

    def test_bad_json_rejected_without_byte_change(self):
        self.registry.write_text("{bad", encoding="utf-8")
        before = self.registry.read_bytes()
        with self.assertRaises(mtr.RegistryInvalid) as ctx:
            self.register("x", make_tree(self.base, "x"))
        self.assertEqual(ctx.exception.reason, "bad_registry_json")
        self.assertEqual(before, self.registry.read_bytes())

    def test_existing_entry_missing_field_rejected(self):
        self.registry.write_text(json.dumps({"x": {"worktree": "/tmp"}}), encoding="utf-8")
        with self.assertRaises(mtr.RegistryInvalid) as ctx:
            self.register("y", make_tree(self.base, "y"))
        self.assertEqual(ctx.exception.reason, "bad_existing_entry")

    def test_new_entry_missing_field_rejected(self):
        tree = make_tree(self.base, "missing")
        entry = {
            "worktree": tree["worktree"],
            "project": tree["project"],
            "contract_package": tree["contract_package"],
        }
        with self.assertRaises(mtr.ValidationError) as ctx:
            mtr.validate_entry(entry, ai_uid=self.ai_uid, trusted_uid=self.ai_uid)
        self.assertEqual(ctx.exception.reason, "missing_field")

    def test_path_outside_allowed_base_rejected(self):
        tree = make_tree(self.base, "badpath")
        tree["worktree"] = "/home/zhong"
        with self.assertRaises(mtr.ValidationError) as ctx:
            self.register("badpath", tree)
        self.assertEqual(ctx.exception.reason, "path_outside_allowed_base")

    def test_contract_relation_rejected(self):
        tree = make_tree(self.base, "badcontract")
        (Path(tree["contract_package"]) / "implementation-contract.json").write_text(
            json.dumps({"allowed_paths": ["other/"]}), encoding="utf-8"
        )
        with self.assertRaises(mtr.ValidationError) as ctx:
            self.register("badcontract", tree)
        self.assertEqual(ctx.exception.reason, "worktree_not_allowed")

    def test_source_root_mismatch_rejected(self):
        tree = make_tree(self.base, "badroot")
        other = self.base / "elsewhere"
        other.mkdir()
        (Path(tree["contract_package"]) / "project-context.json").write_text(
            json.dumps({"source_root": str(other)}), encoding="utf-8"
        )
        with self.assertRaises(mtr.ValidationError) as ctx:
            self.register("badroot", tree)
        self.assertEqual(ctx.exception.reason, "worktree_outside_source_root")

    def test_contract_dir_writable_rejected(self):
        tree = make_tree(self.base, "contractwritable")
        contract = Path(tree["contract_package"])
        os.chmod(contract, 0o777)
        try:
            with self.assertRaises(mtr.ValidationError) as ctx:
                self.register("contractwritable", tree)
            self.assertEqual(ctx.exception.reason, "contract_writable")
        finally:
            os.chmod(contract, 0o755)

    def test_contract_file_writable_rejected(self):
        tree = make_tree(self.base, "contractfilewritable")
        target = Path(tree["contract_package"]) / "implementation-contract.json"
        os.chmod(target, 0o666)
        try:
            with self.assertRaises(mtr.ValidationError) as ctx:
                self.register("contractfilewritable", tree)
            self.assertEqual(ctx.exception.reason, "contract_file_writable")
        finally:
            os.chmod(target, 0o644)

    def test_contract_parent_writable_rejected(self):
        tree = make_tree(self.base, "contractparent")
        root = Path(tree["worktree"]).parent
        contract = Path(tree["contract_package"])
        os.chmod(contract, 0o555)
        os.chmod(root, 0o777)
        try:
            with self.assertRaises(mtr.ValidationError) as ctx:
                self.register("contractparent", tree)
            self.assertEqual(ctx.exception.reason, "contract_parent_writable")
        finally:
            os.chmod(root, 0o755)
            os.chmod(contract, 0o755)

    def test_contract_dir_not_trusted_rejected(self):
        tree = make_tree(self.base, "contractuntrusted")
        with self.assertRaises(mtr.ValidationError) as ctx:
            self.register("contractuntrusted", tree, trusted_uid=0)
        self.assertEqual(ctx.exception.reason, "contract_not_trusted")

    def test_contract_symlink_rejected(self):
        tree = make_tree(self.base, "contractlink")
        link = self.base / "contract-link"
        os.symlink(tree["contract_package"], link)
        tree["contract_package"] = str(link)
        with self.assertRaises(mtr.ValidationError) as ctx:
            self.register("contractlink", tree)
        self.assertEqual(ctx.exception.reason, "symlink_path")

    def test_registry_group_writable_rejected(self):
        before = self.registry.read_bytes()
        os.chmod(self.registry, 0o666)
        try:
            with self.assertRaises(mtr.RegistryInvalid) as ctx:
                self.register("x", make_tree(self.base, "x"))
            self.assertEqual(ctx.exception.reason, "registry_writable")
            self.assertEqual(before, self.registry.read_bytes())
        finally:
            os.chmod(self.registry, 0o644)

    def test_registry_symlink_rejected(self):
        target = self.base / "real-registry.json"
        target.write_text("{}\n", encoding="utf-8")
        os.chmod(target, 0o644)
        self.registry.unlink()
        os.symlink(target, self.registry)
        with self.assertRaises(mtr.RegistryInvalid) as ctx:
            self.register("x", make_tree(self.base, "x"))
        self.assertEqual(ctx.exception.reason, "registry_symlink")
        self.assertEqual(target.read_text(encoding="utf-8"), "{}\n")

    def test_mode_preserved(self):
        os.chmod(self.registry, 0o600)
        self.register("mode", make_tree(self.base, "mode"))
        self.assertEqual(stat.S_IMODE(os.stat(self.registry).st_mode), 0o600)

    def test_precommit_replace_failure_preserves_bytes_and_cleans_temp(self):
        self.register("keep", make_tree(self.base, "keep"))
        before = self.registry.read_bytes()
        tree = make_tree(self.base, "fail")
        with mock.patch.object(mtr.os, "replace", side_effect=OSError("boom")):
            with self.assertRaises(mtr.PrecommitIOError) as ctx:
                self.register("fail", tree)
        self.assertEqual(ctx.exception.exit_code, 6)
        self.assertEqual(ctx.exception.reason, "precommit_io")
        self.assertEqual(before, self.registry.read_bytes())
        leftovers = [p.name for p in self.base.iterdir() if p.name.startswith(".registry.")]
        self.assertEqual(leftovers, [])

    def test_precommit_fsync_failure_preserves_bytes_and_cleans_temp(self):
        self.register("keep", make_tree(self.base, "keepfsync"))
        before = self.registry.read_bytes()
        tree = make_tree(self.base, "failfsync")
        with mock.patch.object(mtr.os, "fsync", side_effect=OSError("boom")):
            with self.assertRaises(mtr.PrecommitIOError) as ctx:
                self.register("failfsync", tree)
        self.assertEqual(ctx.exception.exit_code, 6)
        self.assertEqual(ctx.exception.reason, "precommit_io")
        self.assertEqual(before, self.registry.read_bytes())
        leftovers = [p.name for p in self.base.iterdir() if p.name.startswith(".registry.")]
        self.assertEqual(leftovers, [])

    def test_precommit_metadata_failure_preserves_bytes_and_cleans_temp(self):
        self.register("keep", make_tree(self.base, "keepmeta"))
        before = self.registry.read_bytes()
        tree = make_tree(self.base, "failmeta")
        with mock.patch.object(mtr.os, "fchmod", side_effect=OSError("boom")):
            with self.assertRaises(mtr.PrecommitIOError) as ctx:
                self.register("failmeta", tree)
        self.assertEqual(ctx.exception.exit_code, 6)
        self.assertEqual(ctx.exception.reason, "precommit_io")
        self.assertEqual(before, self.registry.read_bytes())
        leftovers = [p.name for p in self.base.iterdir() if p.name.startswith(".registry.")]
        self.assertEqual(leftovers, [])

    def test_durability_uncertain_after_replace(self):
        tree = make_tree(self.base, "durable")
        with mock.patch.object(mtr, "_fsync_dir", side_effect=OSError("boom")):
            with self.assertRaises(mtr.DurabilityError) as ctx:
                self.register("durable", tree)
        self.assertEqual(ctx.exception.reason, "dir_fsync_failed")
        after = json.loads(self.registry.read_text(encoding="utf-8"))
        self.assertIn("durable", after)

    @unittest.skipIf(os.geteuid() == 0, "requires a non-root test runner")
    def test_cli_rejects_non_root(self):
        cmd = [
            sys.executable,
            str(REPO / "bin" / "aegl-model-task"),
            "register",
            "--task-id", "x",
            "--worktree", "/tmp/w",
            "--scratch", "/tmp/s",
            "--project", "/tmp/p",
            "--contract-package", "/tmp/c",
        ]
        proc = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(proc.returncode, 2)
        self.assertIn("reason=not_root", proc.stderr)

    def test_worktree_not_git_worktree_rejected(self):
        tree = make_tree(self.base, "notgitwt")
        # replace the real worktree with a plain directory (no git identity)
        wt = Path(tree["worktree"])
        subprocess.run(["git", "-c", "safe.directory=*", "-C", str(tree["project"]),
                        "worktree", "remove", "--force", str(wt)], check=True, capture_output=True)
        wt.mkdir()
        os.chmod(wt, 0o755)
        with self.assertRaises(mtr.ValidationError) as ctx:
            self.register("notgitwt", tree)
        self.assertEqual(ctx.exception.reason, "git_unavailable")

    def test_worktree_of_other_repo_rejected(self):
        tree = make_tree(self.base, "otherrepo")
        # a second, unrelated formal repo whose worktree is swapped in
        other = self.base / "otherrepo-formal"
        other.mkdir(parents=True, exist_ok=True)
        os.chmod(other, 0o755)
        _git(other, "init", "-q", "-b", "main")
        _git(other, "config", "user.email", "x@local")
        _git(other, "config", "user.name", "x")
        (other / "f.txt").write_text("x\n", encoding="utf-8")
        _git(other, "add", "-A")
        _git(other, "commit", "-q", "-m", "b")
        foreign = self.base / "otherrepo-wt"
        _git(other, "worktree", "add", "-q", "--detach", str(foreign), "HEAD")
        os.chmod(foreign, 0o755)
        tree["worktree"] = str(foreign)
        # keep the worktree inside source_root and allowed_paths so the git proof is the
        # only failing gate
        (Path(tree["contract_package"]) / "project-context.json").write_text(
            json.dumps({"source_root": str(self.base)}), encoding="utf-8"
        )
        (Path(tree["contract_package"]) / "implementation-contract.json").write_text(
            json.dumps({"allowed_paths": ["otherrepo-wt/"]}), encoding="utf-8"
        )
        with self.assertRaises(mtr.ValidationError) as ctx:
            self.register("otherrepo", tree)
        self.assertEqual(ctx.exception.reason, "worktree_not_project_repo")

    def test_genuine_worktree_accepted(self):
        tree = make_tree(self.base, "genuine")
        entry = self.register("genuine", tree)
        self.assertEqual(entry["worktree"], tree["worktree"])

    def test_legacy_four_field_registry_still_loads(self):
        """A pre-existing 4-field registry must load unchanged (no new required field)."""
        legacy = {
            "legacy-1": {
                "worktree": "/var/tmp/legacy/project",
                "scratch": "/var/tmp/legacy/scratch",
                "project": "/var/tmp/legacy/formal",
                "contract_package": "/var/tmp/legacy/contract",
            }
        }
        self.registry.write_text(json.dumps(legacy), encoding="utf-8")
        os.chmod(self.registry, 0o644)
        loaded = mtr._load_registry(str(self.registry), require_root_owner=False)
        self.assertEqual(loaded, legacy)
        self.assertEqual(mtr.ENTRY_FIELDS, ("worktree", "scratch", "project", "contract_package"))

    def _run_concurrent(self, tasks):
        ctx = multiprocessing.get_context("fork")
        queue = ctx.Queue()
        procs = [
            ctx.Process(
                target=_worker,
                args=(str(self.registry), task_id, tree, self.ai_uid, queue),
            )
            for task_id, tree in tasks
        ]
        for proc in procs:
            proc.start()
        for proc in procs:
            proc.join(10)
        results = [queue.get(timeout=2) for _ in procs]
        for proc in procs:
            proc.close()
        return results

    def test_concurrent_distinct_tasks_preserved(self):
        results = self._run_concurrent(
            [
                ("c1", make_tree(self.base, "c1")),
                ("c2", make_tree(self.base, "c2")),
            ]
        )
        self.assertTrue(all(result[0] == "ok" for result in results))
        data = json.loads(self.registry.read_text(encoding="utf-8"))
        self.assertEqual(set(data), {"c1", "c2"})

    def test_concurrent_duplicate_only_one_succeeds(self):
        tree = make_tree(self.base, "same")
        results = self._run_concurrent([("same", tree), ("same", tree)])
        oks = [result for result in results if result[0] == "ok"]
        errs = [result for result in results if result[0] == "err"]
        self.assertEqual(len(oks), 1)
        self.assertEqual(len(errs), 1)
        self.assertEqual(errs[0][2], "duplicate_task_id")
        data = json.loads(self.registry.read_text(encoding="utf-8"))
        self.assertEqual(set(data), {"same"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
