"""Real Git + real AEGL broker over a private Unix socket; no host/root/model changes.

Only installation is replaced with a temporary-file check: real root ownership,
service identities, mounts and runtime installation remain NOT_RUN here.
"""
import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import pwd
import shlex
import socket
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("iap_delivery", ROOT / "iap_delivery.py")
d = importlib.util.module_from_spec(spec)
spec.loader.exec_module(d)


def git(repo, *args):
    return subprocess.run(["git", "-c", "core.hooksPath=/dev/null", "-C", str(repo), *args],
                          capture_output=True, check=True).stdout.decode().strip()


class TestDelivery(d.Delivery):
    __test__ = False

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.calls = []
        self.fail_before = None
        self.fail_after = None
        self.status_failure = False
        self.install_count = 0

    def run(self, argv, **kwargs):
        if self.status_failure and "status" in argv:
            raise d.DeliveryError("command_failed: injected git status failure")
        return super().run(argv, **kwargs)

    def broker_call(self, row, op, decision, **kwargs):
        if self.fail_before == (row["name"], op):
            raise d.DeliveryError("injected_before_" + op)
        reply = super().broker_call(row, op, decision, **kwargs)
        self.calls.append((row["name"], op, copy.deepcopy(reply)))
        if self.fail_after == (row["name"], op):
            raise d.DeliveryError("injected_after_" + op)
        return reply

    def install(self):
        # Exercise the package's real relative payload paths, not the host installer.
        for rel in ("bin/aegl-model-task", "recovery/model_task_registry.py"):
            self.assert_payload(self.package / "payload/aegl" / rel)
        self.install_count += 1
        self.state["installed"] = True
        self.save()

    def assert_payload(self, path):
        d.require(path.is_file(), "test_payload_path_missing")

    def emit(self, value):
        pass


class FlowTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="iap-flow-", dir="/var/tmp")
        self.root = Path(self.tmp.name)
        self.projects = self.root / "projects"
        self.projects.mkdir()
        self.pkg = self.root / "package"
        self.pkg.mkdir()
        (self.pkg / "bundle").mkdir()
        (self.pkg / "payload/aegl/bin").mkdir(parents=True)
        (self.pkg / "payload/aegl/recovery").mkdir()
        (self.pkg / "payload/aegl/bin/aegl-model-task").write_text("test CLI\n")
        (self.pkg / "payload/aegl/recovery/model_task_registry.py").write_text("test module\n")
        self.release = {"schema": 1, "repos": []}
        for name, basename, branch in [("stack", "Google-Android-Agent-Development-Stack", "master"),
                                       ("aegl", "AI-Engineering-Governance-Layer", "main")]:
            repo = self.projects / basename
            repo.mkdir()
            git(repo, "init", "-q", "-b", branch)
            git(repo, "config", "user.name", "IAP offline test")
            git(repo, "config", "user.email", "iap-test@local.invalid")
            (repo / "source.txt").write_text("base\n")
            (repo / "removed.txt").write_text("old\n")
            git(repo, "add", "--", "source.txt", "removed.txt")
            git(repo, "commit", "-q", "-m", "base")
            base = git(repo, "rev-parse", "HEAD")
            git(repo, "switch", "-q", "-c", "candidate")
            (repo / "source.txt").write_text("final\n")
            (repo / "added.txt").write_text("added\n")
            git(repo, "add", "-A")
            git(repo, "commit", "-q", "-m", "candidate")
            final = git(repo, "rev-parse", "HEAD")
            bundle = "bundle/" + name + ".bundle"
            git(repo, "bundle", "create", str(self.pkg / bundle), base + "..HEAD")
            git(repo, "switch", "-q", branch)
            self.release["repos"].append({"name": name, "path": str(repo), "base": base, "final": final,
                                          "target_ref": "refs/heads/" + branch, "bundle": bundle, "gitlinks": {}})
        self.socket = self.root / "broker.sock"
        self.registry_dir = self.root / "registry"
        env = dict(os.environ, PROJECTS_ROOT=str(self.projects), AEGL_BROKER_REGISTRY_DIR=str(self.registry_dir),
                   AEGL_BROKER_ALLOW_RECORDERS=str(os.getuid()), AEGL_BROKER_ALLOW_REQUESTERS=str(os.getuid()),
                   PYTHONDONTWRITEBYTECODE="1")
        # Actual broker module / server / freeze / classify / CAS. Only its production
        # mount policy location is redirected away from the host for this isolated test.
        code = ("import sys;sys.path.insert(0," + repr(str(ROOT)) + ");import promotion_broker as b;"
                "b.ENTRY_BIND_POLICY=" + repr(str(self.root / "no-host-policy")) + ";"
                "sys.exit(b.main(['serve','--socket'," + repr(str(self.socket)) + "]))")
        self.server = subprocess.Popen([sys.executable, "-I", "-c", code], env=env,
                                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        deadline = time.monotonic() + 5
        while not self.socket.exists():
            if self.server.poll() is not None:
                raise RuntimeError(self.server.stderr.read().decode())
            if time.monotonic() > deadline:
                raise RuntimeError("test broker startup timeout")
            time.sleep(.01)
        self.client = self.root / "broker-client"
        self.client.write_text("#!/bin/sh\nexec " + shlex.quote(sys.executable) + " -B " +
                               shlex.quote(str(ROOT / "promotion_broker.py")) + ' "$@"\n')
        self.client.chmod(0o700)
        self.ledger = self.root / "ledger"
        self.ledger.mkdir()
        self.driver = self.new_driver()

    def new_driver(self):
        return TestDelivery(self.pkg, "a" * 64, self.release, self.ledger, self.root / "workspace",
                            operator=pwd.getpwuid(os.getuid()).pw_name, requester=pwd.getpwuid(os.getuid()).pw_name,
                            broker=self.client, socket=self.socket, registry=self.registry_dir / "registry.json")

    def tearDown(self):
        self.server.terminate()
        try:
            self.server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            self.server.kill()
            self.server.wait(timeout=5)
        self.server.stderr.close()
        self.tmp.cleanup()

    def test_complete_real_broker_flow_freezes_candidate_and_syncs_both(self):
        self.driver.execute()
        records = [reply for _, op, reply in self.driver.calls if op == "record"]
        self.assertEqual([x["approved_commit"] for x in records], [r["final"] for r in self.release["repos"]])
        for row in self.release["repos"]:
            self.assertEqual(git(row["path"], "rev-parse", row["target_ref"]), row["final"])
            self.assertEqual(git(row["path"], "status", "--porcelain"), "")
            self.assertEqual((Path(row["path"]) / "source.txt").read_text(), "final\n")
            self.assertEqual((Path(row["path"]) / "removed.txt").read_text(), "old\n")
            self.assertTrue((Path(row["path"]) / "added.txt").is_file())
        self.assertFalse(self.driver.workspace.exists())
        self.assertTrue(json.loads((self.ledger / "state.json").read_text())["complete"])

    def test_import_does_not_advance_target(self):
        self.driver.prepare_workspace()
        row = self.release["repos"][0]
        self.driver.import_objects(row)
        self.assertEqual(git(row["path"], "rev-parse", row["target_ref"]), row["base"])
        self.assertEqual(self.driver.calls, [])

    def test_payload_not_in_candidate_source_stops_before_any_broker(self):
        self.release["source_files"] = {"payload/aegl/bin/aegl-model-task": "source.txt"}
        with self.assertRaisesRegex(d.DeliveryError, "payload_not_from_approved_source"):
            self.driver.execute()
        self.assertEqual(self.driver.calls, [])
        for row in self.release["repos"]:
            self.assertEqual(git(row["path"], "rev-parse", row["target_ref"]), row["base"])

    def test_second_tree_dirty_stops_before_first_broker(self):
        p = Path(self.release["repos"][1]["path"]) / "source.txt"
        p.write_text("human edit\n")
        with self.assertRaisesRegex(d.DeliveryError, "formal_dirty_preserved"):
            self.driver.execute()
        self.assertEqual(self.driver.calls, [])
        self.assertEqual(p.read_text(), "human edit\n")

    def test_git_status_failure_stops_before_broker(self):
        self.driver.status_failure = True
        with self.assertRaisesRegex(d.DeliveryError, "git status failure"):
            self.driver.execute()
        self.assertEqual(self.driver.calls, [])

    def test_second_repo_failure_resumes_without_repromoting_first(self):
        self.driver.fail_before = ("aegl", "register")
        with self.assertRaisesRegex(d.DeliveryError, "injected_before"):
            self.driver.execute()
        first = self.release["repos"][0]
        self.assertEqual(git(first["path"], "rev-parse", "HEAD"), first["final"])
        resumed = self.new_driver()
        resumed.execute()
        self.assertFalse(any(name == "stack" and op in ("register", "record", "promote")
                             for name, op, _ in resumed.calls))
        self.assertTrue(any(name == "aegl" and op == "promote" for name, op, _ in resumed.calls))

    def test_lost_record_reply_is_reconciled_without_register_or_record(self):
        self.driver.fail_after = ("stack", "record")
        with self.assertRaisesRegex(d.DeliveryError, "injected_after_record"):
            self.driver.execute()
        resumed = self.new_driver()
        resumed.execute()
        self.assertFalse(any(name == "stack" and op in ("register", "record") for name, op, _ in resumed.calls))

    def test_lost_apply_reply_does_not_repeat_promotion(self):
        self.driver.fail_after = ("stack", "promote")
        with self.assertRaisesRegex(d.DeliveryError, "injected_after_promote"):
            self.driver.execute()
        resumed = self.new_driver()
        resumed.execute()
        self.assertFalse(any(name == "stack" and op in ("register", "record", "promote")
                             for name, op, _ in resumed.calls))

    def test_completed_promotion_with_regressed_ref_is_not_reapplied(self):
        row = self.release["repos"][0]
        self.driver.prepare_workspace()
        self.driver.import_objects(row)
        self.driver.promote(row)
        # Only a deliberately changed ref in this isolated fixture, never a host ref.
        git(row["path"], "update-ref", row["target_ref"], row["base"], row["final"])
        resumed = self.new_driver()
        resumed.load()
        with self.assertRaisesRegex(d.DeliveryError, "completed_promotion_target_regressed"):
            resumed.promote(row)
        self.assertEqual(resumed.calls, [])

    def test_post_cas_user_edit_is_preserved(self):
        row = self.release["repos"][0]
        self.driver.prepare_workspace()
        self.driver.import_objects(row)
        self.driver.promote(row)
        path = Path(row["path"]) / "source.txt"
        path.write_text("human edit after CAS\n")
        with self.assertRaisesRegex(d.DeliveryError, "worktree_edit_preserved"):
            self.driver.sync(row)
        self.assertEqual(path.read_text(), "human edit after CAS\n")

    def test_post_cas_staged_edit_is_preserved(self):
        row = self.release["repos"][0]
        self.driver.prepare_workspace()
        self.driver.import_objects(row)
        self.driver.promote(row)
        path = Path(row["path"]) / "source.txt"
        path.write_text("staged human edit\n")
        git(row["path"], "add", "source.txt")
        with self.assertRaisesRegex(d.DeliveryError, "staged_edit_preserved"):
            self.driver.sync(row)
        self.assertEqual(path.read_text(), "staged human edit\n")

    def test_ledger_for_different_candidate_is_rejected(self):
        self.driver.save()
        resumed = self.new_driver()
        resumed.release = copy.deepcopy(self.release)
        resumed.release["repos"][0]["final"] = "f" * 40
        with self.assertRaisesRegex(d.DeliveryError, "ledger_binding_mismatch"):
            resumed.execute()

    def test_known_gitlink_exception_is_exact_path_and_oid(self):
        row = self.release["repos"][0]
        row["gitlinks"] = {"references/architecture-templates": "1" * 40}
        tree = {"references/architecture-templates": ("160000", "1" * 40),
                "references/other": ("160000", "1" * 40)}
        self.assertTrue(self.driver.known_gitlink(row, b" M", "references/architecture-templates", tree, tree))
        self.assertFalse(self.driver.known_gitlink(row, b" M", "references/other", tree, tree))
        self.assertFalse(self.driver.known_gitlink(row, b"M ", "references/architecture-templates", tree, tree))
        changed = dict(tree, **{"references/architecture-templates": ("160000", "2" * 40)})
        self.assertFalse(self.driver.known_gitlink(row, b" M", "references/architecture-templates", tree, changed))

    def test_real_gitlink_dirt_survives_sync_only_for_exact_approved_path(self):
        repo = self.root / "gitlink-formal"
        repo.mkdir()
        git(repo, "init", "-q", "-b", "master")
        git(repo, "config", "user.name", "test")
        git(repo, "config", "user.email", "test@local.invalid")
        module = repo / "references/architecture-templates"
        module.mkdir(parents=True)
        git(module, "init", "-q")
        git(module, "config", "user.name", "test")
        git(module, "config", "user.email", "test@local.invalid")
        (module / "note.txt").write_text("module base\n")
        git(module, "add", "note.txt")
        git(module, "commit", "-q", "-m", "module")
        module_oid = git(module, "rev-parse", "HEAD")
        git(repo, "update-index", "--add", "--cacheinfo",
            "160000," + module_oid + ",references/architecture-templates")
        (repo / "source.txt").write_text("base\n")
        git(repo, "add", "source.txt")
        git(repo, "commit", "-q", "-m", "base")
        base = git(repo, "rev-parse", "HEAD")
        git(repo, "switch", "-q", "-c", "candidate")
        (repo / "source.txt").write_text("new\n")
        git(repo, "add", "source.txt")
        git(repo, "commit", "-q", "-m", "new")
        final = git(repo, "rev-parse", "HEAD")
        git(repo, "switch", "-q", "master")
        (module / "note.txt").write_text("preserved module edit\n")
        row = {"name":"stack", "path":str(repo), "target_ref":"refs/heads/master", "base":base,
               "final":final, "gitlinks":{"references/architecture-templates":module_oid}}
        self.driver.clean_formal(row, base)
        denied = dict(row, gitlinks={})
        with self.assertRaisesRegex(d.DeliveryError, "formal_dirty_preserved"):
            self.driver.clean_formal(denied, base)
        # Isolated fixture simulates an already-authorized CAS, then exercises the
        # actual sync implementation. No production ref is touched here.
        git(repo, "update-ref", row["target_ref"], final, base)
        self.driver.sync(row)
        self.assertEqual((module / "note.txt").read_text(), "preserved module edit\n")
        self.assertEqual((repo / "source.txt").read_text(), "new\n")

    def test_real_broker_does_not_fabricate_final_for_wrong_worktree(self):
        row = self.release["repos"][0]
        self.driver.prepare_workspace()
        self.driver.import_objects(row)
        self.driver.broker_call(row, "register", "REGISTERED", project=row["path"], base=row["base"],
                                worktree=row["path"], branch="incorrect-test-candidate", target_ref=row["target_ref"])
        with self.assertRaisesRegex(d.DeliveryError, "broker_approved_wrong_candidate"):
            self.driver.broker_call(row, "record", "RECORDED", verify_result="PASS")
        self.assertEqual(self.driver.entry(row)["approved_commit"], row["base"])
        self.assertEqual(git(row["path"], "rev-parse", row["target_ref"]), row["base"])


class ManifestTests(unittest.TestCase):
    def test_payload_tampering_and_bad_anchor_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="iap-manifest-", dir="/var/tmp") as t:
            p = Path(t)
            for rel in ("release.json", "iap_delivery.py"):
                (p / rel).write_text("test\n")
            (p / "MANIFEST.sha256").write_text("".join(d.digest(p / rel) + "  " + rel + "\n"
                                                     for rel in ("release.json", "iap_delivery.py")))
            anchor = d.digest(p / "MANIFEST.sha256")
            self.assertEqual(len(d.manifest_entries(p, anchor)), 2)
            (p / "iap_delivery.py").write_text("tampered\n")
            with self.assertRaisesRegex(d.DeliveryError, "payload_hash"):
                d.manifest_entries(p, anchor)
            with self.assertRaisesRegex(d.DeliveryError, "anchor_mismatch"):
                d.manifest_entries(p, "0" * 64)

    def test_installer_classifies_predecessor_new_unknown_and_symlink(self):
        with tempfile.TemporaryDirectory(prefix="iap-install-state-", dir="/var/tmp") as t:
            p = Path(t)
            (p / "old").write_text("old module\n")
            (p / "new").write_text("new module\n")
            target = p / "target"
            script = ('source "$1"; MOD_SHA=$(sha "$2/new"); MOD_SHA_OLD=$(sha "$2/old"); '
                      'install_target_state "$2/target"')
            def state():
                return subprocess.run(["bash", "-euo", "pipefail", "-c", script, "_",
                                       str(ROOT / "install-model-task-registry.sh"), str(p)],
                                      capture_output=True, check=True).stdout.decode().strip()
            self.assertEqual(state(), "ABSENT")
            (target / "recovery").mkdir(parents=True)
            module = target / "recovery/model_task_registry.py"
            module.write_bytes((p / "old").read_bytes())
            self.assertEqual(state(), "UPGRADABLE")
            module.write_bytes((p / "new").read_bytes())
            self.assertEqual(state(), "ALREADY_NEW")
            module.write_text("unknown\n")
            self.assertEqual(state(), "UNKNOWN")
            module.unlink()
            module.symlink_to(p / "new")
            self.assertEqual(state(), "UNKNOWN")


if __name__ == "__main__":
    unittest.main()
