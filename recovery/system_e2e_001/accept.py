#!/usr/bin/env python3
"""Independent, read-only host acceptance for SYSTEM-E2E-001.

Reads the trusted registry entry, the root-owned prepared contract package, the
root-authored input pin and the executor's worktree. Recomputes every hash it can and
re-reads every generated artifact; a model statement, a zero exit code or a guard log
is never acceptance.

Usage:
    python3 -B accept.py [--task-root DIR] [--contract DIR] [--registry FILE] [--project DIR]

Exit: 0 ACCEPT=OK, 1 ACCEPT=FAIL (precise code on stderr).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path, PurePosixPath

TASK_ID = "SYSTEM-E2E-001"
FIXTURE_ID = "FIXTURE-B1-CONTRACT"
RESULT_KEYS = (
    "task_id",
    "fixture_id",
    "manifest_entries",
    "requirements",
    "tasks",
    "validator_status",
    "errors",
)
COPY_REL = PurePosixPath("e2e/valid_package")
RESULT_REL = PurePosixPath("RESULT.json")
PIN_FILE = "INPUTS-PIN.json"
SHA_LINE = re.compile(r"^([0-9a-f]{64})  (.+)$")


class Fail(Exception):
    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_json(path: Path, what: str):
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise Fail("MISSING", "%s unreadable: %s (%s)" % (what, path, exc))
    try:
        return json.loads(raw)
    except json.JSONDecodeError as exc:
        raise Fail("INVALID_JSON", "%s invalid JSON: %s (%s)" % (what, path, exc))


def safe_rel(raw: str, what: str) -> PurePosixPath:
    if not isinstance(raw, str) or not raw:
        raise Fail("BAD_PATH", "%s path is not a non-empty string" % what)
    if raw.startswith("/"):
        raise Fail("BAD_PATH", "%s path is absolute: %r" % (what, raw))
    parts = PurePosixPath(raw).parts
    if not parts or any(part in (".", "..") for part in parts):
        raise Fail("BAD_PATH", "%s path is not canonical: %r" % (what, raw))
    if str(PurePosixPath(raw)) != raw:
        raise Fail("BAD_PATH", "%s path is not canonical: %r" % (what, raw))
    return PurePosixPath(raw)


def require_file(path: Path, what: str) -> None:
    if not path.is_file():
        raise Fail("MISSING", "%s missing: %s" % (what, path))


def check_manifest(copy_dir: Path) -> dict:
    manifest = read_json(copy_dir / "manifest.json", "fixture manifest")
    if not isinstance(manifest, dict):
        raise Fail("BAD_MANIFEST", "fixture manifest is not an object")
    entries = manifest.get("entries")
    if not isinstance(entries, list):
        raise Fail("BAD_MANIFEST", "fixture manifest entries is not a list")
    seen: set[str] = set()
    artifact_hashes: dict[str, str] = {}
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise Fail("BAD_MANIFEST", "manifest entry %d is not an object" % index)
        rel = safe_rel(entry.get("path"), "manifest entry %d" % index)
        digest = entry.get("sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise Fail("BAD_MANIFEST", "manifest entry %s has an invalid sha256" % rel)
        if str(rel) in seen:
            raise Fail("BAD_MANIFEST", "duplicate manifest path: %s" % rel)
        seen.add(str(rel))
        target = copy_dir / rel
        require_file(target, "manifest member %s" % rel)
        actual = sha256_file(target)
        if actual != digest:
            raise Fail("MANIFEST_HASH", "manifest member %s sha256 %s != %s" % (rel, actual, digest))
        artifact_hashes[str(rel)] = digest
    return {"count": len(entries), "hashes": artifact_hashes}


def check_contract(copy_dir: Path, accepted: dict) -> dict:
    contract = read_json(copy_dir / "implementation-contract.json", "fixture contract")
    if not isinstance(contract, dict):
        raise Fail("BAD_CONTRACT", "implementation contract is not an object")
    requirements = contract.get("requirements")
    tasks = contract.get("tasks")
    if not isinstance(requirements, list) or not isinstance(tasks, list):
        raise Fail("BAD_CONTRACT", "requirements/tasks are not lists")
    contract_id = contract.get("contract_id")
    if contract_id != FIXTURE_ID:
        raise Fail("FIXTURE_ID", "contract_id %r != %r" % (contract_id, FIXTURE_ID))
    artifact_hashes = contract.get("artifact_hashes")
    if not isinstance(artifact_hashes, dict):
        raise Fail("BAD_CONTRACT", "artifact_hashes is not an object")
    for path, digest in accepted["hashes"].items():
        if artifact_hashes.get(path) != digest:
            raise Fail("CONTRACT_HASHES", "artifact_hashes mismatch for %s" % path)
    return {
        "contract_id": contract_id,
        "requirements": len(requirements),
        "tasks": len(tasks),
    }


def check_report(copy_dir: Path) -> dict:
    report = read_json(copy_dir / "validation-report.json", "validation report")
    if not isinstance(report, dict):
        raise Fail("BAD_REPORT", "validation report is not an object")
    status = report.get("status")
    errors = report.get("errors")
    if not isinstance(errors, list):
        raise Fail("BAD_REPORT", "validation report errors is not a list")
    if status != "READY":
        raise Fail("NOT_READY", "validator status is %r" % (status,))
    if errors:
        raise Fail("VALIDATOR_ERRORS", "validator reported %d error(s)" % len(errors))
    gates = report.get("gates")
    if not isinstance(gates, dict) or not gates:
        raise Fail("BAD_REPORT", "validation report gates is missing")
    for gate, value in gates.items():
        if value != "PASS":
            raise Fail("GATE_FAIL", "gate %s is %r" % (gate, value))
    for field, target in (("manifest_sha256", "manifest.json"),
                          ("contract_sha256", "implementation-contract.json")):
        recorded = report.get(field)
        actual = sha256_file(copy_dir / target)
        if recorded != actual:
            raise Fail("REPORT_HASH", "%s %r != %s" % (field, recorded, actual))
    return {"status": status, "errors": len(errors), "gates": sorted(gates)}


def check_ready(copy_dir: Path) -> str:
    ready = read_json(copy_dir / "READY.json", "readiness")
    if not isinstance(ready, dict) or ready.get("status") != "READY":
        raise Fail("READY_NOT_READY", "READY.json does not report READY")
    return ready["status"]


def check_result(path: Path, actual: dict) -> dict:
    value = read_json(path, "RESULT.json")
    if not isinstance(value, dict):
        raise Fail("RESULT_NOT_OBJECT", "RESULT.json is not an object")
    keys = set(value)
    missing = [key for key in RESULT_KEYS if key not in keys]
    extra = sorted(keys - set(RESULT_KEYS))
    if missing:
        raise Fail("RESULT_MISSING_FIELD", "missing keys: %s" % ", ".join(missing))
    if extra:
        raise Fail("RESULT_EXTRA_FIELD", "unexpected keys: %s" % ", ".join(extra))

    def expect_type(name, kind):
        item = value[name]
        if kind is int:
            if isinstance(item, bool) or not isinstance(item, int):
                raise Fail("RESULT_TYPE", "%s must be an integer" % name)
        elif not isinstance(item, str):
            raise Fail("RESULT_TYPE", "%s must be a string" % name)
        return item

    if expect_type("task_id", str) != TASK_ID:
        raise Fail("RESULT_TASK_ID", "task_id is not %s" % TASK_ID)
    if expect_type("fixture_id", str) != actual["fixture_id"]:
        raise Fail("RESULT_FIXTURE_ID", "fixture_id does not match the generated contract")
    for name, kind in (("manifest_entries", int), ("requirements", int),
                       ("tasks", int), ("validator_status", str), ("errors", int)):
        expect_type(name, kind)
    expected = {
        "task_id": TASK_ID,
        "fixture_id": actual["fixture_id"],
        "manifest_entries": actual["manifest_entries"],
        "requirements": actual["requirements"],
        "tasks": actual["tasks"],
        "validator_status": actual["validator_status"],
        "errors": actual["errors"],
    }
    for name, wanted in expected.items():
        if value[name] != wanted:
            raise Fail("RESULT_MISMATCH", "%s is %r, actual artifacts give %r"
                       % (name, value[name], wanted))
    return value


def check_pinned_inputs(contract_dir: Path) -> int:
    pin_path = contract_dir / "inputs" / "INPUTS.sha256"
    try:
        lines = pin_path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise Fail("MISSING", "input pin unreadable: %s (%s)" % (pin_path, exc))
    count = 0
    seen: set[str] = set()
    for line in lines:
        match = SHA_LINE.fullmatch(line)
        if not match:
            raise Fail("BAD_PIN", "invalid input pin line: %r" % line)
        digest, rel = match.groups()
        safe_rel(rel, "input pin")
        if rel in seen:
            raise Fail("BAD_PIN", "duplicate input pin path: %s" % rel)
        seen.add(rel)
        target = contract_dir / "inputs" / rel
        require_file(target, "declared input %s" % rel)
        actual = sha256_file(target)
        if actual != digest:
            raise Fail("INPUT_HASH", "%s sha256 %s != %s" % (rel, actual, digest))
        count += 1
    if count == 0:
        raise Fail("BAD_PIN", "input pin is empty")
    return count


def check_fixture_inputs_unchanged(contract_dir: Path, copy_dir: Path) -> int:
    pin_path = contract_dir / "inputs" / "INPUTS.sha256"
    checked = 0
    for line in pin_path.read_text(encoding="utf-8").splitlines():
        digest, rel = SHA_LINE.fullmatch(line).groups()
        if not rel.startswith("fixture/"):
            continue
        copy_rel = PurePosixPath(rel[len("fixture/"):])
        target = copy_dir / copy_rel
        require_file(target, "fixture copy member %s" % copy_rel)
        actual = sha256_file(target)
        if actual != digest:
            raise Fail("FIXTURE_CHANGED", "fixture member %s sha256 %s != %s"
                       % (copy_rel, actual, digest))
        checked += 1
    return checked


def check_outer_package(contract_dir: Path, expected_manifest_sha: str) -> dict:
    manifest_path = contract_dir / "manifest.json"
    require_file(manifest_path, "contract manifest")
    actual = sha256_file(manifest_path)
    if actual != expected_manifest_sha:
        raise Fail("PACKAGE_HASH", "contract manifest sha256 %s != %s"
                   % (actual, expected_manifest_sha))
    manifest = read_json(manifest_path, "contract manifest")
    entries = manifest.get("entries") if isinstance(manifest, dict) else None
    if not isinstance(entries, list):
        raise Fail("BAD_PACKAGE", "contract manifest entries is not a list")
    for entry in entries:
        if not isinstance(entry, dict):
            raise Fail("BAD_PACKAGE", "contract manifest entry is not an object")
        rel = safe_rel(entry.get("path"), "contract manifest")
        digest = entry.get("sha256")
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise Fail("BAD_PACKAGE", "contract manifest sha256 invalid for %s" % rel)
        target = contract_dir / rel
        require_file(target, "contract member %s" % rel)
        if sha256_file(target) != digest:
            raise Fail("PACKAGE_MEMBER", "contract member %s hash mismatch" % rel)
    return {"manifest_sha256": actual, "members": len(entries)}


def check_registry(registry_path: Path, expected: dict) -> dict:
    registry = read_json(registry_path, "task registry")
    if not isinstance(registry, dict):
        raise Fail("BAD_REGISTRY", "registry is not an object")
    entry = registry.get(TASK_ID)
    if not isinstance(entry, dict):
        raise Fail("NOT_REGISTERED", "%s is not registered" % TASK_ID)
    if set(entry) != {"worktree", "scratch", "project", "contract_package"}:
        raise Fail("REGISTRY_FIELDS", "registry entry fields differ: %s" % sorted(entry))
    for field, wanted in expected.items():
        got = entry.get(field)
        if not isinstance(got, str) or os.path.realpath(got) != os.path.realpath(wanted):
            raise Fail("REGISTRY_MISMATCH", "%s %r != %r" % (field, got, wanted))
    return entry


def _git(cwd: Path, *args: str, trusted: tuple[Path, ...] = ()) -> str:
    argv = ["git"]
    for path in trusted:
        argv += ["-c", "safe.directory=%s" % os.path.realpath(path)]
    argv += ["-C", str(cwd), *args]
    proc = subprocess.run(argv, capture_output=True, text=True, timeout=30)
    if proc.returncode != 0:
        raise Fail("GIT", "git %s failed: %s" % (" ".join(args), (proc.stderr or "").strip()[:300]))
    return proc.stdout.strip()


def check_worktree_binding(worktree: Path, project: Path, base_commit: str) -> dict:
    if not worktree.is_dir():
        raise Fail("MISSING", "worktree missing: %s" % worktree)
    trusted = (worktree, project)
    toplevel = _git(worktree, "rev-parse", "--show-toplevel", trusted=trusted)
    if os.path.realpath(toplevel) != os.path.realpath(worktree):
        raise Fail("WORKTREE_TOPLEVEL", "worktree is not its own git toplevel")
    common = _git(worktree, "rev-parse", "--git-common-dir", trusted=trusted)
    common_path = Path(common) if os.path.isabs(common) else worktree / common
    if os.path.realpath(common_path) != os.path.realpath(project / ".git"):
        raise Fail("WORKTREE_REPO", "worktree does not belong to the declared project")
    head = _git(worktree, "rev-parse", "HEAD", trusted=trusted)
    if head != base_commit:
        raise Fail("WORKTREE_HEAD", "HEAD %s != %s" % (head, base_commit))
    return {"head": head}


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="SYSTEM-E2E-001 independent host acceptance")
    parser.add_argument("--task-root", default="/var/tmp/%s" % TASK_ID)
    parser.add_argument("--contract",
                        default="/var/lib/aegl-model/trusted/ImageAnalysisFactory/reports/contracts/%s" % TASK_ID)
    parser.add_argument("--registry", default="/var/lib/aegl-model/registry.json")
    parser.add_argument("--project", default="/home/zhong/AndroidStudioProjects/ImageAnalysisFactory")
    args = parser.parse_args(argv)

    task_root = Path(args.task_root)
    contract_dir = Path(args.contract)
    project = Path(args.project)
    try:
        pin = read_json(task_root / PIN_FILE, "input pin")
        if not isinstance(pin, dict):
            raise Fail("BAD_PIN", "input pin is not an object")
        if pin.get("task_id") != TASK_ID:
            raise Fail("PIN_TASK", "input pin task_id is not %s" % TASK_ID)
        base_commit = pin.get("iap_base_commit")
        if not isinstance(base_commit, str) or not re.fullmatch(r"[0-9a-f]{40}", base_commit):
            raise Fail("BAD_PIN", "iap_base_commit is not a 40-hex commit")
        worktree = Path(pin.get("worktree") or "")
        scratch = Path(pin.get("scratch") or "")
        if pin.get("contract_package") != args.contract:
            raise Fail("PIN_CONTRACT", "input pin contract path does not match --contract")

        check_registry(Path(args.registry), {
            "worktree": str(worktree),
            "scratch": str(scratch),
            "project": str(project),
            "contract_package": str(contract_dir),
        })
        package = check_outer_package(contract_dir, pin.get("contract_manifest_sha256"))
        inputs = check_pinned_inputs(contract_dir)
        binding = check_worktree_binding(worktree, project, base_commit)

        copy_dir = worktree / COPY_REL
        manifest = check_manifest(copy_dir)
        contract = check_contract(copy_dir, manifest)
        report = check_report(copy_dir)
        ready = check_ready(copy_dir)
        unchanged = check_fixture_inputs_unchanged(contract_dir, copy_dir)
        actual = {
            "fixture_id": contract["contract_id"],
            "manifest_entries": manifest["count"],
            "requirements": contract["requirements"],
            "tasks": contract["tasks"],
            "validator_status": report["status"],
            "errors": report["errors"],
        }
        result = check_result(worktree / RESULT_REL, actual)
        if ready != report["status"]:
            raise Fail("READY_MISMATCH", "READY.json and validation-report.json differ")
        if pin.get("inputs_sha256") != _sha_of(contract_dir / "inputs" / "INPUTS.sha256"):
            raise Fail("PIN_INPUTS", "input pin inputs_sha256 does not match the package")
        print(json.dumps({
            "decision": "ACCEPT=OK",
            "task_id": TASK_ID,
            "result": result,
            "package_manifest_sha256": package["manifest_sha256"],
            "package_members": package["members"],
            "declared_inputs": inputs,
            "fixture_files_unchanged": unchanged,
            "worktree_head": binding["head"],
            "gates": report["gates"],
        }, sort_keys=True))
        return 0
    except Fail as exc:
        print("ACCEPT=FAIL code=%s: %s" % (exc.code, exc.detail), file=sys.stderr)
        return 1


def _sha_of(path: Path) -> str:
    return sha256_file(path) if path.is_file() else ""


if __name__ == "__main__":
    raise SystemExit(main())
