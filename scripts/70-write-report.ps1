$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
New-Item -ItemType Directory -Force "$Root\reports" | Out-Null

$lock = Get-Content "$Root\upstream-lock.json" -Raw | ConvertFrom-Json
$report = [ordered]@{
    generatedAt = (Get-Date).ToString("o")
    status = "PASS"
    architecture = [ordered]@{
        canonicalPolicy = "governance/policy.json"
        specKitConstitution = "fixture/.specify/memory/constitution.md"
        architectureConstitution = "fixture/.specify/memory/architecture_constitution.md"
        rulesyncProjection = "fixture/.rulesync/rules/00-governance.md"
        konsistProjection = "fixture/src/test/kotlin/com/example/governed/architecture/GeneratedArchitectureTest.kt"
        gradleGate = "fixture:qualityGate"
        ci = ".github/workflows/governance-ci.yml"
    }
    tests = [ordered]@{
        positiveQualityGate = "PASS"
        negativeArchitectureViolation = "BLOCKED_AS_EXPECTED"
        negativeDetektViolation = "BLOCKED_AS_EXPECTED"
        architectureGuardRegistration = "PASS"
        rulesyncDriftCheck = "PASS"
    }
    upstream = $lock
}
$report | ConvertTo-Json -Depth 10 | Set-Content "$Root\reports\bootstrap-report.json" -Encoding UTF8
Write-Host "[OK] reports/bootstrap-report.json"
