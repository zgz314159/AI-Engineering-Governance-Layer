"""AEGL Android (Gradle) adapter.

Technology adapter for Android / Gradle projects. It is deliberately **not**
derived from the Kotlin adapter: Android is multi-module, has Android-specific
boundaries (domain isolation, ViewModel/Compose/Room boundaries) and needs
Android Lint, none of which the single-module Kotlin adapter models.

Non-invasive by design: `attach` writes an AEGL overlay under `<project>/.aegl/`
plus a CI bridge, and injects Detekt, the Konsist architecture test, Android Lint
and a Gradle module-boundary check at run time via `gradle --init-script`. The
target's own Gradle build files are never modified, which is what makes `detach`
safe and complete.

Single source of truth: `.aegl/policy.json` is the **Android governance model**.
The architecture constitution, the Konsist executable rules, the Detekt profile,
the module-boundary rules and the quality gate are all projections of it.

All library functions take an absolute project `Path`.
"""
from __future__ import annotations

import hashlib
import json
import re
import subprocess
import xml.etree.ElementTree as ET
from pathlib import Path

LANGUAGE = "android"

# Pinned tool versions (match upstream-lock.json / versions.json where shared).
DETEKT_VERSION = "1.23.8"
KONSIST_VERSION = "0.17.3"
JUNIT_VERSION = "5.11.4"

# Android toolchain the adapter validates against (documented in the report).
TOOLCHAIN = {
    "agp": "8.13.2",
    "kotlin": "2.0.21",
    "gradle": "8.13",
    "jdk": "21",
    "compileSdk": "37",
    "minSdk": "24",
    "targetSdk": "37",
    "buildTools": "36.0.0",
}

_SKIP_DIRS = ("/build/", "/.aegl/", "/.gradle/", "/.git/", "/node_modules/", "/.kotlin/")
_LAYER_SEGMENTS = {"domain", "data", "presentation", "ui", "app", "feature"}
_EXTRA_MARKERS = {
    "compose": ("androidx.compose", "compose = true", "kotlin.plugin.compose"),
    "hilt": ("com.google.dagger", "dagger.hilt", "hilt-android"),
    "room": ("androidx.room", "room-runtime"),
    "datastore": ("androidx.datastore", "datastore-preferences"),
    "ksp": ("com.google.devtools.ksp", "ksp(", "ksp ="),
    "kapt": ("kotlin-kapt", "ktlint", "kapt("),
    "ktor": ("io.ktor", "ktor-client"),
    "retrofit": ("retrofit2", "com.squareup.retrofit"),
    "detekt": ("detekt",),
    "konsist": ("konsist",),
    "androidLint": ("lint {", "lintOptions", "android.lint"),
    "versionCatalog": ("libs.versions.toml", "libs.plugins", "libs.androidx"),
}


