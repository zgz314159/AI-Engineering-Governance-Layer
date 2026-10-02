$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
$Fixture = "$Root\fixture"
$BadArch = "$Fixture\src\main\kotlin\com\example\governed\domain\IllegalDependency.kt"
$BadDetekt = "$Fixture\src\main\kotlin\com\example\governed\domain\MagicNumberViolation.kt"

try {
    @"
package com.example.governed.domain

import com.example.governed.presentation.GreetingService

class IllegalDependency(
    private val presentation: GreetingService
)
"@ | Set-Content $BadArch -Encoding UTF8

    Push-Location $Fixture
    try {
        Write-Host "[NEGATIVE] Intentionally violating Domain -> Presentation"
        & .\gradlew.bat test
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($code -eq 0) {
        throw "NEGATIVE ARCHITECTURE TEST FAILED: Konsist allowed an illegal dependency."
    }
    Write-Host "NEGATIVE ARCHITECTURE TEST: PASS (violation correctly blocked)"
}
finally {
    Remove-Item $BadArch -Force -ErrorAction SilentlyContinue
}

try {
    @"
package com.example.governed.domain

fun forbiddenMagicNumber(): Int = 42
"@ | Set-Content $BadDetekt -Encoding UTF8

    Push-Location $Fixture
    try {
        Write-Host "[NEGATIVE] Intentionally creating Detekt MagicNumber violation"
        & .\gradlew.bat detekt
        $code2 = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if ($code2 -eq 0) {
        throw "NEGATIVE DETEKT TEST FAILED: Detekt allowed the configured violation."
    }
    Write-Host "NEGATIVE DETEKT TEST: PASS (violation correctly blocked)"
}
finally {
    Remove-Item $BadDetekt -Force -ErrorAction SilentlyContinue
}

# Ensure cleanup returns the fixture to green.
Push-Location $Fixture
try {
    .\gradlew.bat qualityGate
    if ($LASTEXITCODE -ne 0) {
        throw "Fixture did not return to green after negative tests."
    }
} finally {
    Pop-Location
}
