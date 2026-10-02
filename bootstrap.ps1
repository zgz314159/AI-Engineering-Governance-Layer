$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Step([string]$Text) {
    Write-Host ""
    Write-Host "================================================================"
    Write-Host $Text
    Write-Host "================================================================"
}

Step "0/7 Prerequisite check"
& "$Root\scripts\00-check-prereqs.ps1"

Step "1/7 Fetch and pin upstream source projects"
& "$Root\scripts\10-fetch-upstreams.ps1"

Step "2/7 Build source-first tooling"
& "$Root\scripts\20-build-source-tools.ps1"

Step "3/7 Initialize Spec Kit + Architecture Guard fixture"
& "$Root\scripts\30-init-fixture.ps1"

Step "4/7 Render policy -> Spec Kit / RuleSync / Konsist"
& "$Root\scripts\40-render-governance.ps1"

Step "5/7 Bootstrap Gradle wrapper"
& "$Root\scripts\45-bootstrap-gradle.ps1"

Step "6/7 Run positive and negative integration tests"
& "$Root\scripts\50-positive-test.ps1"
& "$Root\scripts\60-negative-test.ps1"

Step "7/7 Write integration report"
& "$Root\scripts\70-write-report.ps1"

Write-Host ""
Write-Host "==============================================================="
Write-Host "GOVERNANCE LAYER: PASS"
Write-Host "Report: $Root\reports\bootstrap-report.json"
Write-Host "==============================================================="
