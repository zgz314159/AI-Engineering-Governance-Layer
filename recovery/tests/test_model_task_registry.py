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


def make_tree(base: Path, name: str) -> dict:
    root = base / name
    (root / "project").mkdir(parents=True)
    (root / "scratch").mkdir()
    (root / "contract").mkdir()
    (root / "formal" / ".git").mkdir(parents=True)
    (root / "contract" / "project-context.json").write_text(
        json.dumps({"source_root": str(root)}), encoding="utf-8"
    )
    (root / "contract" / "implementation-contract.json").write_text(
        json.dumps({"allowed_paths": ["project/"]}), encoding="utf-8"
    )
    return {
        "worktree": str(root / "project"),
        "scratch": str(root / "scratch"),
        "project": str(root / "formal"),
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
        self.ai_uid = os.getuid()

    def tearDown(self):
        self.tmp.cleanup()

    def register(self, task_id: str, tree: dict) -> dict:
        return mtr.register(
            str(self.registry),
            task_id,
            worktree=tree["worktree"],
            scratch=tree["scratch"],
            project=tree["project"],
            contract_package=tree["contract_package"],
            ai_uid=self.ai_uid,
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
            mtr.validate_entry(entry, ai_uid=self.ai_uid)
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

    def test_mode_preserved(self):
        os.chmod(self.registry, 0o600)
        self.register("mode", make_tree(self.base, "mode"))
        self.assertEqual(stat.S_IMODE(os.stat(self.registry).st_mode), 0o600)

    def test_precommit_failure_preserves_bytes_and_cleans_temp(self):
        self.register("keep", make_tree(self.base, "keep"))
        before = self.registry.read_bytes()
        tree = make_tree(self.base, "fail")
        with mock.patch.object(mtr.os, "replace", side_effect=OSError("boom")):
            with self.assertRaises(mtr.RegistryError) as ctx:
                self.register("fail", tree)
        self.assertEqual(ctx.exception.reason, "replace_io")
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
