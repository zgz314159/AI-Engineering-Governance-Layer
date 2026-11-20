#!/usr/bin/env python3
"""Deterministic validation of a spec package against every READY gate.

No LLM, no network, no guessed content. Writes validation-report.json always, and
READY.json ONLY when all gates PASS. Stable rule ids make failures attributable.

Usage:
  python3 validate_package.py <spec-package-dir> [--project-root DIR]
Exit: 0 READY, 1 NOT READY, 2 error.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from spec_lib import (
    AUTHORED,
    CONTRACT_FILE,
    MANIFEST_FILE,
    READY_FILE,
    REPORT_FILE,
    REQUIRED_SECTIONS,
    is_relative_within,
    load_json,
    missing_sections,
    overlaps,
    parse_acceptance,
    parse_requirements,
    parse_tasks,
    read_text,
    schema_errors,
    sha256_file,
    write_json,
)

SCHEMA_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir, "contracts")
GATES = ["schema", "traceability", "boundaries", "acceptance", "hashes"]


def _try_json(pkg: str, name: str):
    path = os.path.join(pkg, name)
    if not os.path.exists(path):
        return None
    try:
        return load_json(path)
    except (ValueError, OSError):
        return None


def _duplicates(ids: list[str]) -> list[str]:
    seen: set[str] = set()
    dups: list[str] = []
    for item in ids:
        if item in seen:
            dups.append(item)
        seen.add(item)
    return dups


def validate(pkg: str, project_root: str | None = None) -> dict:
    gates = {gate: "PASS" for gate in GATES}
    errors: list[dict] = []

    def fail(rule_id: str, gate: str, where: str, message: str) -> None:
        gates[gate] = "FAIL"
        errors.append({"rule_id": rule_id, "gate": gate, "where": where, "message": message})

    # --- required artifacts -------------------------------------------------
    for name, _role, required, _source in AUTHORED:
        if required and not os.path.exists(os.path.join(pkg, name)):
            fail("E_ARTIFACT_MISSING", "schema", name, "required authored artifact missing")
    for name in (CONTRACT_FILE, MANIFEST_FILE):
        if not os.path.exists(os.path.join(pkg, name)):
            fail("E_ARTIFACT_MISSING", "schema", name, "required generated artifact missing")

    contract = _try_json(pkg, CONTRACT_FILE)
    manifest = _try_json(pkg, MANIFEST_FILE)
    project_context = _try_json(pkg, "project-context.json")

    # --- schema gate --------------------------------------------------------
    try:
        contract_schema = load_json(os.path.join(SCHEMA_DIR, "android-implementation-contract.schema.json"))
        manifest_schema = load_json(os.path.join(SCHEMA_DIR, "package-manifest.schema.json"))
        ready_schema = load_json(os.path.join(SCHEMA_DIR, "readiness.schema.json"))
    except OSError as exc:
        print(f"ERROR: schemas unavailable: {exc}", file=sys.stderr)
        raise SystemExit(2)

    if contract is not None:
        for err in schema_errors(contract, contract_schema):
            fail("E_SCHEMA_INVALID", "schema", CONTRACT_FILE, err)
    if manifest is not None:
        for err in schema_errors(manifest, manifest_schema):
            fail("E_SCHEMA_INVALID", "schema", MANIFEST_FILE, err)
    ready_path = os.path.join(pkg, READY_FILE)
    if os.path.exists(ready_path):
        for err in schema_errors(_try_json(pkg, READY_FILE), ready_schema):
            fail("E_SCHEMA_INVALID", "schema", READY_FILE, err)

    for name, headings in REQUIRED_SECTIONS.items():
        full = os.path.join(pkg, name)
        if not os.path.exists(full):
            continue
        for miss in missing_sections(read_text(full), headings):
            fail("E_SECTION_MISSING", "schema", name, f"missing section: {miss}")

    if contract is not None:
        for ref in contract.get("artifact_refs", []):
            if not os.path.exists(os.path.join(pkg, ref["path"])):
                fail("E_CONTRACT_REF_MISSING", "schema", ref["path"], "artifact_ref path does not exist")

        intent = contract.get("verification_intent", {})
        engine = intent.get("engine")
        if engine == "cli":
            checks = intent.get("cli_checks")
            if not isinstance(checks, list) or not checks:
                fail("E_CLI_CHECKS_MISSING", "schema", "verification_intent.cli_checks",
                     "cli engine requires at least one concrete check")
            else:
                for index, check in enumerate(checks):
                    if not isinstance(check, dict):
                        fail("E_CLI_CHECK_INCOMPLETE", "schema",
                             f"verification_intent.cli_checks[{index}]", "cli check must be an object")
                        continue
                    for field in ("step", "command", "expected", "on_failure"):
                        value = check.get(field)
                        if not isinstance(value, str) or not value.strip():
                            fail("E_CLI_CHECK_INCOMPLETE", "schema",
                                 f"verification_intent.cli_checks[{index}].{field}",
                                 f"cli check requires a non-empty {field}")
        elif engine in ("uiautomator", "maestro"):
            if not contract.get("selector_contract"):
                fail("E_UI_SELECTOR_REQUIRED", "schema", "selector_contract",
                     "uiautomator/maestro engine requires a non-empty selector_contract")
            if not intent.get("required_selectors"):
                fail("E_UI_SELECTOR_REQUIRED", "schema", "verification_intent.required_selectors",
                     "uiautomator/maestro engine requires at least one required selector")
        else:
            fail("E_UNKNOWN_ENGINE", "schema", "verification_intent.engine",
                 f"unknown verification engine {engine!r}")

    # --- parse markdown -----------------------------------------------------
    reqs = parse_requirements(read_text(os.path.join(pkg, "requirements.md"))) if os.path.exists(os.path.join(pkg, "requirements.md")) else []
    tasks_md = parse_tasks(read_text(os.path.join(pkg, "tasks.md"))) if os.path.exists(os.path.join(pkg, "tasks.md")) else []
    acs_md = parse_acceptance(read_text(os.path.join(pkg, "acceptance.md"))) if os.path.exists(os.path.join(pkg, "acceptance.md")) else []

    for dup in _duplicates([r["id"] for r in reqs]):
        fail("E_DUP_REQ_ID", "traceability", "requirements.md", f"duplicate requirement id {dup}")
    for dup in _duplicates([a["id"] for a in acs_md]):
        fail("E_DUP_AC_ID", "traceability", "acceptance.md", f"duplicate acceptance id {dup}")
    for dup in _duplicates([t["id"] for t in tasks_md]):
        fail("E_DUP_TASK_ID", "traceability", "tasks.md", f"duplicate task id {dup}")

    if contract is not None:
        contract_task_ids = {t["id"] for t in contract.get("tasks", [])}
        for task in contract.get("tasks", []):
            for dep in task.get("depends", []):
                if dep not in contract_task_ids:
                    fail("E_MISSING_DEPENDENCY", "traceability", task["id"], f"depends on unknown task {dep}")
            for task_id in task.get("acceptance_ids", []):
                if task_id not in contract.get("acceptance_ids", []):
                    fail("E_AC_UNDEFINED", "acceptance", task["id"], f"references undefined acceptance {task_id}")
        for question in contract.get("unresolved_questions", []):
            fail("E_UNRESOLVED_QUESTIONS", "traceability", question.get("id", "?"), "unresolved question blocks READY")
        mapped: set[str] = set()
        for req in contract.get("requirements", []):
            mapped.update(req.get("acceptance_ids", []))
        mapped.update(contract.get("verification_intent", {}).get("acceptance_ids", []))
        for ac in contract.get("acceptance_ids", []):
            if ac not in mapped:
                fail("E_ORPHAN_ACCEPTANCE", "traceability", ac, "acceptance referenced by no requirement or verification intent")

    # --- boundaries gate ----------------------------------------------------
    if contract is not None:
        for task in contract.get("tasks", []):
            if not str(task.get("boundary", "")).strip():
                fail("E_MISSING_BOUNDARY", "boundaries", task["id"], "task has no boundary")
            if not task.get("allowed_paths"):
                fail("E_MISSING_ALLOWED_PATHS", "boundaries", task["id"], "task has no allowed paths")
        for allowed in contract.get("allowed_paths", []):
            for forbidden in contract.get("forbidden_paths", []):
                if overlaps(allowed, forbidden):
                    fail("E_PATH_CONFLICT", "boundaries", allowed, f"allowed path overlaps forbidden path {forbidden}")
        for path in list(contract.get("allowed_paths", [])) + list(contract.get("forbidden_paths", [])):
            if not is_relative_within(path):
                fail("E_PROJECT_ESCAPE", "boundaries", path, "path is not project-relative or escapes with '..'")

        root = project_root or (project_context or {}).get("source_root")
        for item in contract.get("read_first", []):
            path = item["path"]
            full = path if os.path.isabs(path) else os.path.join(root or pkg, path)
            if not os.path.exists(full):
                fail("E_READ_FIRST_MISSING", "boundaries", path, f"read_first file not found under {root or pkg}")

        selector_names = {sel["name"] for sel in contract.get("selector_contract", [])}
        for selector in contract.get("verification_intent", {}).get("required_selectors", []):
            if selector not in selector_names:
                fail("E_MISSING_SELECTOR", "boundaries", selector, "required selector is not declared in selector_contract")

    # --- acceptance gate ----------------------------------------------------
    if contract is not None:
        ac_ids_md = {a["id"] for a in acs_md}
        for ac in contract.get("acceptance_ids", []):
            if ac not in ac_ids_md:
                fail("E_AC_UNDEFINED", "acceptance", ac, "acceptance id not defined in acceptance.md")
        for req in contract.get("requirements", []):
            if not req.get("acceptance_ids"):
                fail("E_REQ_NO_ACCEPTANCE", "acceptance", req["id"], "requirement has no acceptance criterion")
        task_ac: set[str] = set()
        for task in contract.get("tasks", []):
            task_ac.update(task.get("acceptance_ids", []))
        vi_ac = set(contract.get("verification_intent", {}).get("acceptance_ids", []))
        for ac in contract.get("acceptance_ids", []):
            if ac not in task_ac and ac not in vi_ac:
                fail("E_AC_UNMAPPED", "acceptance", ac, "acceptance mapped to no task and not covered by verification intent")

    # --- hashes gate --------------------------------------------------------
    if manifest is not None:
        by_path = {entry["path"]: entry for entry in manifest.get("entries", [])}
        for name, _role, _required, _source in AUTHORED:
            full = os.path.join(pkg, name)
            if not os.path.exists(full):
                continue
            entry = by_path.get(name)
            if entry is None:
                fail("E_MANIFEST_INCONSISTENT", "hashes", name, "authored artifact absent from manifest")
            elif sha256_file(full) != entry["sha256"]:
                fail("E_HASH_MISMATCH", "hashes", name, "file sha256 does not match manifest")
        if contract is not None:
            manifest_hashes = {entry["path"]: entry["sha256"] for entry in manifest.get("entries", [])}
            if contract.get("artifact_hashes") != manifest_hashes:
                fail("E_MANIFEST_INCONSISTENT", "hashes", CONTRACT_FILE, "contract artifact_hashes differ from manifest")

    # --- traceability matrix + status --------------------------------------
    ac_fields = {a["id"]: a["fields"] for a in acs_md}
    matrix = []
    for req in (contract or {}).get("requirements", []):
        matrix.append(
            {
                "requirement": req["id"],
                "acceptance_ids": req.get("acceptance_ids", []),
                "task_ids": req.get("task_ids", []),
                "pc1_steps": [ac_fields.get(ac, {}).get("pc1 step", "") for ac in req.get("acceptance_ids", [])],
            }
        )

    status = "READY" if all(value == "PASS" for value in gates.values()) else "NOT_READY"
    if contract is None:
        status = "NOT_READY"

    if contract is not None:
        contract["readiness"] = {"status": status, "gates": gates}
        write_json(os.path.join(pkg, CONTRACT_FILE), contract)

    report = {
        "status": status,
        "gates": gates,
        "errors": errors,
        "traceability": matrix,
        "contract_sha256": sha256_file(os.path.join(pkg, CONTRACT_FILE)) if contract is not None else None,
        "manifest_sha256": sha256_file(os.path.join(pkg, MANIFEST_FILE)) if manifest is not None else None,
    }
    write_json(os.path.join(pkg, REPORT_FILE), report)

    if status == "READY" and contract is not None:
        write_json(
            os.path.join(pkg, READY_FILE),
            {
                "contract_version": contract["contract_version"],
                "contract_id": contract["contract_id"],
                "experiment_id": contract["experiment_id"],
                "status": "READY",
                "unresolved_questions": [q["question"] for q in contract.get("unresolved_questions", [])],
                "validation": gates,
            },
        )
    elif os.path.exists(ready_path):
        os.remove(ready_path)

    return report


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Validate a spec package")
    parser.add_argument("package")
    parser.add_argument("--project-root", default=None)
    args = parser.parse_args(argv)

    pkg = os.path.abspath(args.package)
    if not os.path.isdir(pkg):
        print(f"ERROR: not a directory: {pkg}", file=sys.stderr)
        return 2

    report = validate(pkg, args.project_root)
    for error in report["errors"]:
        print(f"{error['rule_id']} [{error['gate']}] {error['where']}: {error['message']}", file=sys.stderr)
    summary = " ".join(f"{gate}={value}" for gate, value in report["gates"].items())
    print(f"STATUS={report['status']} {summary} errors={len(report['errors'])}")
    return 0 if report["status"] == "READY" else 1


if __name__ == "__main__":
    raise SystemExit(main())
