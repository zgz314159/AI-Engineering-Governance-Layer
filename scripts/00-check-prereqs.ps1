$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Require-Command([string]$Name, [string]$Hint) {
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing required command '$Name'. $Hint"
    }
    Write-Host "[OK] $Name -> $((Get-Command $Name).Source)"
}

Require-Command git "Install Git for Windows."
Require-Command node "Install Node.js 22+."
Require-Command npm "npm must accompany Node.js."
Require-Command java "Install JDK 21."
Require-Command python "Install Python 3.11+."

if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "[INFO] uv not found; installing with WinGet..."
        winget install --id=astral-sh.uv -e --accept-source-agreements --accept-package-agreements
        $env:Path = "$env:USERPROFILE\.local\bin;$env:Path"
    } else {
        throw "uv not found. Install it with: winget install --id=astral-sh.uv -e"
    }
}
Require-Command uv "Spec Kit requires uv."

$nodeMajor = [int]((node --version).TrimStart('v').Split('.')[0])
if ($nodeMajor -lt 22) {
    throw "Node.js 22+ required for RuleSync source build. Current: $(node --version)"
}

$pythonVersion = (python --version 2>&1).ToString().Split(' ')[1]
$pythonParts = $pythonVersion.Split('.')
if ([int]$pythonParts[0] -lt 3 -or ([int]$pythonParts[0] -eq 3 -and [int]$pythonParts[1] -lt 11)) {
    throw "Python 3.11+ required. Current: $pythonVersion"
}

Write-Host "[OK] Node $(node --version)"
Write-Host "[OK] Python $pythonVersion"
Write-Host "[OK] Java:"
java -version
Write-Host "[OK] uv $(uv --version)"
