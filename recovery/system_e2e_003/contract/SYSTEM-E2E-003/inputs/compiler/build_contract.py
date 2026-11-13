#!/usr/bin/env python3
"""Assemble implementation-contract.json (+ EXECUTOR-PROMPT.md) from a spec package.

Deterministic. Reads only the authored artifacts and the manifest; it writes no prose
of its own beyond fixing references and generating the executor prompt. A missing
required input is a hard failure — it never invents content.

Usage: python3 build_contract.py <spec-package-dir>
Exit: 0 ok, 1 input missing/invalid, 2 error.
"""

from __future__ import annotations

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from spec_lib import (
    CONTRACT_FILE,
    MANIFEST_FILE,
    PROMPT_FILE,
    find_json_block,
    load_json,
    parse_acceptance,
    parse_requirements,
    parse_tasks,
    read_text,
    spec_version,
    write_json,
)

VI_KEYS = [
    "feature_id",
    "journey_id",
    "engine",
    "acceptance_ids",
    "required_selectors",
    "cli_checks",
    "persistence_checks",
    "rotation_checks",
    "search_checks",
    "fixture_intent",
    "oracle_intent",
]


class BuildError(Exception):
    """A required input is missing or unusable."""


def _require(pkg: str, name: str) -> str:
    path = os.path.join(pkg, name)
    if not os.path.exists(path):
        raise BuildError(f"missing required input: {name}")
    return path


def build(pkg: str) -> dict:
    pc = load_json(_require(pkg, "project-context.json"))
    product = find_json_block(read_text(_require(pkg, "PRODUCT.md")))
    design = find_json_block(read_text(_require(pkg, "design.md")))
    requirements = parse_requirements(read_text(_require(pkg, "requirements.md")))
    tasks = parse_tasks(read_text(_require(pkg, "tasks.md")))
    acceptance = parse_acceptance(read_text(_require(pkg, "acceptance.md")))
    verification_intent = load_json(_require(pkg, "verification-intent.json"))
    manifest = load_json(_require(pkg, MANIFEST_FILE))

    if not requirements:
        raise BuildError("requirements.md contains no REQ-* entries")
    if not tasks:
        raise BuildError("tasks.md contains no TASK-* entries")
    if not acceptance:
        raise BuildError("acceptance.md contains no AC-* entries")

    experiment = product["experiment"]
    contract = {
        "contract_version": spec_version(),
        "contract_id": experiment["contract_id"],
        "experiment_id": experiment["experiment_id"],
        "experiment_type": experiment["experiment_type"],
        "matched_control_available": experiment["matched_control_available"],
        "project": pc["project"],
        "mode": experiment["mode"],
        "feature": product["feature"],
        "artifact_refs": [
            {
                "role": entry["role"],
                "path": entry["path"],
                "required": entry["required"],
                "source": entry["source"],
            }
            for entry in manifest["entries"]
        ],
        "artifact_hashes": {entry["path"]: entry["sha256"] for entry in manifest["entries"]},
        "scope": product["scope"],
        "non_goals": product.get("non_goals", []),
        "decisions": design.get("decisions", []),
        "assumptions": design.get("assumptions", []),
        "read_first": pc["read_first"],
        "allowed_paths": pc["allowed_paths"],
        "forbidden_paths": pc.get("forbidden_paths", []),
        "requirements": requirements,
        "acceptance_ids": [item["id"] for item in acceptance],
        "data_change": design["data_change"],
        "ui_change": design["ui_change"],
        "selector_contract": design["selector_contract"],
        "tasks": tasks,
        "verification_intent": {key: verification_intent[key] for key in VI_KEYS if key in verification_intent},
        "stop_conditions": design["stop_conditions"],
        "unresolved_questions": product.get("unresolved_questions", []),
        "readiness": {"status": "NOT_READY", "gates": {}},
    }
    return contract


