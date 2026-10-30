#!/usr/bin/env python3
"""Frozen IAP control-plane delivery. No model calls or business-task registration.

Production paths and identities are fixed by main(); tests exercise Delivery with
temporary repositories and a real, isolated promotion broker. There is deliberately
no environment switch that disables production permissions or changes repositories.
"""
from __future__ import annotations

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import pwd
import re
import shutil
import stat
import subprocess
import sys
import tempfile

HEX40 = re.compile(r"[0-9a-f]{40}\Z")
HEX64 = re.compile(r"[0-9a-f]{64}\Z")
FAILED_IMPORT_ANCHOR = "a41e8c53488955881853830bed1d57868ebe001dc2899b191638ea104729e32f"
FAILED_IMPORT_AEGL = "34cbf247ad5fb1dd3fdf4cadaa5f7e066ba29a29"
PRODUCTION = {
    "stack": ("/home/zhong/Projects/Google-Android-Agent-Development-Stack", "master",
              "3a93066de216e731900870d145032bbb995fb92f"),
    "aegl": ("/home/zhong/Projects/AI-Engineering-Governance-Layer", "main",
             "19c069d318ac5846864224d7950c9191fa900b2a"),
}
GITLINK = {"references/architecture-templates": "4a3b2a141f457f1312c8dc52d6cbea6c9592af72"}
PACKAGE_SOURCES = {
    "iap_delivery.py": "recovery/iap_delivery.py",
    "bootstrap.sh": "recovery/iap-delivery-bootstrap.sh",
    "install-model-task-registry.sh": "recovery/install-model-task-registry.sh",
    "payload/aegl/bin/aegl-model-task": "bin/aegl-model-task",
    "payload/aegl/recovery/model_task_registry.py": "recovery/model_task_registry.py",
    "payload/aegl/recovery/gt1-install-manifest.txt": "recovery/gt1-install-manifest.txt",
    "README.md": "docs/IAP-DELIVERY.md",
}


class DeliveryError(RuntimeError):
    pass


def require(ok, reason):
    if not ok:
        raise DeliveryError(reason)


