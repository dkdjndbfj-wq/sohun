# Exercises the actual release entry points without an SDK, credentials or builds.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$packager = Join-Path $repoRoot 'scripts/public_core_build.ps1'
$installer = Join-Path $repoRoot '电脑软件/scripts/build_installer.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sohun-public-release-check-' + [guid]::NewGuid().ToString('N'))
$stage = Join-Path $fixtureRoot 'source'
$output = Join-Path $fixtureRoot 'output'
$priorProperties = $env:SOHUN_ANDROID_SIGNING_PROPERTIES
$priorFingerprint = $env:SOHUN_ANDROID_SIGNING_CERT_SHA256
$originalLocation = Get-Location
$passed = 0
function Write-Fixture([string]$Relative, [string]$Text) {
    $path = Join-Path $stage $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.ToString() -notmatch $Pattern) { throw "Expected release rejection: $Pattern" }
    if (Test-Path -LiteralPath $output) { throw 'Rejected release unexpectedly created artifact output.' }
    $script:passed++
}
try {
    Write-Fixture '电脑软件/pubspec.yaml' "name: release_boundary_fixture`nversion: 1.0.1+2`n"
    Write-Fixture '电脑软件/pubspec.lock' "packages: {}`n"
    Write-Fixture '电脑软件/core-build.json' '{"schemaVersion":1,"product":"sohun-core-preview","signedRelease":false}'
    Write-Fixture '电脑软件/scripts/Test-CoreSource.ps1' ([IO.File]::ReadAllText((Join-Path $repoRoot '电脑软件/scripts/Test-CoreSource.ps1')))
    $files = @(Get-ChildItem -LiteralPath $stage -File -Recurse | ForEach-Object {
        [ordered]@{path=$_.FullName.Substring($stage.Length + 1).Replace('\','/'); bytes=$_.Length; sha256=(Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()}
    })
    $manifest = [ordered]@{schemaVersion=1; purpose='Public source export; isolated release boundary fixture'; coreAssets=$true; fileCount=$files.Count; files=$files}
    Write-Fixture 'PUBLIC_SOURCE_EXPORT.json' ($manifest | ConvertTo-Json -Depth 8)
    $env:SOHUN_ANDROID_SIGNING_PROPERTIES = $null
    $env:SOHUN_ANDROID_SIGNING_CERT_SHA256 = $null
    Reject { & $packager -SourceStage $stage -Target Android -PublicRelease -OutputDirectory $output } 'requires an explicit version tag'
    Reject { & $packager -SourceStage $stage -Target Android -PublicRelease -ExpectedTag 'core-v1.0.1+2' -OutputDirectory $output } 'expected v1\.0\.1\+2'
    Reject { & $packager -SourceStage $stage -Target Android -ExpectedTag 'v1.0.1+2' -OutputDirectory $output } 'expected core-v1\.0\.1\+2'
    Reject { & $packager -SourceStage $stage -Target Android -PublicRelease -ExpectedTag 'v1.0.1+2' -OutputDirectory $output } 'requires SOHUN_ANDROID_SIGNING_PROPERTIES'
    $env:SOHUN_ANDROID_SIGNING_PROPERTIES = Join-Path $repoRoot '.deploy/nonexistent-release-key.properties'
    Reject { & $packager -SourceStage $stage -Target Android -PublicRelease -ExpectedTag 'v1.0.1+2' -OutputDirectory $output } 'outside the repository and sanitized export'
    $properties = Join-Path $fixtureRoot 'key.properties'
    $keystore = Join-Path $fixtureRoot 'fixture.jks'
    [IO.File]::WriteAllText($keystore, 'not-a-real-key')
    [IO.File]::WriteAllText($properties, "storeFile=$($keystore.Replace('\','/'))`nstorePassword=fixture`nkeyAlias=fixture`nkeyPassword=fixture`n")
    $env:SOHUN_ANDROID_SIGNING_PROPERTIES = $properties
    Reject { & $packager -SourceStage $stage -Target Android -PublicRelease -ExpectedTag 'v1.0.1+2' -OutputDirectory $output } 'requires the expected SOHUN_ANDROID_SIGNING_CERT_SHA256'
    $env:SOHUN_ANDROID_SIGNING_CERT_SHA256 = 'invalid-fingerprint'
    Reject { & $packager -SourceStage $stage -Target Android -PublicRelease -ExpectedTag 'v1.0.1+2' -OutputDirectory $output } 'requires the expected SOHUN_ANDROID_SIGNING_CERT_SHA256'
    [IO.File]::WriteAllText($properties, "storeFile=relative.jks`nstorePassword=fixture`nkeyAlias=fixture`nkeyPassword=fixture`n")
    $env:SOHUN_ANDROID_SIGNING_CERT_SHA256 = 'a' * 64
    Reject { & $packager -SourceStage $stage -Target Android -PublicRelease -ExpectedTag 'v1.0.1+2' -OutputDirectory $output } 'absolute path using forward slashes'
    Reject { & $installer -PublicRelease } 'pass -Core -Product Personal'
    Reject { & $installer -PublicRelease -Core -Product Farm } 'pass -Core -Product Personal'
    Write-Host "$passed public release entry-point boundary checks passed."
    $global:LASTEXITCODE = 0
} finally {
    $env:SOHUN_ANDROID_SIGNING_PROPERTIES = $priorProperties
    $env:SOHUN_ANDROID_SIGNING_CERT_SHA256 = $priorFingerprint
    Set-Location $originalLocation
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^sohun-public-release-check-[0-9a-f]{32}$') { throw 'Unexpected fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