def render_prompt(contract: dict) -> str:
    tasks = contract["tasks"]
    task_lines = "\n".join(
        f"  {task['id']}  {task['goal']}  (depends: {', '.join(task['depends']) or 'none'})"
        for task in tasks
    )
    allowed = "\n".join(f"  - {path}" for path in contract["allowed_paths"])
    forbidden = "\n".join(f"  - {path}" for path in contract["forbidden_paths"]) or "  - (none declared)"
    stops = "\n".join(f"  - {item}" for item in contract["stop_conditions"])
    read_first = "\n".join(f"  {i + 1}. {item['path']}" for i, item in enumerate(contract["read_first"]))
    intent = contract["verification_intent"]
    if intent.get("engine") == "cli":
        checks = "\n".join(
            "  - {step}: `{command}` — expected: {expected}; on failure: {on_failure}".format(
                step=check.get("step", "(missing step)"),
                command=check.get("command", "(missing command)"),
                expected=check.get("expected", "(missing expected result)"),
                on_failure=check.get("on_failure", "(missing failure condition)"),
            )
            for check in intent.get("cli_checks", [])
        ) or "  - (none declared; contract is invalid)"
        verify_steps = f"""1. Run every CLI check below exactly as declared, in order.
2. Record evidence only in the files and format required by the frozen contract. Put expected results, failure conditions, and supplemental reporting in the FINAL ASSISTANT RESPONSE unless the contract explicitly requires them in an artifact.
3. A zero process exit alone is NOT a PASS; the expected result must be observed in the actual output.
4. If any check fails: STOP, report the failure, and do not synthesize or repair evidence.
5. On PASS: make NO further tool call, search, read, audit, repeated verification or exploratory check. Produce the Phase C report in the FINAL ASSISTANT RESPONSE using only evidence already collected in this session, emit the compact final task result, and STOP immediately.

CLI checks:
{checks}"""
    else:
        verify_steps = f"""1. Run the targeted tests named in `tasks.md`.
2. Build the Verification Plan (engine `{intent['engine']}`, journey `{intent['journey_id']}`).
3. Run the deterministic Verification Layer exactly once.
4. On PASS: make NO further tool call, search, read, audit, repeated verification or exploratory check. Produce the Phase C report in the FINAL ASSISTANT RESPONSE using only evidence already collected in this session, emit the compact final task result, and STOP immediately.
5. On FAIL: repair only the failed contract item and re-run only the work that repair invalidated. Do not repeat unaffected PASS work."""
    return f"""# EXECUTOR PROMPT — {contract['experiment_id']}

You are the execution agent for a FROZEN Implementation Contract. Work from the contract
and the listed `read_first` files. Do not re-do reconnaissance, re-choose architecture, or
re-plan decisions this contract has already frozen.

## 0. Verify the frozen contract
- Contract: `implementation-contract.json` (contract_id `{contract['contract_id']}`, version `{contract['contract_version']}`)
- Package manifest: `manifest.json` — sha256 of every authored artifact
- Recompute the manifest hashes. If any artifact differs, emit `CONTRACT_CHANGED` and STOP
  (unless this session was explicitly launched with `--accept-contract-update`).
- Confirm `READY.json` reports `status == READY`.

## 1. Read, in this order
1. `implementation-contract.json`
2. `project-context.json` (then ONLY the `read_first` files it lists)
3. `requirements.md`, `acceptance.md`, `design.md`, `DESIGN.md`, `tasks.md`
4. `verification-intent.json`

## 2. Recon budget
- `broad repo scan = forbidden`.
- Read only these {len(contract['read_first'])} `read_first` files:
{read_first}
- Extend to a targeted search ONLY for `CONTRACT_GAP`, `CONTRACT_CONTRADICTION`, a missing
  dependency, or compile evidence that requires one extra file. Record `EXTRA_RECON_REASON`
  (file + why) for every extension.

## 3. Execute tasks in dependency order
{task_lines}

## 4. Boundaries
Allowed paths:
{allowed}
Forbidden paths:
{forbidden}
Frozen decisions (do not reopen): {', '.join(d['id'] for d in contract['decisions']) or '(none)'}.

## 5. If the contract is wrong
If a contract fact contradicts the source, a required file is missing, an assumption is
wrong, an acceptance is impossible, or a boundary is unsafe:
  STOP → emit `CONTRACT_DEVIATION` with evidence. Do NOT silently redesign.

## 6. Verify and hand off
{verify_steps}

After this session (POST-SESSION observers, not in-session steps):
- `on_session_finalize` / Auto-Finalizer are POST-SESSION observers.
- Do NOT invoke, inspect, wait for, or verify Auto-Finalizer from inside this Hermes session.
- Auto-Finalizer runs only AFTER this Hermes session exits and is NOT an in-session acceptance
  criterion.

## Stop conditions
{stops}
"""


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Compile an Android Implementation Contract")
    parser.add_argument("package")
    args = parser.parse_args(argv)

    pkg = os.path.abspath(args.package)
    if not os.path.isdir(pkg):
        print(f"ERROR: not a directory: {pkg}", file=sys.stderr)
        return 2

    try:
        contract = build(pkg)
    except (BuildError, KeyError, ValueError) as exc:
        print(f"BUILD_ERROR {exc}", file=sys.stderr)
        return 1

    write_json(os.path.join(pkg, CONTRACT_FILE), contract)
    prompt_path = os.path.join(pkg, PROMPT_FILE)
    tmp = prompt_path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(render_prompt(contract))
    os.replace(tmp, prompt_path)

    print(
        f"CONTRACT=WROTE id={contract['contract_id']} "
        f"requirements={len(contract['requirements'])} tasks={len(contract['tasks'])}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
