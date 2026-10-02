$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
$SpecKit = "$Root\upstream\spec-kit"
$AG = "$Root\upstream\architecture-guard"
$RuleSync = "$Root\upstream\rulesync"

Write-Host "[Spec Kit] preparing local uv environment"
uv sync --project $SpecKit
uv run --project $SpecKit specify version

Write-Host "[Architecture Guard] npm ci + build + upstream tests"
Push-Location $AG
try {
    npm ci
    npm run build
    npm test
} finally {
    Pop-Location
}

Write-Host "[RuleSync] pnpm install + build from downloaded source"
Push-Location $RuleSync
try {
    npx --yes pnpm@10 install --frozen-lockfile
    npx --yes pnpm@10 run build
    node ".\dist\cli\index.js" --version
} finally {
    Pop-Location
}

Write-Host "[OK] Source-first tooling ready."
