$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
$Fixture = "$Root\fixture"
$SpecKit = "$Root\upstream\spec-kit"
$RuleSyncCli = "$Root\upstream\rulesync\dist\cli\index.js"

Push-Location $Fixture
try {
    Write-Host "[1] Spec Kit runtime"
    uv run --project $SpecKit specify version

    Write-Host "[2] Architecture Guard extension registration"
    $extensions = (uv run --project $SpecKit specify extension list --json) | ConvertFrom-Json
    if (-not ($extensions | Where-Object { $_.id -eq "architecture-guard" })) {
        throw "Architecture Guard missing."
    }

    Write-Host "[3] Architecture Guard generated command/skill presence"
    $agFiles = Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "architecture-guard|ag-" }
    if ($agFiles.Count -eq 0) {
        throw "No Architecture Guard agent command/skill files found."
    }

    Write-Host "[4] RuleSync drift check"
    node $RuleSyncCli generate --targets claudecode --features rules --check
    node $RuleSyncCli generate --targets codexcli --features rules --check
    node $RuleSyncCli generate --targets cursor --features rules --check

    Write-Host "[5] Gradle deterministic quality gate (Konsist + Detekt + JUnit)"
    .\gradlew.bat clean qualityGate

    if ($LASTEXITCODE -ne 0) {
        throw "Gradle qualityGate failed."
    }

    Write-Host "POSITIVE GATE: PASS"
} finally {
    Pop-Location
}