def _aegl_version() -> str:
    """Single source of truth for the AEGL version: the top-level VERSION file."""
    try:
        return (Path(__file__).resolve().parents[2] / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        return "0.0.0"


AEGL_VERSION = _aegl_version()


# --------------------------------------------------------------------------- #
# Small helpers
# --------------------------------------------------------------------------- #

def _sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _sha256_path(p: Path) -> str:
    return _sha256_bytes(p.read_bytes())


def _read(p: Path) -> str:
    try:
        return p.read_text(encoding="utf-8")
    except OSError:
        return ""


def _skippable(p: Path) -> bool:
    s = p.as_posix()
    return any(d in s for d in _SKIP_DIRS)


def _gradle_files(project: Path) -> list[Path]:
    """All settings/build Gradle files, excluding build outputs and the overlay."""
    out: list[Path] = []
    for name in ("settings.gradle.kts", "settings.gradle", "build.gradle.kts", "build.gradle"):
        p = project / name
        if p.is_file():
            out.append(p)
    for pattern in ("**/build.gradle.kts", "**/build.gradle"):
        for p in project.glob(pattern):
            if p.is_file() and not _skippable(p) and p not in out:
                out.append(p)
    return sorted(set(out))


def _production_source_dirs(project: Path) -> list[Path]:
    dirs: list[Path] = []
    for pattern in ("**/src/main/kotlin", "**/src/main/java"):
        for d in project.glob(pattern):
            if d.is_dir() and not _skippable(d):
                dirs.append(d)
    return sorted(set(dirs))


def _production_packages(project: Path) -> list[str]:
    pkgs: set[str] = set()
    for root in _production_source_dirs(project):
        for kt in list(root.rglob("*.kt")) + list(root.rglob("*.java")):
            if _skippable(kt):
                continue
            for line in _read(kt).splitlines():
                m = re.match(r"\s*package\s+([\w.]+)\s*;?\s*$", line)
                if m:
                    pkgs.add(m.group(1))
                    break
    return sorted(pkgs)


def _strip_layer(pkg: str) -> list[str]:
    segs = pkg.split(".")
    for i, s in enumerate(segs):
        if s.lower() in _LAYER_SEGMENTS:
            return segs[:i]
    return segs


def _camel(text: str) -> str:
    return text[:1].upper() + text[1:]


# --------------------------------------------------------------------------- #
# Detection / scanning
# --------------------------------------------------------------------------- #

def _parse_includes(settings_text: str) -> list[str]:
    out: list[str] = []
    for m in re.finditer(r"include\s*\(([^)]*)\)", settings_text):
        out.extend(re.findall(r'"([^"]+)"', m.group(1)))
    for m in re.finditer(r"^\s*include\s+([^(\n][^\n]*)", settings_text, re.M):
        out.extend(re.findall(r"['\"]([^'\"]+)['\"]", m.group(1)))
    seen, uniq = set(), []
    for p in out:
        p = p.strip()
        if p and p not in seen:
            seen.add(p)
            uniq.append(p)
    return uniq


def _module_dir(project: Path, path: str) -> Path:
    rel = path.lstrip(":").replace(":", "/")
    return project / rel if rel else project


def scan_modules(project: Path) -> list[dict]:
    project = project.resolve()
    settings = next((project / n for n in ("settings.gradle.kts", "settings.gradle") if (project / n).is_file()), None)
    includes = _parse_includes(_read(settings)) if settings else []

    modules: list[dict] = []
    for path in includes:
        mdir = _module_dir(project, path)
        build = next((mdir / n for n in ("build.gradle.kts", "build.gradle") if (mdir / n).is_file()), None)
        btext = _read(build) if build else ""
        if "com.android.application" in btext:
            role = "app"
        elif "com.android.library" in btext:
            role = "library"
        elif mdir.is_dir():
            role = "unknown"
        else:
            role = "missing"
        deps = sorted(set(re.findall(r"project\s*\(\s*[\"']([^\"']+)[\"']\s*\)", btext)))
        modules.append({
            "path": path,
            "dir": str(mdir.relative_to(project)) if mdir != project else ".",
            "role": role,
            "plugins": {
                "androidApplication": "com.android.application" in btext,
                "androidLibrary": "com.android.library" in btext,
                "kotlinAndroid": "org.jetbrains.kotlin.android" in btext or "kotlin(\"android\")" in btext,
            },
            "projectDependencies": deps,
        })
    return sorted(modules, key=lambda m: m["path"])


def _detect_layers(prefix: str, packages: list[str]) -> list[dict]:
    layers: dict[str, dict] = {}
    for pkg in packages:
        rest = pkg[len(prefix) + 1:] if prefix and pkg.startswith(prefix + ".") else pkg
        parts = rest.split(".") if rest else []
        if not parts or not parts[0]:
            continue
        head = parts[0].lower()
        if head == "feature" and len(parts) >= 2:
            name, seg, kind = _camel("feature") + _camel(parts[1]), "feature." + parts[1], "feature"
        elif head == "domain":
            name, seg, kind = "Domain", "domain", "domain"
        elif head == "data":
            name, seg, kind = "Data", "data", "data"
        elif head in ("presentation", "ui"):
            name, seg, kind = "Presentation", parts[0], "presentation"
        elif head == "app":
            name, seg, kind = "App", "app", "app"
        else:
            name, seg, kind = _camel(parts[0]), parts[0], "core"
        root = f"{prefix}.{seg}" if prefix else seg
        layers.setdefault(name, {"name": name, "rootPackage": root, "kind": kind})
    return sorted(layers.values(), key=lambda l: l["name"])


def package_prefix(project: Path) -> str:
    packages = _production_packages(project)
    stripped = [_strip_layer(p) for p in packages]
    stripped = [s for s in stripped if s]
    if not stripped:
        return "com.example"
    common = stripped[0]
    for segs in stripped[1:]:
        i = 0
        while i < len(common) and i < len(segs) and common[i] == segs[i]:
            i += 1
        common = common[:i]
    return ".".join(common) if common else "com.example"


def existing_layers(project: Path, prefix: str) -> list[str]:
    return [l["name"] for l in _detect_layers(prefix, _production_packages(project))]


def detect(project: Path) -> dict:
    project = project.resolve()
    gfiles = _gradle_files(project)
    text = "\n".join(_read(p) for p in gfiles)
    settings = [n for n in ("settings.gradle.kts", "settings.gradle") if (project / n).is_file()]
    builds = [n for n in ("build.gradle.kts", "build.gradle") if (project / n).is_file()]
    modules = scan_modules(project)

    indicators = {
        "settingsGradle": bool(settings),
        "buildGradle": bool(builds),
        "gradleWrapper": (project / "gradlew").is_file(),
        "androidApplication": "com.android.application" in text,
        "androidLibrary": "com.android.library" in text,
        "androidPlugin": ("com.android.application" in text) or ("com.android.library" in text),
        "kotlinPlugin": bool(re.search(r"org\.jetbrains\.kotlin\.android|kotlin\(\"android\"\)", text)),
        "existingDetekt": "detekt" in text.lower(),
        "existingKonsist": "konsist" in text.lower(),
        "existingCI": (project / ".github/workflows").is_dir(),
        "existingClaude": (project / "CLAUDE.md").is_file(),
        "existingAgents": (project / "AGENTS.md").is_file(),
        "existingArchitectureTests": any(
            re.search(r"Architecture.*Test", p.name)
            for p in project.glob("**/src/test/**/*.kt") if not _skippable(p)
        ),
        "multiModule": len([m for m in modules if m["role"] in ("app", "library")]) > 1,
        "versionCatalog": (project / "gradle/libs.versions.toml").is_file(),
        "buildSrc": (project / "buildSrc").is_dir(),
        "buildLogic": (project / "build-logic").is_dir(),
        "conventionPlugins": (project / "buildSrc/src/main/kotlin").is_dir() or (project / "build-logic").is_dir(),
        "gradleWrapperVersion": _read(project / "gradle/wrapper/gradle-wrapper.properties"),
    }
    for key, needles in _EXTRA_MARKERS.items():
        indicators[key] = any(n in text.lower() if not n.endswith(".toml") else (project / n).is_file() for n in needles)

    matched = indicators["androidPlugin"] and indicators["settingsGradle"]
    profile = {
        "language": LANGUAGE,
        "adapterVersion": AEGL_VERSION,
        "matched": matched,
        "indicators": indicators,
        "modules": modules,
    }
    return profile


def _detected_versions(project: Path) -> dict:
    text = "\n".join(_read(p) for p in _gradle_files(project))
    catalog = _read(project / "gradle/libs.versions.toml")

    def find(pattern: str) -> str | None:
        m = re.search(pattern, text, re.M)
        return m.group(1) if m else None

    return {
        "agp": find(r'com\.android\.(?:application|library)[\'"]?\s*\)?\s*version\s*[\'"]?([\d.]+)')
        or find(r'androidGradlePlugin\s*=\s*[\'"]([\d.]+)[\'"]')
        or (re.search(r'agp\s*=\s*[\'"]([\d.]+)[\'"]', catalog).group(1) if re.search(r'agp\s*=\s*[\'"]([\d.]+)[\'"]', catalog) else None)
        or TOOLCHAIN["agp"],
        "kotlin": find(r'org\.jetbrains\.kotlin\.(?:android|jvm)[\'"]?\s*\)?\s*version\s*[\'"]?([\d.]+)')
        or (re.search(r'kotlin\s*=\s*[\'"]([\d.]+)[\'"]', catalog).group(1) if re.search(r'kotlin\s*=\s*[\'"]([\d.]+)[\'"]', catalog) else None)
        or TOOLCHAIN["kotlin"],
        "compileSdk": find(r"compileSdk\s*=?\s*(\d+)") or TOOLCHAIN["compileSdk"],
        "minSdk": find(r"minSdk\s*=?\s*(\d+)") or TOOLCHAIN["minSdk"],
        "targetSdk": find(r"targetSdk\s*=?\s*(\d+)") or TOOLCHAIN["targetSdk"],
        "buildTools": find(r'buildToolsVersion\s*=?\s*[\'"]([\d.]+)[\'"]') or TOOLCHAIN["buildTools"],
        "gradle": (re.search(r"gradle-([\d.]+)-bin\.zip", _read(project / "gradle/wrapper/gradle-wrapper.properties")).group(1)
                   if re.search(r"gradle-([\d.]+)-bin\.zip", _read(project / "gradle/wrapper/gradle-wrapper.properties")) else TOOLCHAIN["gradle"]),
    }


# --------------------------------------------------------------------------- #
# Governance model (single source of truth) + projections
# --------------------------------------------------------------------------- #

def _allowed_deps(layers: list[dict]) -> None:
    names = [l["name"] for l in layers]
    for layer in layers:
        kind = layer["kind"]
        if kind == "domain":
            allowed: list[str] = []
        elif kind == "data":
            allowed = [n for n in names if n == "Domain"]
        elif kind == "presentation":
            allowed = [n for n in names if n == "Domain"]
        elif kind == "feature":
            allowed = [n for n in names if n in ("Domain", "Data")]
        elif kind == "app":
            allowed = [n for n in names if n != "App"]
        else:
            allowed = [n for n in names if n in ("Domain", "Data")]
        layer["mayDependOn"] = allowed


_MODULE_ROLES = {"app": "app", "domain": "domain", "data": "data", "feature": "feature"}


def _module_records(project: Path, modules: list[dict], layers: list[dict]) -> list[dict]:
    roots = [(layer["rootPackage"], layer) for layer in layers]
    records = []
    for m in modules:
        if m["role"] not in ("app", "library"):
            continue
        mdir = _module_dir(project, m["path"])
        kinds: set[str] = set()
        for pkg in _production_packages(mdir):
            for root, layer in roots:
                if pkg == root or pkg.startswith(root + "."):
                    kinds.add(layer["kind"])
                    break
        # An application module is always the "app" role; a library takes the
        # single layer kind it owns, or "core" when it owns several (or none).
        if m["role"] == "app":
            role, layer_name = "app", "App" if any(k == "app" for k in kinds) else None
        elif len(kinds) == 1:
            kind = next(iter(kinds))
            role = _MODULE_ROLES.get(kind, "core")
            layer_name = next((layer["name"] for layer in layers if layer["kind"] == kind), None)
        else:
            role, layer_name = "core", None
        records.append({
            "path": m["path"],
            "role": role,
            "layer": layer_name,
            "projectDependencies": m["projectDependencies"],
        })
    return sorted(records, key=lambda r: r["path"])


def governance_model(project: Path) -> dict:
    project = project.resolve()
    prefix = package_prefix(project)
    packages = _production_packages(project)
    layers = _detect_layers(prefix, packages)
    _allowed_deps(layers)
    modules = scan_modules(project)
    module_records = _module_records(project, modules, layers)

    hosts = [m["path"] for m in module_records if m["role"] == "app"]
    if not hosts:
        hosts = [m["path"] for m in module_records] or [":"]

    domain_roots = [l["rootPackage"] for l in layers if l["kind"] == "domain"]
    data_roots = [l["rootPackage"] for l in layers if l["kind"] == "data"]
    presentation_roots = [l["rootPackage"] for l in layers if l["kind"] == "presentation"]
    feature_roots = [l["rootPackage"] for l in layers if l["kind"] == "feature"]

    return {
        "adapter": LANGUAGE,
        "aeglVersion": AEGL_VERSION,
        "policyVersion": "1.2.0",
        "projectName": project.name,
        "packagePrefix": prefix,
        "toolchain": _detected_versions(project),
        "pinnedToolchain": TOOLCHAIN,
        "principles": [
            "Specifications and architecture rules are authoritative before implementation.",
            "AI agents MUST NOT silently change architecture to make implementation easier.",
            "A task is complete only after deterministic quality gates pass.",
            "Android source-of-truth is this policy; the constitution, Konsist rules, Detekt profile and gate are generated from it.",
        ],
        "layers": layers,
        "android": {
            "hostModule": hosts[0],
            "modules": module_records,
            "moduleGraph": {r["path"]: r["projectDependencies"] for r in module_records},
            "moduleBoundary": {
                "rules": [
                    {"id": "no-depend-on-app", "description": "No module may depend on an application module."},
                    {"id": "domain-purity", "description": "Domain modules must not depend on any other module."},
                    {"id": "feature-isolation", "description": "Feature modules must not depend on other feature modules."},
                    {"id": "core-no-feature", "description": "core/data modules must not depend on feature or app modules."},
                ]
            },
            "rules": {
                "domainRoots": domain_roots,
                "dataRoots": data_roots,
                "presentationRoots": presentation_roots,
                "featureRoots": feature_roots,
                "viewModelForbiddenImports": [
                    "android.app.Activity", "android.app.Fragment", "android.view.View", "android.view.ViewGroup",
                ],
                "viewModelForbiddenPrefixes": ["androidx.fragment."],
                "semantic": [
                    "Room entities must not be exposed as UI state through the full data flow (documented, not machine-verified).",
                ],
            },
            "lintTask": "lintDebug",
        },
        "qualityGates": [
            "AEGL module boundary check passes",
            "Konsist Android architecture tests pass",
            "Detekt reports zero issues",
            "Android Lint reports no errors",
            "Unit tests pass",
            "Debug build compiles",
        ],
    }


def _constitution(model: dict) -> str:
    lines = []
    for layer in model["layers"]:
        deps = layer["mayDependOn"]
        dep_txt = "nothing" if not deps else ", ".join(deps)
        lines.append(f"- **{layer['name']}** (`{layer['rootPackage']}..`) may depend on: **{dep_txt}**.")
    app = model["android"]
    rules = [
        "- **Domain isolation**: the domain layer MUST NOT depend on `android.*` or `androidx.*`.",
        "- **Presentation boundary**: UI/presentation MUST NOT access DAOs, databases or data sources directly.",
        "- **Data boundary**: data MUST NOT depend on presentation/UI.",
        "- **ViewModel boundary**: ViewModels MUST NOT hold Activity/Fragment/View (application `Context` is allowed).",
        "- **Feature boundary**: `:feature:*` modules MUST NOT depend on other `:feature:*` modules.",
        "- **Compose boundary**: `@Composable` functions MUST NOT access DAOs/databases/repositories directly.",
        "- **Room boundary**: Room `@Entity` types belong to the data layer only.",
    ]
    return f"""# Android Architecture Constitution

Project: {model['projectName']}
Governed by: AEGL (AI Engineering Governance Layer) {model['aeglVersion']} — android adapter

## Layer Boundaries
{chr(10).join(lines)}

## Module Boundary Rules
{chr(10).join('- ' + r['description'] for r in app['moduleBoundary']['rules'])}

## Android Boundaries
{chr(10).join(rules)}

## Blocking Violations
- A layer depending on a layer not listed above is a blocking violation.
- Domain is independent; domain code MUST NOT import `android.*` or `androidx.*`.
- AI agents MUST NOT weaken these boundaries merely to make an implementation easier.

## Semantic Rules (documented, not machine-verified)
{chr(10).join('- ' + s for s in app['rules']['semantic'])}

> GENERATED by AEGL `attach` from `.aegl/policy.json`. Do not edit directly.
"""


def _project_constitution(model: dict) -> str:
    principles = "\n".join(f"- {p}" for p in model["principles"])
    gates = "\n".join(f"- {g}" for g in model["qualityGates"])
    return f"""# Project Constitution

Project: {model['projectName']}
Governed by: AEGL (AI Engineering Governance Layer) {model['aeglVersion']} — android adapter

## Engineering Principles
{principles}

## Definition of Done
{gates}

> GENERATED by AEGL `attach` from `.aegl/policy.json`. Do not edit directly.
"""


DETEKT_YML = """# GENERATED by AEGL `attach` (android adapter). Do not edit directly.
# A moderate, AI-focused profile: complexity and dead-code hygiene, not every rule.
build:
  maxIssues: 0

config:
  validation: true
  warningsAsErrors: true

complexity:
  CyclomaticComplexMethod:
    active: true
    threshold: 15
  LongMethod:
    active: true
    threshold: 60
  LargeClass:
    active: true
    threshold: 600
  TooManyFunctions:
    active: true
    thresholdInFiles: 20
    thresholdInClasses: 15
  NestedBlockDepth:
    active: true
    threshold: 4

style:
  MagicNumber:
    active: true
    ignoreNumbers: ['-1', '0', '1', '2']
    ignoreConstantDeclaration: true
    ignoreCompanionObjectPropertyDeclaration: true
    ignoreAnnotation: true
    ignoreNamedArgument: true
    ignoreEnums: true
  UnusedPrivateMember:
    active: true
  UnusedParameter:
    active: true
  ReturnCount:
    active: true
    max: 3

exceptions:
  SwallowedException:
    active: true
  TooGenericExceptionCaught:
    active: true
"""


def _klist(items: list[str]) -> str:
    if not items:
        return "emptyList<String>()"
    return "listOf(" + ", ".join(f'"{i}"' for i in items) + ")"


def _v(name: str) -> str:
    return name[:1].lower() + name[1:]


def _generated_test(model: dict) -> str:
    layers = model["layers"]
    rules = model["android"]["rules"]
    L: list[str] = []
    L.append("package aegl.generated")
    L.append("")
    L.append("import com.lemonappdev.konsist.api.Konsist")
    L.append("import com.lemonappdev.konsist.api.architecture.KoArchitectureCreator.assertArchitecture")
    L.append("import com.lemonappdev.konsist.api.architecture.Layer")
    L.append("import com.lemonappdev.konsist.api.container.KoScope")
    L.append("import com.lemonappdev.konsist.api.declaration.KoFileDeclaration")
    L.append("import com.lemonappdev.konsist.api.verify.assertFalse")
    L.append("import org.junit.jupiter.api.Test")
    L.append("")
    L.append("/**")
    L.append(" * GENERATED by AEGL `attach` (android adapter) from .aegl/policy.json.")
    L.append(" * Do not edit this file directly.")
    L.append(" */")
    L.append("class GeneratedAndroidArchitectureTest {")
    L.append("")
    L.append("    private val scope: KoScope by lazy {")
    L.append('        val dirs = (System.getProperty("aegl.sourceDirs") ?: "")')
    L.append("            .split(java.io.File.pathSeparator)")
    L.append("            .filter { it.isNotBlank() }")
    L.append("        if (dirs.isEmpty()) Konsist.scopeFromDirectory(\".\") else Konsist.scopeFromExternalDirectories(dirs)")
    L.append("    }")
    L.append("")
    L.append(f"    private val domainRoots = {_klist(rules['domainRoots'])}")
    L.append(f"    private val dataRoots = {_klist(rules['dataRoots'])}")
    L.append(f"    private val presentationRoots = {_klist(rules['presentationRoots'])}")
    L.append(f"    private val featureRoots = {_klist(rules['featureRoots'])}")
    L.append(f"    private val viewModelForbiddenImports = {_klist(rules['viewModelForbiddenImports'])}")
    L.append(f"    private val viewModelForbiddenPrefixes = {_klist(rules['viewModelForbiddenPrefixes'])}")
    L.append("")
    L.append("    private fun inPackages(file: KoFileDeclaration, roots: List<String>): Boolean =")
    L.append("        roots.any { file.packagee?.name?.startsWith(it) == true }")
    L.append("")
    L.append("    private fun isDataImport(fqn: String): Boolean =")
    L.append("        dataRoots.any { fqn.startsWith(it) } ||")
    L.append('            fqn.startsWith("androidx.room.") ||')
    L.append("            fqn.substringAfterLast('.').let {")
    L.append('                it.endsWith("Dao") || it.endsWith("Database") || it.endsWith("DataSource")')
    L.append("            }")
    L.append("")

    if layers:
        names = [layer["name"] for layer in layers]
        prohibitions: list[str] = []
        for layer in layers:
            v = _v(layer["name"])
            allowed = set(layer["mayDependOn"])
            prohibited = [n for n in names if n != layer["name"] and n not in allowed]
            if not prohibited:
                continue
            if len(prohibited) == len(names) - 1:
                prohibitions.append(f"            {v}.dependsOnNothing()")
            else:
                refs = ", ".join(_v(p) for p in prohibited)
                prohibitions.append(f"            {v}.doesNotDependOn(setOf({refs}))")
        if not prohibitions:
            prohibitions.append(f"            {_v(names[0])}.include()")
        L.append("    @Test")
        L.append("    fun `layer dependency policy must hold`() {")
        L.append("        scope.assertArchitecture {")
        for layer in layers:
            L.append(f'            val {_v(layer["name"])} = Layer("{layer["name"]}", "{layer["rootPackage"]}..")')
        L.append("")
        L.extend(prohibitions)
        L.append("        }")
        L.append("    }")
        L.append("")

    L.append("    @Test")
    L.append("    fun `domain must not depend on android`() {")
    L.append("        scope.files")
    L.append("            .filter { inPackages(it, domainRoots) }")
    L.append('            .assertFalse(additionalMessage = "domain must not import android/androidx") { f ->')
    L.append('                f.imports.any { imp -> imp.name.startsWith("android.") || imp.name.startsWith("androidx.") }')
    L.append("            }")
    L.append("    }")
    L.append("")

    L.append("    @Test")
    L.append("    fun `presentation must not access the data layer`() {")
    L.append("        scope.files")
    L.append("            .filter { inPackages(it, presentationRoots) }")
    L.append('            .assertFalse(additionalMessage = "presentation must not use DAOs/databases/data sources") { f ->')
    L.append("                f.imports.any { imp -> isDataImport(imp.name) }")
    L.append("            }")
    L.append("    }")
    L.append("")

    L.append("    @Test")
    L.append("    fun `view models must not reference ui framework types`() {")
    L.append("        scope.files")
    L.append('            .filter { f -> f.classes().any { c -> c.name.endsWith("ViewModel") } }')
    L.append('            .assertFalse(additionalMessage = "ViewModels must not hold Activity/Fragment/View") { f ->')
    L.append("                f.imports.any { imp ->")
    L.append("                    viewModelForbiddenImports.any { imp.name == it } ||")
    L.append("                        viewModelForbiddenPrefixes.any { imp.name.startsWith(it) }")
    L.append("                }")
    L.append("            }")
    L.append("    }")
    L.append("")

    L.append("    @Test")
    L.append("    fun `composable functions must not access the data layer`() {")
    L.append("        scope.files")
    L.append("            .filter { f -> f.functions().any { fn ->")
    L.append('                fn.hasAnnotationWithName("Composable") || fn.hasAnnotationWithName("androidx.compose.runtime.Composable")')
    L.append("            } }")
    L.append('            .assertFalse(additionalMessage = "Composables must not use DAOs/databases/data sources") { f ->')
    L.append("                f.imports.any { imp -> isDataImport(imp.name) }")
    L.append("            }")
    L.append("    }")
    L.append("")

    if rules["featureRoots"]:
        L.append("    @Test")
        L.append("    fun `feature modules must not depend on other feature modules`() {")
        L.append("        scope.files")
        L.append("            .filter { inPackages(it, featureRoots) }")
        L.append('            .assertFalse(additionalMessage = "features must not depend on other features") { f ->')
        L.append("                val own = featureRoots.firstOrNull { f.packagee?.name?.startsWith(it) == true }")
        L.append("                f.imports.any { imp -> featureRoots.any { r -> r != own && imp.name.startsWith(r) } }")
        L.append("            }")
        L.append("    }")
        L.append("")

    L.append("    @Test")
    L.append("    fun `room entities must live in the data layer`() {")
    L.append("        scope.files")
    L.append('            .filter { f -> f.imports.any { imp -> imp.name == "androidx.room.Entity" } }')
    L.append('            .assertFalse(additionalMessage = "Room @Entity types must live in the data layer") { f -> !inPackages(f, dataRoots) }')
    L.append("    }")
    L.append("}")
    L.append("")
    return "\n".join(L)


INIT_GRADLE = r"""// GENERATED by AEGL `attach` (android adapter). Do not edit directly.
// Injected via `gradle --init-script`. Adds Detekt, the Konsist architecture
// test, Android Lint and the module-boundary check WITHOUT modifying the
// target project's build files.
import groovy.json.JsonSlurper

initscript {
    repositories { mavenCentral(); gradlePluginPortal() }
    dependencies {
        classpath 'io.gitlab.arturbosch.detekt:detekt-gradle-plugin:__DETEKT__'
    }
}

def DETEKT = '__DETEKT__'
def KONSIST = '__KONSIST__'
def JUNIT = '__JUNIT__'

def aeglSourceDirs = { rootP ->
    def dirs = []
    rootP.allprojects.each { sp ->
        ['src/main/kotlin', 'src/main/java'].each { rel ->
            def d = new File(sp.projectDir, rel)
            if (d.isDirectory()) { dirs << d.absolutePath }
        }
    }
    return dirs.unique()
}

def aeglConfigureAndroidModule = { p, rootDir ->
    p.apply plugin: 'io.gitlab.arturbosch.detekt'
    p.detekt {
        buildUponDefaultConfig = false
        allRules = false
        config.setFrom(p.files(new File(rootDir, '.aegl/detekt.yml')))
    }
}

allprojects { p ->
    p.buildscript {
        repositories { mavenCentral(); gradlePluginPortal() }
        dependencies {
            classpath "io.gitlab.arturbosch.detekt:detekt-gradle-plugin:$DETEKT"
        }
    }

    def rootDir = p.rootProject.projectDir
    def modelFile = new File(rootDir, '.aegl/policy.json')
    if (modelFile.exists()) {
        def model = new JsonSlurper().parseText(modelFile.text)
        def isHost = (p.path == model.android.hostModule)

        p.plugins.withId('com.android.application') { aeglConfigureAndroidModule(p, rootDir) }
        p.plugins.withId('com.android.library') { aeglConfigureAndroidModule(p, rootDir) }

        p.plugins.withId('org.jetbrains.kotlin.android') {
            if (isHost) {
                p.dependencies {
                    testImplementation "com.lemonappdev:konsist:$KONSIST"
                    testImplementation "org.junit.jupiter:junit-jupiter:$JUNIT"
                    testRuntimeOnly 'org.junit.platform:junit-platform-launcher'
                }
                p.kotlin.sourceSets.configureEach { ks ->
                    if (ks.name in ['test', 'testDebug', 'debugUnitTest']) {
                        ks.kotlin.srcDir new File(rootDir, '.aegl/android')
                    }
                }
                p.tasks.withType(Test).configureEach { t ->
                    t.useJUnitPlatform()
                    t.doFirst {
                        t.systemProperty 'aegl.sourceDirs', aeglSourceDirs(p.rootProject).join(File.pathSeparator)
                    }
                }
            }
        }

        if (p.rootProject == p) {
            p.tasks.register('aeglModuleBoundaryCheck') {
                group = 'verification'
                description = 'AEGL Android module boundary check (deterministic Gradle project graph).'
                doLast {
                    def m = new JsonSlurper().parseText(new File(p.projectDir, '.aegl/policy.json').text)
                    def roles = [:]
                    m.android.modules.each { mod -> roles[mod.path] = mod.role }
                    def violations = []
                    p.allprojects.each { sp ->
                        def srcRole = roles[sp.path]
                        if (srcRole != null) {
                            // Only declarable configurations hold user-declared project
                            // dependencies; AGP's *Classpath configs inject self/transitive
                            // edges that must not be treated as architecture.
                            def declaredConfigs = ['api', 'implementation', 'compileOnly', 'compileOnlyApi',
                                                   'runtimeOnly', 'debugImplementation', 'releaseImplementation'] as Set
                            def targets = [] as Set
                            sp.configurations.each { cfg ->
                                if (declaredConfigs.contains(cfg.name)) {
                                    try {
                                        cfg.dependencies.each { d ->
                                            if (d instanceof org.gradle.api.artifacts.ProjectDependency && d.path != sp.path) {
                                                targets << d.path
                                            }
                                        }
                                    } catch (ignored) { }
                                }
                            }
                            targets.each { tgt ->
                                def tgtRole = roles[tgt]
                                if (tgtRole == 'app') {
                                    violations << "${sp.path} -> ${tgt} (no module may depend on an application module)"
                                }
                                if (srcRole == 'domain') {
                                    violations << "${sp.path} -> ${tgt} (domain modules must not depend on other modules)"
                                }
                                if (srcRole == 'feature' && tgtRole == 'feature') {
                                    violations << "${sp.path} -> ${tgt} (feature modules must not depend on other feature modules)"
                                }
                                if ((srcRole in ['core', 'data']) && (tgtRole in ['feature', 'app'])) {
                                    violations << "${sp.path} -> ${tgt} (core/data modules must not depend on feature/app modules)"
                                }
                            }
                        }
                    }
                    if (!violations.isEmpty()) {
                        throw new GradleException('AEGL module boundary violations:\n  ' + violations.unique().join('\n  '))
                    }
                    println 'AEGL module boundary check: PASS'
                }
            }

            def gate = p.tasks.register('aeglQualityGate') {
                group = 'verification'
                description = 'AEGL Android governance gate: module boundary + detekt + konsist + lint + tests + build.'
                dependsOn 'aeglModuleBoundaryCheck'
            }
            def modulePaths = model.android.modules.collect { it.path } as Set
            p.gradle.projectsEvaluated {
                p.allprojects.each { sp ->
                    if (modulePaths.contains(sp.path)) {
                        ['detekt', 'lintDebug', 'testDebugUnitTest', 'assembleDebug'].each { tn ->
                            if (sp.tasks.findByName(tn) != null) {
                                gate.configure { it.dependsOn("${sp.path}:${tn}") }
                            }
                        }
                    }
                }
            }
        }
    }
}
"""


QUALITY_GATE_SH = r"""#!/usr/bin/env bash
# AEGL Android quality gate bridge. Runs the module-boundary check, Detekt, the
# Konsist architecture tests, Android Lint, unit tests and the debug build via an
# init script so the target's own build files are never modified.
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$(cd "$HERE/.." && pwd)"
cd "$PROJECT"

if [ ! -x ./gradlew ]; then
    echo "AEGL: no ./gradlew in $PROJECT" >&2
    exit 2
fi

# Resolve the Android SDK from the environment or local.properties; never commit a machine path.
if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    if [ -f "$PROJECT/local.properties" ]; then
        SDK="$(sed -n 's/^sdk\.dir=//p' "$PROJECT/local.properties" | head -1)"
        if [ -n "$SDK" ]; then export ANDROID_SDK_ROOT="$SDK"; export ANDROID_HOME="$SDK"; fi
    fi
fi
if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ] && [ -d "$HOME/Android/Sdk" ]; then
    export ANDROID_SDK_ROOT="$HOME/Android/Sdk"; export ANDROID_HOME="$HOME/Android/Sdk"
fi

exec ./gradlew --init-script "$HERE/aegl-init.gradle" --continue aeglQualityGate "$@"
"""

CI_BRIDGE = """name: AEGL Governance
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
      - uses: android-actions/setup-android@v3
      - name: AEGL Android quality gate
        run: ./.aegl/quality-gate.sh
"""


# --------------------------------------------------------------------------- #
# Attach / detach / verify
# --------------------------------------------------------------------------- #

def _owned_files(project: Path) -> dict[str, tuple[str, int]]:
    project = project.resolve()
    model = governance_model(project)
    graph = model["android"]["moduleGraph"]
    return {
        ".aegl/policy.json": (json.dumps(model, indent=2) + "\n", 0o644),
        ".aegl/governance/constitution.md": (_project_constitution(model), 0o644),
        ".aegl/governance/architecture_constitution.md": (_constitution(model), 0o644),
        ".aegl/detekt.yml": (DETEKT_YML, 0o644),
        ".aegl/android/GeneratedAndroidArchitectureTest.kt": (_generated_test(model), 0o644),
        ".aegl/android/module-graph.json": (json.dumps(graph, indent=2) + "\n", 0o644),
        ".aegl/aegl-init.gradle": (
            INIT_GRADLE.replace("__DETEKT__", DETEKT_VERSION)
            .replace("__KONSIST__", KONSIST_VERSION)
            .replace("__JUNIT__", JUNIT_VERSION), 0o644),
        ".aegl/quality-gate.sh": (QUALITY_GATE_SH, 0o755),
        ".github/workflows/aegl-governance.yml": (CI_BRIDGE, 0o644),
    }


def _preserved(project: Path) -> list[str]:
    keep: list[str] = []
    for rel in ("CLAUDE.md", "AGENTS.md", "local.properties", "gradle.properties",
                "build.gradle.kts", "build.gradle", "settings.gradle.kts", "settings.gradle"):
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
    (project / ".aegl/manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    manifest["manifestPath"] = ".aegl/manifest.json"
    return manifest


def _test_failures(project: Path) -> list[dict]:
    out: list[dict] = []
    for xml in project.glob("**/build/test-results/**/*.xml"):
        try:
            root = ET.parse(xml).getroot()
        except ET.ParseError:
            continue
        for tc in root.iter("testcase"):
            for failure in list(tc.findall("failure")) + list(tc.findall("error")):
                out.append({
                    "suite": tc.get("classname", ""),
                    "test": tc.get("name", ""),
                    "message": (failure.get("message") or (failure.text or ""))[:800],
                })
    return out


def _detekt_findings(project: Path) -> list[dict]:
    out: list[dict] = []
    for xml in project.glob("**/build/reports/detekt/detekt.xml"):
        try:
            root = ET.parse(xml).getroot()
        except ET.ParseError:
            continue
        for f in root.iter("file"):
            for err in f.findall("error"):
                out.append({
                    "file": f.get("name", ""),
                    "rule": err.get("rule", ""),
                    "line": err.get("line", ""),
                    "message": (err.get("message") or "")[:300],
                })
    return out


def _lint_errors(project: Path) -> list[dict]:
    out: list[dict] = []
    for xml in project.glob("**/build/reports/lint-results-*.xml"):
        try:
            root = ET.parse(xml).getroot()
        except ET.ParseError:
            continue
        for issue in root.iter("issue"):
            if (issue.get("severity") or "").lower() != "error":
                continue
            loc = issue.find("location")
            out.append({
                "id": issue.get("id", ""),
                "message": (issue.get("message") or "")[:300],
                "file": (loc.get("file") if loc is not None else ""),
            })
    return out


def verify(project: Path) -> dict:
    project = project.resolve()
    script = project / ".aegl/quality-gate.sh"
    if not script.exists():
        return {"ok": False, "error": "not attached (.aegl/quality-gate.sh missing)"}

    proc = subprocess.run([str(script)], cwd=str(project), text=True, capture_output=True)
    out = (proc.stdout or "") + (proc.stderr or "")

    failed_tasks = re.findall(r"^\s*> Task (\S+) FAILED", out, re.M)
    executed_lint = sorted(set(re.findall(r"^\s*> Task (\S*lint\S*)", out, re.M)))

    gates = {"moduleBoundary": "PASS", "detekt": "PASS", "lint": "PASS", "unitTests": "PASS", "build": "PASS"}
    for task in failed_tasks:
        name = task.rsplit(":", 1)[-1]
        if name == "aeglModuleBoundaryCheck":
            gates["moduleBoundary"] = "FAIL"
        elif name == "detekt":
            gates["detekt"] = "FAIL"
        elif name.startswith("lint"):
            gates["lint"] = "FAIL"
        elif name.startswith("test") or name == "test":
            gates["unitTests"] = "FAIL"
        elif name.startswith("assemble") or name.startswith("compile") or name.startswith("package"):
            gates["build"] = "FAIL"

    test_failures = _test_failures(project)
    detekt_findings = _detekt_findings(project)
    lint_errors = _lint_errors(project)

    arch_failures = [
        f for f in test_failures
        if "GeneratedAndroidArchitectureTest" in f["suite"]
        or "KoAssertion" in f["message"]
        or "layer dependency policy" in f["test"]
    ]
    module_boundary: list[str] = []
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if "module boundary violation" in line.lower():
            for extra in lines[i:i + 8]:
                if " -> " in extra or "module boundary violation" in extra.lower():
                    module_boundary.append(extra.strip())
    if failed_tasks and any(t.endswith(":aeglModuleBoundaryCheck") for t in failed_tasks):
        module_boundary = module_boundary or ["aeglModuleBoundaryCheck FAILED"]

    return {
        "ok": proc.returncode == 0,
        "exitCode": proc.returncode,
        "gates": gates,
        "architectureViolation": bool(arch_failures),
        "moduleBoundaryViolation": gates["moduleBoundary"] == "FAIL" or bool(module_boundary),
        "architectureFailures": arch_failures,
        "moduleBoundaryViolations": module_boundary,
        "detektFindings": detekt_findings[:20],
        "lintErrors": lint_errors[:20],
        "testFailures": [f for f in test_failures if f not in arch_failures][:20],
        "lintTasksExecuted": executed_lint,
        "outputTail": "\n".join(out.strip().splitlines()[-25:]),
    }


def _prune_empty_dirs(root: Path) -> None:
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
        manifest_path.unlink()
    _prune_empty_dirs(project / ".aegl")
    _prune_empty_dirs(project / ".github")

    return {"removed": sorted(to_delete + [".aegl/manifest.json"]),
            "restored": sorted(to_restore), "skipped": sorted(skipped)}


# --------------------------------------------------------------------------- #
# Inspect summary
# --------------------------------------------------------------------------- #

def inspect_summary(project: Path, profile: dict) -> dict:
    project = project.resolve()
    prefix = package_prefix(project)
    layers = _detect_layers(prefix, _production_packages(project))
    modules = profile["modules"]
    graph = {m["path"]: m["projectDependencies"] for m in modules}
    return {
        "technology": {
            "language": "kotlin",
            "buildSystem": "gradle",
            "android": True,
            "multiModule": len([m for m in modules if m["role"] in ("app", "library")]) > 1,
        },
        "governance": {
            "existingDetekt": profile["indicators"]["existingDetekt"],
            "existingKonsist": profile["indicators"]["existingKonsist"],
            "existingCI": profile["indicators"]["existingCI"],
            "existingClaude": profile["indicators"]["existingClaude"],
            "existingAgents": profile["indicators"]["existingAgents"],
            "existingArchitectureTests": profile["indicators"]["existingArchitectureTests"],
        },
        "packagePrefix": prefix,
        "existingLayers": [l["name"] for l in layers],
        "android": {
            "agp": _detected_versions(project)["agp"],
            "kotlin": _detected_versions(project)["kotlin"],
            "compileSdk": _detected_versions(project)["compileSdk"],
            "minSdk": _detected_versions(project)["minSdk"],
            "targetSdk": _detected_versions(project)["targetSdk"],
            "modules": modules,
            "moduleGraph": graph,
            "hostModule": next((m["path"] for m in modules if m["role"] == "app"), modules[0]["path"] if modules else ":"),
        },
        "featureFlags": {
            k: v for k, v in profile["indicators"].items()
            if k in ("compose", "hilt", "room", "datastore", "ksp", "kapt", "ktor", "retrofit",
                     "detekt", "konsist", "androidLint", "versionCatalog", "buildSrc",
                     "buildLogic", "conventionPlugins")
        },
    }


def describe() -> dict:
    return json.loads((Path(__file__).resolve().parent / "adapter.json").read_text(encoding="utf-8"))
