$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$Root = Resolve-Path "$PSScriptRoot\.."
$Fixture = "$Root\fixture"
$Versions = Get-Content "$Root\versions.json" -Raw | ConvertFrom-Json
$GradleVersion = $Versions.gradle.version
$MirrorUrl = $Versions.gradle.distributionUrl
$OfficialUrl = if ($Versions.gradle.officialDistributionUrl) { $Versions.gradle.officialDistributionUrl } else { $MirrorUrl }
$ExpectedSha = $Versions.gradle.sha256

if (Test-Path "$Fixture\gradlew.bat") {
    Write-Host "[OK] Gradle wrapper already exists."
    exit 0
}

$Cache = "$Root\.cache"
New-Item -ItemType Directory -Force $Cache | Out-Null
$Zip = "$Cache\gradle-$GradleVersion-bin.zip"
$Unpack = "$Cache\gradle-$GradleVersion"

if (-not (Test-Path $Zip)) {
    Write-Host "[Gradle] downloading $MirrorUrl (mainland mirror)"
    try {
        Invoke-WebRequest -Uri $MirrorUrl -OutFile $Zip
    } catch {
        Write-Host "[Gradle] mirror failed; one official fallback: $OfficialUrl"
        Remove-Item -Force -ErrorAction SilentlyContinue $Zip
        Invoke-WebRequest -Uri $OfficialUrl -OutFile $Zip
    }
}

$ActualSha = (Get-FileHash $Zip -Algorithm SHA256).Hash.ToLowerInvariant()
if ($ActualSha -ne $ExpectedSha.ToLowerInvariant()) {
    throw "Gradle ZIP checksum mismatch. Expected $ExpectedSha, got $ActualSha"
}
Write-Host "[OK] Gradle distribution SHA-256 verified."

if (-not (Test-Path $Unpack)) {
    Expand-Archive -Path $Zip -DestinationPath $Cache -Force
}

$GradleBat = "$Unpack\bin\gradle.bat"
if (-not (Test-Path $GradleBat)) {
    throw "Cannot find $GradleBat"
}

& $GradleBat -p $Fixture wrapper --gradle-version $GradleVersion --distribution-type bin --gradle-distribution-url $MirrorUrl --gradle-distribution-sha256-sum $ExpectedSha
Write-Host "[OK] Gradle wrapper generated (mirror URL + official SHA-256)."
