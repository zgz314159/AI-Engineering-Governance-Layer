$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
$Versions = Get-Content "$Root\versions.json" -Raw | ConvertFrom-Json

Set-Location $Root
if (-not (Test-Path ".git")) {
    git init
    git branch -M main
}

New-Item -ItemType Directory -Force "$Root\upstream" | Out-Null

$items = @(
    @{ Name="spec-kit"; Key="specKit" },
    @{ Name="architecture-guard"; Key="architectureGuard" },
    @{ Name="konsist"; Key="konsist" },
    @{ Name="detekt"; Key="detekt" },
    @{ Name="rulesync"; Key="ruleSync" },
    @{ Name="gradle-actions"; Key="gradleActions" }
)

foreach ($item in $items) {
    $entry = $Versions.($item.Key)
    $path = "upstream/$($item.Name)"

    if (-not (Test-Path $path)) {
        Write-Host "[ADD] $($item.Name) <- $($entry.repo)"
        git submodule add $entry.repo $path
    } else {
        Write-Host "[EXISTS] $path"
        git submodule update --init --recursive -- $path
    }

    git -C $path fetch --tags --force
    git -C $path checkout --detach $entry.ref
}

git add .gitmodules upstream

$lock = [ordered]@{}
foreach ($item in $items) {
    $path = "upstream/$($item.Name)"
    $sha = (git -C $path rev-parse HEAD).Trim()
    $lock[$item.Name] = [ordered]@{
        ref = $Versions.($item.Key).ref
        commit = $sha
        repo = $Versions.($item.Key).repo
    }
}

$lock | ConvertTo-Json -Depth 6 | Set-Content "$Root\upstream-lock.json" -Encoding UTF8
Write-Host "[OK] Wrote upstream-lock.json"
