$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
$Fixture = "$Root\fixture"
$SpecKit = "$Root\upstream\spec-kit"
$AG = "$Root\upstream\architecture-guard"

Push-Location $Fixture
try {
    if (-not (Test-Path ".specify")) {
        Write-Host "[Spec Kit] initialize fixture from local downloaded source"
        uv run --project $SpecKit specify init --here --force --non-interactive --integration claude --script ps --ignore-agent-tools
    } else {
        Write-Host "[Spec Kit] fixture already initialized"
    }

    Write-Host "[Architecture Guard] install local downloaded source as Spec Kit dev extension"
    uv run --project $SpecKit specify extension add architecture-guard --dev $AG --force

    $json = uv run --project $SpecKit specify extension list --json
    $installed = $json | ConvertFrom-Json
    if (-not ($installed | Where-Object { $_.id -eq "architecture-guard" })) {
        throw "Architecture Guard extension is not registered in Spec Kit."
    }

    Write-Host "[OK] Architecture Guard registered."
} finally {
    Pop-Location
}
