"""Shared core for the Specification & Design Compiler.

Standard library only. Deterministic: no LLM, no network, no inferred content.
Every entry point (hash_manifest / build_contract / validate_package) imports from here.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from typing import Any

# ---------------------------------------------------------------------------
# Package layout
# ---------------------------------------------------------------------------

# Authored artifacts: hashed into the manifest, compiled into the contract.
AUTHORED = [
    ("PRODUCT.md", "product", True, "authored"),
    ("requirements.md", "requirements", True, "authored"),
    ("design.md", "design", True, "authored"),
    ("tasks.md", "tasks", True, "authored"),
    ("DESIGN.md", "ui_design", True, "authored"),
    ("acceptance.md", "acceptance", True, "authored"),
    ("project-context.json", "project_context", True, "authored"),
    ("verification-intent.json", "verification_intent", True, "authored"),
]

# Generated artifacts: not in the manifest (they are outputs, not inputs).
GENERATED = [
    ("implementation-contract.json", "contract", "generated"),
    ("manifest.json", "manifest", "generated"),
    ("READY.json", "readiness", "generated"),
    ("EXECUTOR-PROMPT.md", "executor_prompt", "generated"),
]

CONTRACT_FILE = "implementation-contract.json"
MANIFEST_FILE = "manifest.json"
READY_FILE = "READY.json"
PROMPT_FILE = "EXECUTOR-PROMPT.md"
REPORT_FILE = "validation-report.json"

REQUIRED_SECTIONS = {
    "PRODUCT.md": ["## Product", "## Change Request", "## Scope", "## Non-Goals", "## Contract Metadata"],
    "requirements.md": ["## Requirements"],
    "design.md": [
        "## Architecture",
        "## Data Flow",
        "## File Structure Plan",
        "## Selector Contract",
        "## Contract Metadata",
    ],
    "tasks.md": ["## Tasks"],
    "DESIGN.md": [
        "## Design Source",
        "## Action Placement",
        "## State Indicators",
        "## Accessibility",
        "## Reused Visual System",
    ],
    "acceptance.md": ["## Acceptance Criteria"],
}

REQ_ID = re.compile(r"^REQ-[A-Z0-9]+-\d{3}$")
AC_ID = re.compile(r"^AC-[A-Z0-9]+-\d{3}$")
TASK_ID = re.compile(r"^TASK-\d{2}$")

REQ_HEADING = re.compile(r"^###\s+(REQ-[A-Z0-9]+-\d{3})\b[^\n]*$", re.MULTILINE)
AC_HEADING = re.compile(r"^###\s+(AC-[A-Z0-9]+-\d{3})\b[^\n]*$", re.MULTILINE)
TASK_HEADING = re.compile(r"^###\s+(TASK-\d{2})\b[^\n]*$", re.MULTILINE)

JSON_BLOCK = re.compile(r"```json\s*\n(.*?)\n```", re.DOTALL)


# ---------------------------------------------------------------------------
# IO helpers
# ---------------------------------------------------------------------------


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8") as handle:
        return handle.read()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: str) -> str:
    with open(path, "rb") as handle:
        return hashlib.sha256(handle.read()).hexdigest()


def load_json(path: str) -> Any:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path: str, obj: Any) -> None:
    text = json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as handle:
        handle.write(text)
    os.replace(tmp, path)


def rel(path: str, base: str) -> str:
    return os.path.relpath(path, base).replace(os.sep, "/")


def spec_version() -> str:
    here = os.path.dirname(os.path.abspath(__file__))
    return read_text(os.path.join(here, os.pardir, "VERSION")).strip()


# ---------------------------------------------------------------------------
# Markdown parsing (strict, deterministic)
# ---------------------------------------------------------------------------


def find_json_block(text: str) -> Any:
    match = JSON_BLOCK.search(text)
    if not match:
        raise ValueError("no fenced ```json block found")
    return json.loads(match.group(1))


def _blocks(text: str, heading_re: re.Pattern[str]) -> list[tuple[str, str, str]]:
    """Return (id, title, body) for every heading match in a markdown document."""
    matches = list(heading_re.finditer(text))
    out: list[tuple[str, str, str]] = []
    for index, match in enumerate(matches):
        start = match.end()
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        title = match.group(0).split("—", 1)[-1].strip() if "—" in match.group(0) else ""
        out.append((match.group(1), title, text[start:end]))
    return out


def _fields(body: str) -> dict[str, str]:
    fields: dict[str, str] = {}
    for line in body.splitlines():
        line = line.strip()
        if line.startswith("_") and line.endswith("_:"):
            continue
        bullet = re.match(r"^-\s+([A-Za-z0-9 /]+):\s*(.*)$", line)
        if bullet:
            fields[bullet.group(1).strip().lower()] = bullet.group(2).strip()
            continue
        italic = re.match(r"^_([A-Za-z ]+):_\s*(.*)$", line)
        if italic:
            fields[italic.group(1).strip().lower()] = italic.group(2).strip()
    return fields


def _split_ids(value: str) -> list[str]:
    value = value.strip()
    if not value or value.lower() in {"none", "n/a", "-"}:
        return []
    return [item.strip().strip("`") for item in value.split(",") if item.strip()]


def parse_requirements(text: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for req_id, _title, body in _blocks(text, REQ_HEADING):
        fields = _fields(body)
        out.append(
            {
                "id": req_id,
                "statement": fields.get("statement", ""),
                "acceptance_ids": _split_ids(fields.get("acceptance", "")),
                "task_ids": _split_ids(fields.get("tasks", "")),
            }
        )
    return out


def parse_acceptance(text: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for ac_id, _title, body in _blocks(text, AC_HEADING):
        fields = _fields(body)
        out.append({"id": ac_id, "fields": fields})
    return out


def parse_tasks(text: str) -> list[dict[str, Any]]:
    out: list[dict[str, Any]] = []
    for task_id, _title, body in _blocks(text, TASK_HEADING):
        fields = _fields(body)
        out.append(
            {
                "id": task_id,
                "goal": fields.get("goal", ""),
                "boundary": fields.get("boundary", ""),
                "depends": _split_ids(fields.get("depends", "")),
                "allowed_paths": _split_ids(fields.get("allowed paths", "")),
                "acceptance_ids": _split_ids(fields.get("acceptance", "")),
                "verification": _split_ids(fields.get("verification", "")),
                "done_when": fields.get("done when", ""),
            }
        )
    return out


def missing_sections(text: str, headings: list[str]) -> list[str]:
    return [heading for heading in headings if heading not in text]


# ---------------------------------------------------------------------------
# Minimal JSON Schema (draft-07 subset) checker
# ---------------------------------------------------------------------------

_SUPPORTED = {
    "$schema",
    "$id",
    "title",
    "description",
    "type",
    "required",
    "properties",
    "additionalProperties",
    "items",
    "enum",
    "const",
    "pattern",
    "minLength",
    "maxLength",
    "minimum",
    "maximum",
    "minItems",
    "maxItems",
    "uniqueItems",
    "minProperties",
    "maxProperties",
    "$ref",
    "definitions",
    "$defs",
    "if",
    "then",
    "else",
}


class SchemaError(Exception):
    """Raised when a schema uses a keyword this minimal checker does not support."""


def _type_ok(value: Any, name: str) -> bool:
    if name == "boolean":
        return isinstance(value, bool)
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    if name == "null":
        return value is None
    if name == "string":
        return isinstance(value, str)
    if name == "array":
        return isinstance(value, list)
    if name == "object":
        return isinstance(value, dict)
    raise SchemaError(f"unsupported type: {name}")


def _resolve(root: dict[str, Any], ref: str) -> dict[str, Any]:
    if not ref.startswith("#/"):
        raise SchemaError(f"unsupported $ref: {ref}")
    node: Any = root
    for part in ref[2:].split("/"):
        part = part.replace("~1", "/").replace("~0", "~")
        node = node[part]
    return node


def schema_errors(instance: Any, schema: dict[str, Any], root: dict[str, Any] | None = None, path: str = "$") -> list[str]:
    root = schema if root is None else root
    errors: list[str] = []

    if "$ref" in schema:
        return schema_errors(instance, _resolve(root, schema["$ref"]), root, path)

    for key in schema:
        if key not in _SUPPORTED:
            raise SchemaError(f"unsupported schema keyword '{key}'")

    if "type" in schema:
        names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
        if not any(_type_ok(instance, name) for name in names):
            errors.append(f"{path}: expected type {schema['type']}, got {type(instance).__name__}")
            return errors

    if "const" in schema and instance != schema["const"]:
        errors.append(f"{path}: expected const {schema['const']!r}, got {instance!r}")

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: value {instance!r} not in enum {schema['enum']!r}")

    if "if" in schema:
        condition_errors = schema_errors(instance, schema["if"], root, path)
        branch = schema.get("else") if condition_errors else schema.get("then")
        if branch is not None:
            errors.extend(schema_errors(instance, branch, root, path))

    if isinstance(instance, str):
        if "pattern" in schema and not re.search(schema["pattern"], instance):
            errors.append(f"{path}: {instance!r} does not match pattern {schema['pattern']!r}")
        if "minLength" in schema and len(instance) < schema["minLength"]:
            errors.append(f"{path}: shorter than minLength {schema['minLength']}")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            errors.append(f"{path}: longer than maxLength {schema['maxLength']}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: below minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{path}: above maximum {schema['maximum']}")

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{path}: fewer than minItems {schema['minItems']}")
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            errors.append(f"{path}: more than maxItems {schema['maxItems']}")
        if schema.get("uniqueItems"):
            seen = [json.dumps(item, sort_keys=True) for item in instance]
            if len(seen) != len(set(seen)):
                errors.append(f"{path}: items are not unique")
        if "items" in schema:
            for index, item in enumerate(instance):
                errors.extend(schema_errors(item, schema["items"], root, f"{path}[{index}]"))

    if isinstance(instance, dict):
        if "minProperties" in schema and len(instance) < schema["minProperties"]:
            errors.append(f"{path}: fewer than minProperties {schema['minProperties']}")
        if "maxProperties" in schema and len(instance) > schema["maxProperties"]:
            errors.append(f"{path}: more than maxProperties {schema['maxProperties']}")
        for name in schema.get("required", []):
            if name not in instance:
                errors.append(f"{path}: missing required property '{name}'")
        for name, subschema in schema.get("properties", {}).items():
            if name in instance:
                errors.extend(schema_errors(instance[name], subschema, root, f"{path}.{name}"))
        extra = schema.get("additionalProperties", True)
        known = set(schema.get("properties", {}))
        for name, value in instance.items():
            if name in known:
                continue
            if extra is False:
                errors.append(f"{path}: unexpected property '{name}'")
            elif isinstance(extra, dict):
                errors.extend(schema_errors(value, extra, root, f"{path}.{name}"))

    return errors


# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------


def is_relative_within(path: str) -> bool:
    """A contract path must be project-relative: no absolute, no '..' escape."""
    if not path or os.path.isabs(path):
        return False
    parts = path.replace("\\", "/").split("/")
    return ".." not in parts


def overlaps(allowed: str, forbidden: str) -> bool:
    """True when an allowed path is equal to, inside, or a parent of a forbidden path."""
    a = allowed.rstrip("/")
    f = forbidden.rstrip("/")
    return a == f or a.startswith(f + "/") or f.startswith(a + "/")
