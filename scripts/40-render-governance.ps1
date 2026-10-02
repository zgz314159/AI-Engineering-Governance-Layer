$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
$Fixture = "$Root\fixture"
$Policy = Get-Content "$Root\governance\policy.json" -Raw | ConvertFrom-Json
$RuleSyncCli = "$Root\upstream\rulesync\dist\cli\index.js"

$Memory = "$Fixture\.specify\memory"
$RulesDir = "$Fixture\.rulesync\rules"
$TestDir = "$Fixture\src\test\kotlin\com\example\governed\architecture"
New-Item -ItemType Directory -Force $Memory, $RulesDir, $TestDir | Out-Null

# Deterministic RuleSync config: no interactive init and no target ambiguity.
$ruleSyncConfig = @"
{
  "`$schema": "https://github.com/dyoshikawa/rulesync/releases/download/v25.0.0/config-schema.json",
  "targets": {
    "claudecode": { "rules": true },
    "codexcli": { "rules": true },
    "cursor": { "rules": true }
  },
  "outputRoots": ["."],
  "delete": true,
  "verbose": true,
  "silent": false
}
"@
Set-Content "$Fixture\rulesync.jsonc" $ruleSyncConfig -Encoding UTF8

$principles = ($Policy.principles | ForEach-Object { "- $_" }) -join "`n"
$quality = ($Policy.qualityGates | ForEach-Object { "- $_" }) -join "`n"

$constitution = @"
# Project Constitution

Project: $($Policy.projectName)
Policy version: $($Policy.policyVersion)

## Engineering Principles
$principles

## Definition of Done
$quality

## Governance Rule
AI agents MUST NOT declare work complete unless the deterministic `qualityGate` passes.
Architecture changes MUST be explicit; they MUST NOT be introduced silently during implementation.

> GENERATED from `governance/policy.json`. Do not edit directly.
"@
Set-Content "$Memory\constitution.md" $constitution -Encoding UTF8

$archLines = @()
foreach ($layer in $Policy.layers) {
    $deps = if ($layer.mayDependOn.Count -eq 0) { "nothing" } else { ($layer.mayDependOn -join ", ") }
    $archLines += "- **$($layer.name)** (`$($layer.package)`) may depend on: **$deps**."
}
$archText = $archLines -join "`n"

$architecture = @"
# Architecture Constitution

## Layer Boundaries
$archText

## Blocking Violations
- A layer depending on a layer not listed above is a blocking violation.
- Domain is independent and MUST NOT depend on presentation or data.
- AI agents MUST NOT weaken these boundaries merely to make an implementation easier.

## Evolution Policy
To change a layer boundary, update `governance/policy.json`, regenerate governance outputs, and make the policy change visible in review.

> GENERATED from `governance/policy.json`. Do not edit directly.
"@
Set-Content "$Memory\architecture_constitution.md" $architecture -Encoding UTF8

$security = @"
# Security Constitution

This fixture intentionally contains only baseline governance:
- no secrets in source control;
- dependencies are pinned for the governance proof;
- CI must fail closed on quality-gate violations.

> GENERATED from `governance/policy.json`. Do not edit directly.
"@
Set-Content "$Memory\security_constitution.md" $security -Encoding UTF8

$memoryGuidance = @"
# Persistent Work Memory (optional)

AEGL can use Beads (bd) as an OPTIONAL long-horizon work graph and persistent
memory backend. AEGL owns session continuity; Beads owns the work graph;
RuleSync owns agent rules. When persistent work memory is enabled:
- aegl memory status   - check backend availability
- aegl memory ready    - long-horizon ready work (from bd ready)
- aegl bd ...          - task lifecycle (create / dep / update --claim / close / show)
- aegl memory remember - durable project knowledge only; secrets are rejected
- aegl handoff         - session continuity
Never run bd setup: it writes AGENTS.md / CLAUDE.md and would collide with RuleSync.
"@

$rulesyncRule = @"
---
targets:
  - "*"
root: true
description: "Generated governance policy shared across AI coding agents."
---

# AI Engineering Governance

$constitution

$architecture

$memoryGuidance
"@
Set-Content "$RulesDir\00-governance.md" $rulesyncRule -Encoding UTF8

# Generate a Konsist architecture test from the same policy.
$decls = @()
$calls = @()
foreach ($layer in $Policy.layers) {
    $var = $layer.name.Substring(0,1).ToLowerInvariant() + $layer.name.Substring(1)
    $decls += "            val $var = Layer(`"$($layer.name)`", `"$($layer.package)`")"
}
foreach ($layer in $Policy.layers) {
    $var = $layer.name.Substring(0,1).ToLowerInvariant() + $layer.name.Substring(1)
    if ($layer.mayDependOn.Count -eq 0) {
        $calls += "            $var.dependsOnNothing()"
    } else {
        $depVars = @()
        foreach ($dep in $layer.mayDependOn) {
            $depVars += ($dep.Substring(0,1).ToLowerInvariant() + $dep.Substring(1))
        }
        $calls += "            $var.dependsOn($($depVars -join ', '))"
    }
}

$kotlin = @"
package com.example.governed.architecture

import com.lemonappdev.konsist.api.Konsist
import com.lemonappdev.konsist.api.architecture.Layer
import com.lemonappdev.konsist.api.architecture.assertArchitecture
import org.junit.jupiter.api.Test

/**
 * GENERATED from governance/policy.json.
 * Do not edit this file directly.
 */
class GeneratedArchitectureTest {
    @Test
    fun `layer dependency policy must hold`() {
        Konsist
            .scopeFromProduction()
            .assertArchitecture {
$($decls -join "`n")

$($calls -join "`n")
            }
    }
}
"@
Set-Content "$TestDir\GeneratedArchitectureTest.kt" $kotlin -Encoding UTF8

Push-Location $Fixture
try {
    Write-Host "[RuleSync] generating Claude / Codex / Cursor rule projections"
    node $RuleSyncCli generate --targets claudecode --features rules
    node $RuleSyncCli generate --targets codexcli --features rules
    node $RuleSyncCli generate --targets cursor --features rules

    Write-Host "[RuleSync] verifying generated outputs are current"
    node $RuleSyncCli generate --targets claudecode --features rules --check
    node $RuleSyncCli generate --targets codexcli --features rules --check
    node $RuleSyncCli generate --targets cursor --features rules --check
} finally {
    Pop-Location
}

Write-Host "[OK] policy -> Spec Kit / Architecture Guard / RuleSync / Konsist rendered."
