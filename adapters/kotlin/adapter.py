"""AEGL Kotlin (Gradle) adapter.

Non-invasive by design: `attach` writes an AEGL overlay under `<project>/.aegl/`
plus a CI bridge, and injects detekt + Konsist at run time via
`gradle --init-script`. It never edits the target's own build files.

All library functions take an absolute project `Path`.
"""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
from pathlib import Path


def _aegl_version() -> str:
    """Single source of truth for the AEGL version: the top-level VERSION file."""
    try:
        return (Path(__file__).resolve().parents[2] / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        return "0.0.0"


AEGL_VERSION = _aegl_version()
LANGUAGE = "kotlin"
DETEKT_VERSION = "1.23.8"
KONSIST_VERSION = "0.17.3"
JUNIT_VERSION = "5.11.4"

LAYER_ORDER = ["Presentation", "Data", "Application", "Domain", "Infrastructure"]
LAYER_DIR = {
    "Presentation": "presentation",
    "Data": "data",
    "Application": "application",
    "Domain": "domain",
    "Infrastructure": "infrastructure",
}
# Layer -> layers it may depend on (everything else is a violation).
LAYER_MAY_DEPEND_ON = {
    "Presentation": ["Domain"],
    "Data": ["Domain"],
    "Application": ["Domain"],
    "Domain": [],
    "Infrastructure": ["Domain"],
}


def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_path(p: Path) -> str:
    return _sha256_bytes(p.read_bytes())


def _read(p: Path) -> str:
    return p.read_text(encoding="utf-8")


def detect(project: Path) -> dict:
    project = project.resolve()
    indicators: dict[str, bool] = {}
    settings = [n for n in ("settings.gradle.kts", "settings.gradle") if (project / n).exists()]
    builds = [n for n in ("build.gradle.kts", "build.gradle") if (project / n).exists()]
    indicators["settingsGradle"] = bool(settings)
    indicators["buildGradle"] = bool(builds)
    indicators["gradleWrapper"] = (project / "gradlew").exists()
    indicators["kotlinSources"] = (project / "src/main/kotlin").is_dir()

    text = ""
    for n in settings + builds:
        try:
            text += _read(project / n)
        except OSError:
            pass
    indicators["kotlinPlugin"] = bool(re.search(r"org\.jetbrains\.kotlin|kotlin\(", text))
    indicators["androidPlugin"] = "com.android" in text
    indicators["existingDetekt"] = "detekt" in text.lower()
    indicators["existingKonsist"] = "konsist" in text.lower()
    indicators["existingCI"] = (project / ".github/workflows").is_dir()
    indicators["existingClaude"] = (project / "CLAUDE.md").exists()
    indicators["existingAgents"] = (project / "AGENTS.md").exists()
    indicators["existingArchitectureTests"] = any(
        re.search(r"Architecture.*Test|GeneratedArchitectureTest", p.name)
        for p in (project / "src/test").rglob("*.kt")
    ) if (project / "src/test").is_dir() else False

    # Android projects are handled by the android adapter; never claim them here.
    matched = (indicators["settingsGradle"] and indicators["buildGradle"]
               and indicators["kotlinPlugin"] and not indicators["androidPlugin"])
    return {
        "language": LANGUAGE,
        "adapterVersion": AEGL_VERSION,
        "matched": matched,
        "indicators": indicators,
    }


def package_prefix(project: Path) -> str:
    """Best-effort base package (e.g. com.example.target) from main sources."""
    pkgs: list[str] = []
    root = project / "src/main/kotlin"
    if root.is_dir():
        for kt in root.rglob("*.kt"):
            try:
                for line in _read(kt).splitlines():
                    m = re.match(r"\s*package\s+([\w.]+)\s*$", line)
                    if m:
                        pkgs.append(m.group(1))
                        break
            except OSError:
                pass
    if not pkgs:
        return "com.example"
    stripped = []
    for p in pkgs:
        segs = p.split(".")
        if segs and segs[-1] in LAYER_DIR.values():
            segs = segs[:-1]
        stripped.append(segs)
    common = stripped[0]
    for segs in stripped[1:]:
        i = 0
        while i < len(common) and i < len(segs) and common[i] == segs[i]:
            i += 1
        common = common[:i]
    return ".".join(common) if common else "com.example"


def existing_layers(project: Path, prefix: str) -> list[str]:
    base = project / "src/main/kotlin" / Path(*prefix.split("."))
    found = []
    for layer in LAYER_ORDER:
        if (base / LAYER_DIR[layer]).is_dir():
            found.append(layer)
    return found


# --------------------------------------------------------------------------- #
# Generated file templates
# --------------------------------------------------------------------------- #

def _policy(project: Path, prefix: str, layers: list[str]) -> str:
    return json.dumps({
        "projectName": project.name,
        "policyVersion": "1.0.0",
        "packagePrefix": prefix,
        "principles": [
            "Specifications and architecture rules are authoritative before implementation.",
            "AI agents MUST NOT silently change architecture to make implementation easier.",
            "A task is complete only after deterministic quality gates pass.",
        ],
        "layers": [
            {
                "name": layer,
                "package": f"{prefix}.{LAYER_DIR[layer]}..",
                "mayDependOn": LAYER_MAY_DEPEND_ON[layer],
            }
            for layer in layers
        ],
        "qualityGates": [
            "Konsist architecture tests pass",
            "Detekt reports zero issues",
            "JUnit tests pass",
            "AEGL quality gate passes",
        ],
    }, indent=2) + "\n"


def _constitution(project: Path, prefix: str, layers: list[str]) -> str:
    lines = []
    for layer in layers:
        deps = LAYER_MAY_DEPEND_ON[layer]
        dep_txt = "nothing" if not deps else ", ".join(deps)
        lines.append(f"- **{layer}** (`{prefix}.{LAYER_DIR[layer]}..`) may depend on: **{dep_txt}**.")
    return f"""# Project Constitution

Project: {project.name}
Governed by: AEGL (AI Engineering Governance Layer) {AEGL_VERSION}

## Engineering Principles
- Specifications and architecture rules are authoritative before implementation.
- AI agents MUST NOT silently change architecture to make implementation easier.
- A task is complete only after deterministic quality gates pass.

> GENERATED by AEGL `attach`. Do not edit directly; edit `.aegl/policy.json`.
"""


def _architecture_constitution(project: Path, prefix: str, layers: list[str]) -> str:
    lines = []
    for layer in layers:
        deps = LAYER_MAY_DEPEND_ON[layer]
        dep_txt = "nothing" if not deps else ", ".join(deps)
        lines.append(f"- **{layer}** (`{prefix}.{LAYER_DIR[layer]}..`) may depend on: **{dep_txt}**.")
    return f"""# Architecture Constitution

## Layer Boundaries
{chr(10).join(lines)}

## Blocking Violations
- A layer depending on a layer not listed above is a blocking violation.
- Domain is independent and MUST NOT depend on presentation, data, application or infrastructure.
- AI agents MUST NOT weaken these boundaries merely to make an implementation easier.

> GENERATED by AEGL `attach` from `.aegl/policy.json`. Do not edit directly.
"""


DETEKT_YML = """build:
  maxIssues: 0

config:
  validation: true
  warningsAsErrors: true

complexity:
  LongMethod:
    active: true
    threshold: 60
  LargeClass:
    active: true
    threshold: 600

style:
  MagicNumber:
    active: true
    ignoreNumbers:
      - '-1'
      - '0'
      - '1'
      - '2'
    ignoreConstantDeclaration: true
    ignoreCompanionObjectPropertyDeclaration: true
    ignoreAnnotation: true
    ignoreNamedArgument: true
    ignoreEnums: true

exceptions:
  SwallowedException:
    active: true
  TooGenericExceptionCaught:
    active: true
"""


def _generated_test(prefix: str, layers: list[str]) -> str:
    decls = "\n".join(
        f'            val {layer[0].lower() + layer[1:]} = Layer("{layer}", "{prefix}.{LAYER_DIR[layer]}..")'
        for layer in layers
    )
    calls = []
    for layer in layers:
        v = layer[0].lower() + layer[1:]
        deps = LAYER_MAY_DEPEND_ON[layer]
        if not deps:
            calls.append(f"            {v}.dependsOnNothing()")
        else:
            dep_vars = ", ".join(d[0].lower() + d[1:] for d in deps if d in layers)
            if dep_vars:
                calls.append(f"            {v}.dependsOn({dep_vars})")
    return f"""package {prefix}.architecture

import com.lemonappdev.konsist.api.Konsist
import com.lemonappdev.konsist.api.architecture.KoArchitectureCreator.assertArchitecture
import com.lemonappdev.konsist.api.architecture.Layer
import org.junit.jupiter.api.Test

/**
 * GENERATED by AEGL `attach` from .aegl/policy.json.
 * Do not edit this file directly.
 */
class GeneratedArchitectureTest {{
    @Test
    fun `layer dependency policy must hold`() {{
        // Explicit source root: `scopeFromProduction()` derives source sets from
        // paths and is confused by AEGL's injected test source dir (.aegl/kotlin).
        Konsist
            .scopeFromDirectory("src/main/kotlin")
            .assertArchitecture {{
{decls}

{chr(10).join(calls)}
            }}
    }}
}}
"""


def _init_gradle() -> str:
    return f"""// AEGL Kotlin adapter — injected via `gradle --init-script`.
// Adds detekt + Konsist architecture tests WITHOUT modifying the target build files.
initscript {{
    repositories {{ mavenCentral(); gradlePluginPortal() }}
    dependencies {{
        classpath 'io.gitlab.arturbosch.detekt:detekt-gradle-plugin:{DETEKT_VERSION}'
    }}
}}

allprojects {{ p ->
    // The detekt plugin must be on the PROJECT buildscript classpath to be
    // applied by id from an init script.
    p.buildscript {{
        repositories {{ mavenCentral(); gradlePluginPortal() }}
        dependencies {{
            classpath 'io.gitlab.arturbosch.detekt:detekt-gradle-plugin:{DETEKT_VERSION}'
        }}
    }}
    p.repositories {{ mavenCentral() }}
    p.plugins.withId('org.jetbrains.kotlin.jvm') {{
        p.apply plugin: 'io.gitlab.arturbosch.detekt'
        p.dependencies {{
            testImplementation 'com.lemonappdev:konsist:{KONSIST_VERSION}'
            testImplementation 'org.junit.jupiter:junit-jupiter:{JUNIT_VERSION}'
            testRuntimeOnly 'org.junit.platform:junit-platform-launcher'
        }}
        p.sourceSets.test.kotlin.srcDir new File(p.projectDir, '.aegl/kotlin')
        p.tasks.withType(Test).configureEach {{ useJUnitPlatform() }}
        p.detekt {{
            buildUponDefaultConfig = true
            allRules = false
            config.setFrom(files(new File(p.projectDir, '.aegl/detekt.yml')))
        }}
    }}
    p.tasks.register('aeglQualityGate') {{
        group = 'verification'
        description = 'AEGL governance gate: detekt + Konsist/JUnit.'
        dependsOn 'detekt', 'test'
    }}
}}
"""


def _quality_gate_sh() -> str:
    return """#!/usr/bin/env bash
# AEGL quality gate bridge. Runs detekt + Konsist/JUnit via an init script so the
# target's own build files are never modified.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
cd "$PROJECT"
if [ ! -x ./gradlew ]; then
    echo "AEGL: no ./gradlew in $PROJECT" >&2
    exit 2
fi
exec ./gradlew --init-script "$HERE/aegl-init.gradle" aeglQualityGate "$@"
"""


def _ci_bridge() -> str:
    return """name: AEGL Governance
on:
  push:
  pull_request:
jobs:
  aegl:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v6
      - uses: actions/setup-java@v5
        with:
          distribution: temurin
          java-version: "21"
      - name: AEGL quality gate
        run: ./.aegl/quality-gate.sh
"""


def _owned_files(project: Path) -> dict[str, tuple[str, int]]:
    """relpath -> (content, mode)."""
    prefix = package_prefix(project)
    layers = existing_layers(project, prefix) or ["Domain"]
    if "Domain" not in layers:
        layers = layers + ["Domain"]
    return {
        ".aegl/policy.json": (_policy(project, prefix, layers), 0o644),
        ".aegl/governance/constitution.md": (_constitution(project, prefix, layers), 0o644),
        ".aegl/governance/architecture_constitution.md": (
            _architecture_constitution(project, prefix, layers), 0o644),
        ".aegl/detekt.yml": (DETEKT_YML, 0o644),
        ".aegl/kotlin/GeneratedArchitectureTest.kt": (_generated_test(prefix, layers), 0o644),
        ".aegl/aegl-init.gradle": (_init_gradle(), 0o644),
        ".aegl/quality-gate.sh": (_quality_gate_sh(), 0o755),
        ".github/workflows/aegl-governance.yml": (_ci_bridge(), 0o644),
    }


def _preserved(project: Path) -> list[str]:
    keep = []
    for rel in ("CLAUDE.md", "AGENTS.md", "build.gradle.kts", "build.gradle", "settings.gradle.kts", "settings.gradle"):
        if (project / rel).exists():
            keep.append(rel)
    if (project / ".github/workflows").is_dir():
        for p in sorted((project / ".github/workflows").glob("*.y*ml")):
            if p.name != "aegl-governance.yml":
                keep.append(str(p.relative_to(project)))
    return keep


def plan_attach(project: Path) -> dict:
    project = project.resolve()
    owned = _owned_files(project)
    return {
        "wouldCreate": sorted(rel for rel in owned if not (project / rel).exists()),
        "wouldModify": sorted(rel for rel in owned if (project / rel).exists()),
        "wouldPreserve": _preserved(project),
        "wouldRun": ["./.aegl/quality-gate.sh"],
    }


def attach(project: Path, dry_run: bool = False) -> dict:
    project = project.resolve()
    owned = _owned_files(project)
    if dry_run:
        return {"dryRun": True, **plan_attach(project)}

    created, modified = [], []
    for rel, (content, mode) in sorted(owned.items()):
        p = project / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        data = content.encode("utf-8")
        if p.exists():
            before = p.read_bytes()
            if before == data:
                continue
            backup = project / ".aegl/.backup" / rel
            backup.parent.mkdir(parents=True, exist_ok=True)
            backup.write_bytes(before)
            p.write_bytes(data)
            modified.append({
                "path": rel,
                "beforeSha256": _sha256_bytes(before),
                "afterSha256": _sha256_bytes(data),
                "backup": str(backup.relative_to(project)),
            })
        else:
            p.write_bytes(data)
            created.append({"path": rel, "sha256": _sha256_bytes(data)})
        p.chmod(mode)

    # Ensure the quality-gate script is executable even on filesystems that drop it.
    (project / ".aegl/quality-gate.sh").chmod(0o755)

    manifest = {
        "aeglVersion": AEGL_VERSION,
        "adapter": {"id": LANGUAGE, "version": AEGL_VERSION},
        "targetPath": str(project),
        "created": created,
        "modified": modified,
        "preserved": _preserved(project),
        "policy": ".aegl/policy.json",
        "qualityGate": ".aegl/quality-gate.sh",
    }
    manifest_path = project / ".aegl/manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    manifest["manifestPath"] = ".aegl/manifest.json"
    return manifest


def verify(project: Path) -> dict:
    project = project.resolve()
    script = project / ".aegl/quality-gate.sh"
    if not script.exists():
        return {"ok": False, "error": "not attached (.aegl/quality-gate.sh missing)"}
    proc = subprocess.run([str(script)], cwd=str(project), text=True, capture_output=True)
    out = (proc.stdout or "") + (proc.stderr or "")
    konsist = ("KoAssertionFailedException" in out) or (
        "GeneratedArchitectureTest" in out and "FAILED" in out)
    return {
        "ok": proc.returncode == 0,
        "exitCode": proc.returncode,
        "architectureViolation": konsist,
        "outputTail": "\n".join(out.strip().splitlines()[-12:]),
    }


def _prune_empty_dirs(root: Path) -> None:
    """Remove empty directories under `root`, then `root` itself if it became empty."""
    if not root.exists():
        return
    for d in sorted((p for p in root.rglob("*") if p.is_dir()), reverse=True):
        if not any(d.iterdir()):
            d.rmdir()
    if root.is_dir() and not any(root.iterdir()):
        root.rmdir()


def detach(project: Path, dry_run: bool = False) -> dict:
    project = project.resolve()
    manifest_path = project / ".aegl/manifest.json"
    if not manifest_path.exists():
        return {"error": "not attached (.aegl/manifest.json missing)", "removed": [], "skipped": []}

    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))

    # --- compute the plan WITHOUT mutating anything --------------------------
    to_delete: list[str] = []
    skipped: list[str] = []
    for entry in manifest.get("created", []):
        rel, p = entry["path"], project / entry["path"]
        if not p.exists():
            continue
        if entry.get("sha256") and _sha256_path(p) != entry["sha256"]:
            skipped.append(f"modified-since-attach:{rel}")
            continue
        to_delete.append(rel)

    to_restore: list[str] = []
    for entry in manifest.get("modified", []):
        backup, target = project / entry.get("backup", ""), project / entry["path"]
        if backup.exists():
            to_restore.append(entry["path"])
        else:
            skipped.append(f"no-backup:{entry['path']}")

    if dry_run:
        return {"dryRun": True, "removed": sorted(to_delete), "restored": sorted(to_restore),
                "skipped": sorted(skipped)}

    # --- perform -------------------------------------------------------------
    for rel in to_restore:
        entry = next(e for e in manifest["modified"] if e["path"] == rel)
        (project / rel).parent.mkdir(parents=True, exist_ok=True)
        (project / rel).write_bytes((project / entry["backup"]).read_bytes())
    for rel in to_delete:
        (project / rel).unlink()

    backup_dir = project / ".aegl/.backup"
    if backup_dir.exists():
        for f in sorted((p for p in backup_dir.rglob("*") if p.is_file()), reverse=True):
            f.unlink()
    if manifest_path.exists():
        manifest_path.unlink()  # the manifest itself is AEGL-owned
    _prune_empty_dirs(project / ".aegl")
    _prune_empty_dirs(project / ".github")

    return {"removed": sorted(to_delete + [".aegl/manifest.json"]),
            "restored": sorted(to_restore), "skipped": sorted(skipped)}


def inspect_summary(project: Path, profile: dict) -> dict:
    """Technology-specific part of `aegl inspect`, owned by the adapter."""
    project = project.resolve()
    prefix = package_prefix(project)
    indicators = profile["indicators"]
    return {
        "technology": {
            "language": "kotlin",
            "buildSystem": "gradle",
            "android": indicators["androidPlugin"],
        },
        "governance": {
            "existingDetekt": indicators["existingDetekt"],
            "existingKonsist": indicators["existingKonsist"],
            "existingCI": indicators["existingCI"],
            "existingClaude": indicators["existingClaude"],
            "existingAgents": indicators["existingAgents"],
            "existingArchitectureTests": indicators["existingArchitectureTests"],
        },
        "packagePrefix": prefix,
        "existingLayers": existing_layers(project, prefix),
    }


def describe() -> dict:
    return json.loads((Path(__file__).resolve().parent / "adapter.json").read_text())