def digest(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def manifest_entries(package, anchor):
    package = Path(package)
    require(HEX64.fullmatch(anchor), "invalid_package_anchor")
    require(not (package / "MANIFEST.sha256").is_symlink(), "manifest_symlink")
    require(digest(package / "MANIFEST.sha256") == anchor, "package_anchor_mismatch")
    entries = {}
    for line in (package / "MANIFEST.sha256").read_text().splitlines():
        m = re.fullmatch(r"([0-9a-f]{64})  ([A-Za-z0-9_./-]+)", line)
        require(m is not None, "invalid_manifest_line")
        sha, rel = m.groups()
        parts = PurePosixPath(rel).parts
        require(parts and not rel.startswith("/") and all(p not in (".", "..") for p in parts),
                "invalid_manifest_path")
        require(str(PurePosixPath(rel)) == rel and rel not in entries, "duplicate_or_noncanonical_path")
        p = package
        for part in parts:
            p = p / part
            require(not p.is_symlink(), "payload_symlink:" + rel)
        require(p.is_file() and digest(p) == sha, "payload_hash:" + rel)
        entries[rel] = sha
    require(entries and "release.json" in entries and "iap_delivery.py" in entries, "incomplete_manifest")
    return entries


def atomic_json(path, data):
    path = Path(path)
    fd, tmp = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, sort_keys=True)
            f.write("\n")
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
        dfd = os.open(path.parent, os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def status_rows(raw):
    """NUL porcelain; renames are disabled at the caller, never shell-parsed."""
    rows = []
    for row in raw.split(b"\0"):
        if row:
            require(len(row) >= 4 and row[2:3] == b" ", "invalid_git_status")
            rows.append((row[:2], os.fsdecode(row[3:])))
    return rows


class Delivery:
    def __init__(self, package, anchor, release, ledger, workspace, *, operator="aegl-promote",
                 requester="aegl-ai", broker="/usr/local/lib/aegl-promote/aegl-promote-broker",
                 socket="/run/aegl-promote/broker.sock", registry="/var/lib/aegl-promote/registry.json"):
        self.package, self.anchor, self.release = Path(package), anchor, release
        self.ledger, self.workspace = Path(ledger), Path(workspace)
        self.operator, self.requester = operator, requester
        self.broker, self.socket, self.registry = str(broker), str(socket), Path(registry)
        self.state = {"anchor": anchor, "release": release, "repos": {}}
        self.stage = "preflight"

    def emit(self, value):
        print(value, flush=True)

    def run(self, argv, *, user=None, data=None, check=True):
        env = {"PATH": "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
               "HOME": "/nonexistent", "LANG": "C.UTF-8", "GIT_CONFIG_NOSYSTEM": "1",
               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
               "PYTHONDONTWRITEBYTECODE": "1"}
        if user and os.geteuid() == 0:
            argv = ["runuser", "-u", user, "--", *map(str, argv)]
        p = subprocess.run(list(map(str, argv)), input=data, capture_output=True, env=env, timeout=180)
        if check and p.returncode:
            raise DeliveryError("command_failed rc=%s cmd=%s detail=%s" %
                                (p.returncode, argv[0], os.fsdecode(p.stderr)[:450]))
        return p

    def git(self, repo, *args, data=None, check=True):
        repo = Path(repo)
        common = repo / ".git"
        if common.is_file():
            text = common.read_text().strip()
            require(text.startswith("gitdir: "), "invalid_worktree_gitfile")
            gitdir = (repo / text[8:]).resolve()
            common = (gitdir / "commondir")
            common = (gitdir / common.read_text().strip()).resolve() if common.is_file() else gitdir
        argv = ["git", "-c", "safe.directory=" + str(repo.resolve()),
                "-c", "safe.directory=" + str(common.resolve()),
                "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
                "-c", "submodule.recurse=false", "-C", str(repo), *args]
        return self.run(argv, user=self.operator, data=data, check=check)

    def oid(self, row, revision):
        value = self.git(row["path"], "rev-parse", "--verify", revision).stdout.decode().strip()
        require(HEX40.fullmatch(value), "invalid_git_oid")
        return value

    def rows(self, repo):
        return status_rows(self.git(repo, "-c", "status.renames=false", "status", "--porcelain=v1",
                                    "-z", "--untracked-files=all").stdout)

    def tree(self, row, oid):
        result = {}
        for item in self.git(row["path"], "ls-tree", "-rz", "--full-tree", oid).stdout.split(b"\0"):
            if item:
                meta, name = item.split(b"\t", 1)
                mode, kind, obj = meta.decode().split()
                result[os.fsdecode(name)] = (mode, obj)
        return result

    def index(self, row):
        result = {}
        for item in self.git(row["path"], "ls-files", "--stage", "-z").stdout.split(b"\0"):
            if item:
                meta, name = item.split(b"\t", 1)
                mode, obj, stage = meta.decode().split()
                require(stage == "0", "unmerged_index")
                result[os.fsdecode(name)] = (mode, obj)
        return result

    def known_gitlink(self, row, xy, name, tree, index):
        expected = row.get("gitlinks", {}).get(name)
        return (xy == b" M" and expected is not None and
                tree.get(name) == index.get(name) == ("160000", expected))

    def clean_formal(self, row, expected):
        require(self.git(row["path"], "symbolic-ref", "HEAD").stdout.decode().strip() == row["target_ref"],
                "formal_branch_changed")
        require(self.oid(row, row["target_ref"]) == expected and self.oid(row, "HEAD") == expected,
                "formal_baseline_changed")
        tree, index = self.tree(row, expected), self.index(row)
        for xy, name in self.rows(row["path"]):
            require(self.known_gitlink(row, xy, name, tree, index), "formal_dirty_preserved:" + name)

    def save(self):
        atomic_json(self.ledger / "state.json", self.state)

    def load(self):
        p = self.ledger / "state.json"
        if p.exists():
            require(not p.is_symlink(), "ledger_state_symlink")
            if os.geteuid() == 0:
                check_root_path(p, 0o600)
            loaded = json.loads(p.read_text())
            require(loaded.get("anchor") == self.anchor and loaded.get("release") == self.release,
                    "ledger_binding_mismatch")
            self.state = loaded

    def checkpoint(self, name, step):
        self.state["repos"].setdefault(name, {})[step] = True
        self.save()
        self.emit("STEP_OK repo=%s step=%s" % (name, step))

    def prepare_workspace(self):
        if not self.workspace.exists():
            self.workspace.mkdir(mode=0o700)
        require(not self.workspace.is_symlink(), "workspace_symlink")
        if os.geteuid() == 0:
            who = pwd.getpwnam(self.operator)
            st = self.workspace.stat()
            require(st.st_uid == 0 and not st.st_mode & 0o027, "workspace_untrusted")
            os.chown(self.workspace, 0, who.pw_gid)
            os.chmod(self.workspace, 0o750)
        bundles = self.workspace / "bundles"
        bundles.mkdir(mode=0o750, exist_ok=True)
        require(not bundles.is_symlink(), "bundles_symlink")
        if os.geteuid() == 0:
            check_root_path(bundles)
            os.chown(bundles, 0, pwd.getpwnam(self.operator).pw_gid)
            os.chmod(bundles, 0o750)
        for row in self.release["repos"]:
            src, dst = self.package / row["bundle"], bundles / (row["name"] + ".bundle")
            require(not dst.is_symlink(), "bundle_symlink")
            if not dst.exists():
                shutil.copyfile(src, dst)
            elif os.geteuid() == 0:
                check_root_path(dst)
            require(digest(src) == digest(dst), "staged_bundle_hash")
            if os.geteuid() == 0:
                os.chown(dst, 0, pwd.getpwnam(self.operator).pw_gid)
            os.chmod(dst, 0o640)

    def import_objects(self, row):
        before = self.oid(row, row["target_ref"])
        require(before in (row["base"], row["final"]), "target_ref_changed")
        bundle = self.workspace / "bundles" / (row["name"] + ".bundle")
        self.git(row["path"], "bundle", "verify", str(bundle))
        heads = self.git(row["path"], "bundle", "list-heads", str(bundle)).stdout.decode().splitlines()
        require(row["final"] + " HEAD" in heads, "bundle_head_mismatch")
        ref = "refs/aegl-delivery/%s/%s" % (self.anchor[:16], row["name"])
        self.git(row["path"], "fetch", "--no-write-fetch-head", str(bundle), "HEAD:" + ref)
        require(self.oid(row, ref) == row["final"] and self.oid(row, row["target_ref"]) == before,
                "import_changed_target")
        self.git(row["path"], "merge-base", "--is-ancestor", row["base"], row["final"])
        self.checkpoint(row["name"], "import")

    def candidate(self, row):
        candidate = self.workspace / (row["name"] + "-candidate")
        if not candidate.exists():
            candidate.mkdir(mode=0o700)
            if os.geteuid() == 0:
                who = pwd.getpwnam(self.operator)
                os.chown(candidate, who.pw_uid, who.pw_gid)
        require(candidate.is_dir() and not candidate.is_symlink(), "candidate_path_untrusted")
        if os.geteuid() == 0:
            st = candidate.stat()
            require(st.st_uid == pwd.getpwnam(self.operator).pw_uid and not st.st_mode & 0o022,
                    "candidate_owner_mode")
        if not (candidate / ".git").exists():
            require(not list(candidate.iterdir()), "candidate_not_empty")
            self.git(row["path"], "worktree", "add", "--detach", str(candidate), row["final"])
        require(self.git(candidate, "rev-parse", "HEAD").stdout.decode().strip() == row["final"],
                "candidate_head_mismatch")
        require(not self.rows(candidate), "candidate_dirty")
        require(self.git(candidate, "rev-parse", "--path-format=absolute", "--git-common-dir").stdout.decode().strip()
                == str(Path(row["path"]) / ".git"), "candidate_common_dir_mismatch")
        return candidate

    def task_id(self, row):
        return "iap-%s-%s" % (self.anchor[:16], row["name"])

    def entry(self, row):
        if not self.registry.exists():
            return None
        st = self.registry.stat()
        if os.geteuid() == 0:
            require(not self.registry.is_symlink() and st.st_uid in (0, pwd.getpwnam(self.operator).pw_uid)
                    and not st.st_mode & 0o022, "broker_registry_untrusted")
        value = json.loads(self.registry.read_text())
        return value.get(self.task_id(row))

    def checked_entry(self, row, candidate):
        e = self.entry(row)
        if e is not None:
            expected = {"project": row["path"], "base": row["base"], "worktree": str(candidate),
                        "target_ref": row["target_ref"], "target_oid": row["base"]}
            require(all(e.get(k) == v for k, v in expected.items()), "broker_registration_mismatch")
            require(e.get("approved_commit") in (None, row["final"]), "approved_commit_mismatch")
        return e

    def verify_previous_imports(self, anchor, ledger, workspace, previous_aegl):
        """Read-only guard before replacing a package that failed at its launcher.

        A new source commit needs a new package anchor. Do not invent fresh broker
        identities if the superseded package actually reached registration/CAS.
        Retain its artifacts until the replacement has completed successfully.
        """
        ledger, workspace = Path(ledger), Path(workspace)
        if not ledger.exists():
            require(not workspace.exists(), "previous_import_ledger_missing")
            return
        state_path = ledger / "state.json"
        if os.geteuid() == 0:
            check_root_path(ledger, 0o700)
            check_root_path(state_path, 0o600)
        value = json.loads(state_path.read_text())
        require(set(value) == {"anchor", "release", "repos"} and value["anchor"] == anchor,
                "previous_import_state_changed")
        expected_release = json.loads(json.dumps(self.release))
        for row in expected_release["repos"]:
            if row["name"] == "aegl":
                row["final"] = previous_aegl
        require(value["release"] == expected_release and value["repos"] == {
            "stack": {"import": True, "pre_cas": True}, "aegl": {"import": True}},
                "previous_import_progress_not_compatible")
        previous = Delivery(self.package, anchor, expected_release, ledger, workspace,
                            operator=self.operator, requester=self.requester,
                            broker=self.broker, socket=self.socket, registry=self.registry)
        for row in expected_release["repos"]:
            require(previous.entry(row) is None, "previous_broker_task_already_registered")
            ref = "refs/aegl-delivery/%s/%s" % (anchor[:16], row["name"])
            require(self.oid(row, ref) == row["final"], "previous_import_ref_changed")
        self.emit("PREVIOUS_IMPORT_ONLY=VERIFIED (no old broker registrations; old artifacts retained)")

    def broker_call(self, row, op, decision, **kwargs):
        request = {"protocol": "AEGL-BROKER/1", "op": op, "task_id": self.task_id(row), **kwargs}
        # The installed shell launcher requires this variable before it parses
        # arguments. Set it after runuser, inside our otherwise sanitized env.
        p = self.run(["/usr/bin/env", "AEGL_BROKER_SOCKET=" + self.socket,
                      self.broker, "client", "--request", json.dumps(request)],
                     user=self.requester if op in ("promote", "validate") else None, check=False)
        try:
            reply = json.loads(p.stdout)
        except ValueError as exc:
            # Do not echo arbitrary broker output (or request bodies). Distinguish
            # launcher failure from a malformed successful protocol response.
            raise DeliveryError("broker_client_failed op=%s rc=%s stdout_bytes=%s stderr_bytes=%s" %
                                (op, p.returncode, len(p.stdout), len(p.stderr))) from exc
        require(isinstance(reply, dict), "broker_reply_not_object")
        require(p.returncode == 0 and reply.get("decision") == decision,
                "broker_%s rc=%s decision=%s reason=%s" %
                (op, p.returncode, reply.get("decision"), reply.get("reason", "")))
        if op == "record":
            require(reply.get("approved_commit") == row["final"], "broker_approved_wrong_candidate")
        self.emit("BROKER_%s repo=%s decision=%s" % (op.upper(), row["name"], decision))
        return reply

    def promote(self, row):
        candidate = self.workspace / (row["name"] + "-candidate")
        entry = self.checked_entry(row, candidate)
        current = self.oid(row, row["target_ref"])
        require(current in (row["base"], row["final"]), "target_ref_changed")
        if self.state["repos"].get(row["name"], {}).get("broker"):
            require(current == row["final"], "completed_promotion_target_regressed")
        if current == row["final"]:
            require(entry and entry.get("approved_commit") == row["final"], "target_not_bound_to_approval")
            self.broker_call(row, "validate", "VALIDATED")
            self.emit("BROKER_RECONCILED repo=" + row["name"])
        else:
            self.clean_formal(row, row["base"])
            self.checkpoint(row["name"], "pre_cas")
            candidate = self.candidate(row)
            if entry is None:
                self.broker_call(row, "register", "REGISTERED", project=row["path"], base=row["base"],
                                 worktree=str(candidate), branch="iap-" + self.anchor[:16],
                                 target_ref=row["target_ref"])
                entry = self.checked_entry(row, candidate)
            require(entry is not None, "registration_not_persisted")
            if entry.get("approved_commit") is None:
                self.broker_call(row, "record", "RECORDED", verify_result="PASS")
            entry = self.checked_entry(row, candidate)
            require(entry.get("approved_commit") == row["final"], "record_not_persisted")
            self.clean_formal(row, row["base"])
            self.broker_call(row, "promote", "APPLIED")
            require(self.oid(row, row["target_ref"]) == row["final"], "promote_target_mismatch")
        self.checkpoint(row["name"], "broker")

    def worktree_entry(self, row, name):
        p = Path(row["path"]) / name
        parent = p.parent
        while parent != Path(row["path"]):
            require(not parent.is_symlink(), "worktree_parent_symlink:" + name)
            parent = parent.parent
        if not p.exists() and not p.is_symlink():
            return None
        st = p.lstat()
        if stat.S_ISLNK(st.st_mode):
            content, mode = os.fsencode(os.readlink(p)), "120000"
        else:
            require(stat.S_ISREG(st.st_mode), "unexpected_worktree_type:" + name)
            content = p.read_bytes()
            mode = "100755" if st.st_mode & 0o111 else "100644"
        obj = self.git(row["path"], "hash-object", "--stdin", data=content).stdout.decode().strip()
        return mode, obj

    def sync(self, row):
        require(self.oid(row, row["target_ref"]) == row["final"], "sync_target_not_final")
        require(self.git(row["path"], "symbolic-ref", "HEAD").stdout.decode().strip() == row["target_ref"],
                "formal_branch_changed")
        old, new, index = self.tree(row, row["base"]), self.tree(row, row["final"]), self.index(row)
        if index == new:
            self.clean_formal(row, row["final"])
            self.checkpoint(row["name"], "formal_sync")
            self.emit("SYNC_VERIFIED repo=" + row["name"])
            return
        for xy, name in self.rows(row["path"]):
            require(xy != b"??", "untracked_file_preserved:" + name)
        for name in old.keys() | new.keys() | index.keys():
            choices = (old.get(name), new.get(name))
            require(index.get(name) in choices, "staged_edit_preserved:" + name)
            if any(v is not None and v[0] == "160000" for v in choices):
                require(old.get(name) == new.get(name) == index.get(name), "gitlink_index_changed:" + name)
                continue
            require(self.worktree_entry(row, name) in choices, "worktree_edit_preserved:" + name)
        self.git(row["path"], "restore", "--source=" + row["final"], "--staged", "--worktree", "--", ".")
        self.clean_formal(row, row["final"])
        require(self.index(row) == new, "final_index_mismatch")
        self.checkpoint(row["name"], "formal_sync")

    def install(self):
        p = self.run(["bash", str(self.package / "install-model-task-registry.sh"), "--upgrade",
                      "--payload-dir", str(self.package / "payload/aegl")])
        self.emit(p.stdout.decode().strip())
        target = Path("/usr/local/lib/aegl-model-task")
        for rel in ("bin/aegl-model-task", "recovery/model_task_registry.py"):
            require(digest(target / rel) == digest(self.package / "payload/aegl" / rel), "installed_hash_mismatch")
        self.state["installed"] = True
        self.save()

    def verify_source_payloads(self):
        row = next(r for r in self.release["repos"] if r["name"] == "aegl")
        for packaged, source in self.release.get("source_files", {}).items():
            content = self.git(row["path"], "show", row["final"] + ":" + source).stdout
            require(hashlib.sha256(content).hexdigest() == digest(self.package / packaged),
                    "payload_not_from_approved_source:" + packaged)

    def cleanup(self):
        for row in self.release["repos"]:
            candidate = self.workspace / (row["name"] + "-candidate")
            if candidate.exists():
                require(not self.rows(candidate), "cleanup_candidate_dirty")
                self.git(row["path"], "worktree", "remove", str(candidate))
            ref = "refs/aegl-delivery/%s/%s" % (self.anchor[:16], row["name"])
            found = self.git(row["path"], "show-ref", "--verify", "--quiet", ref, check=False)
            require(found.returncode in (0, 1), "temporary_ref_query_failed")
            if found.returncode == 0:
                self.git(row["path"], "update-ref", "-d", ref, row["final"])
        bundles = self.workspace / "bundles"
        for row in self.release["repos"]:
            (bundles / (row["name"] + ".bundle")).unlink(missing_ok=True)
        bundles.rmdir()
        self.workspace.rmdir()
        self.state["complete"] = True
        self.save()

    def execute(self):
        self.load()
        self.prepare_workspace()
        # Check BOTH formal trees before the first object import or broker mutation.
        for row in self.release["repos"]:
            current = self.oid(row, row["target_ref"])
            require(current in (row["base"], row["final"]), "target_ref_changed")
            if current == row["base"]:
                self.clean_formal(row, row["base"])
        for row in self.release["repos"]:
            self.stage = row["name"] + ".import"
            self.emit("STAGE=" + self.stage)
            if self.oid(row, row["target_ref"]) == row["base"]:
                self.import_objects(row)
            else:
                self.emit("IMPORT_SKIP repo=" + row["name"] + " target_already_final")
        self.verify_source_payloads()
        for row in self.release["repos"]:
            self.stage = row["name"] + ".broker"
            self.promote(row)
            self.stage = row["name"] + ".formal_sync"
            self.sync(row)
        self.stage = "install"
        self.install()
        self.stage = "cleanup"
        self.cleanup()
        self.emit("DELIVERY_RESULT=OK")


def check_root_path(path, mode=None):
    path = Path(path)
    require(not path.is_symlink(), "untrusted_symlink:" + str(path))
    st = path.stat()
    require(st.st_uid == 0 and not st.st_mode & 0o022, "untrusted_owner_mode:" + str(path))
    if mode is not None:
        require(stat.S_IMODE(st.st_mode) == mode, "unexpected_mode:" + str(path))


def check_install_prerequisites(package):
    target = Path("/usr/local/lib/aegl-model-task")
    for p in (target, target / "bin", target / "recovery"):
        check_root_path(p, 0o755)
    cli, module = target / "bin/aegl-model-task", target / "recovery/model_task_registry.py"
    check_root_path(cli, 0o755)
    check_root_path(module, 0o644)
    require(digest(cli) == digest(package / "payload/aegl/bin/aegl-model-task"), "installed_cli_not_predecessor")
    require(digest(module) in ("0b9376ef1be8cc1c26a6916c892e619d169b41dc6090818637a1b4fb35d923de",
                               digest(package / "payload/aegl/recovery/model_task_registry.py")),
            "installed_module_unknown_version")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package", type=Path, required=True)
    parser.add_argument("--package-anchor", required=True)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args(argv)
    stage = "verify"
    delivery = None
    try:
        package = args.package.resolve(strict=True)
        entries = manifest_entries(package, args.package_anchor)
        release = json.loads((package / "release.json").read_text())
        require(release.get("schema") == 1 and len(release.get("repos", [])) == 2, "release_schema")
        require(release.get("source_files") == PACKAGE_SOURCES, "release_source_files")
        require({r["name"] for r in release["repos"]} == set(PRODUCTION), "release_projects")
        for row in release["repos"]:
            path, branch, baseline = PRODUCTION[row["name"]]
            require((row["path"], row["target_ref"], row["base"]) ==
                    (path, "refs/heads/" + branch, baseline), "release_target_mismatch")
            require(HEX40.fullmatch(row["final"]), "release_oid")
            require(row["bundle"] == "bundle/" + row["name"] + ".bundle" and row["bundle"] in entries,
                    "release_bundle")
            require(row.get("gitlinks", {}) == (GITLINK if row["name"] == "stack" else {}), "gitlink_policy")
        print("VERIFY_OK files=%d anchor=%s" % (len(entries), args.package_anchor), flush=True)
        if args.verify_only:
            return 0
        require(os.geteuid() == 0, "run_in_trusted_root_terminal")
        os.umask(0o027)
        check_root_path(package, 0o700)
        for rel in entries:
            p = package / rel
            check_root_path(p)
            for parent in p.parents:
                if parent == package:
                    break
                check_root_path(parent)
        # Source payload is never run under the service identities; only checked bundles leave /root.
        for parent in (package / "payload", package / "payload/aegl"):
            check_root_path(parent, 0o700)
        stage = "host_preflight"
        check_install_prerequisites(package)
        checker = Path("/usr/local/lib/aegl-entry-bind/require-entry-binds.sh")
        check_root_path(checker)
        subprocess.run([str(checker)], check=True, timeout=30)
        subprocess.run(["systemctl", "is-active", "--quiet", "aegl-promote-broker"], check=True, timeout=15)
        broker = Path("/usr/local/lib/aegl-promote/aegl-promote-broker")
        check_root_path(broker)
        for row in release["repos"]:
            for parent in (Path(row["path"]), Path(row["path"]).parent):
                require(not parent.is_symlink(), "formal_path_symlink")
        ledger_parent = Path("/var/lib/aegl-delivery")
        ledger_parent.mkdir(mode=0o700, exist_ok=True)
        check_root_path(ledger_parent)
        # Global lock serializes different packages, not just matching anchors.
        lockpath = ledger_parent / "iap.lock"
        require(not lockpath.is_symlink(), "lock_symlink")
        if lockpath.exists():
            check_root_path(lockpath, 0o600)
        with open(lockpath, "a+") as lock:
            os.chmod(lockpath, 0o600)
            check_root_path(lockpath, 0o600)
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            ledger = ledger_parent / ("iap-" + args.package_anchor[:16])
            ledger.mkdir(mode=0o700, exist_ok=True)
            check_root_path(ledger, 0o700)
            delivery = Delivery(package, args.package_anchor, release, ledger,
                                Path("/var/tmp/aegl-iap-" + args.package_anchor[:16]))
            delivery.stage = "previous_import_guard"
            delivery.verify_previous_imports(
                FAILED_IMPORT_ANCHOR,
                ledger_parent / ("iap-" + FAILED_IMPORT_ANCHOR[:16]),
                Path("/var/tmp/aegl-iap-" + FAILED_IMPORT_ANCHOR[:16]), FAILED_IMPORT_AEGL)
            delivery.execute()
        return 0
    except (DeliveryError, OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print("STAGE_FAILED=%s reason=%s" % (delivery.stage if delivery else stage, exc), file=sys.stderr)
        print("PACKAGE_RETAINED=" + str(args.package), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
