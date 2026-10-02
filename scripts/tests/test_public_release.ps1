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
$priorPath = $env:PATH
$environmentNames = @('ANDROID_SDK_ROOT', 'ANDROID_HOME', 'GITHUB_ACTIONS', 'GITHUB_SHA', 'GITHUB_REF_NAME', 'SOHUN_TARGET', 'EXPECTED_ANDROID_CERT', 'SOHUN_RELEASE_FIXTURE_GIT_EXIT')
$originalEnvironment = @{}
foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$originalLocation = Get-Location
$completedBuildRoots = [Collections.Generic.List[string]]::new()
$fixtureCommit = 'b' * 40
$passed = 0
function Write-Fixture([string]$Relative, [string]$Text) {
    $path = Join-Path $stage $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
}
function Reject([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    $global:LASTEXITCODE = 37
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.ToString() -notmatch $Pattern) { throw "Expected release rejection: $Pattern" }
    if ($global:LASTEXITCODE -eq 0) { throw 'Rejected release must not normalize the caller exit code.' }
    if (Test-Path -LiteralPath $output) { throw 'Rejected release unexpectedly created artifact output.' }
    $script:passed++
}
try {
    Write-Fixture '电脑软件/pubspec.yaml' "name: release_boundary_fixture`nversion: 1.0.1+2`n"
    Write-Fixture '电脑软件/pubspec.lock' "packages: {}`n"
    Write-Fixture '电脑软件/core-build.json' '{"schemaVersion":1,"product":"sohun-core-preview","signedRelease":false}'
    Write-Fixture '电脑软件/android/.gitkeep' ''
    Write-Fixture '电脑软件/scripts/Test-CoreSource.ps1' ([IO.File]::ReadAllText((Join-Path $repoRoot '电脑软件/scripts/Test-CoreSource.ps1')))
    Write-Fixture '电脑软件/scripts/Test-CoreBundle.ps1' ([IO.File]::ReadAllText((Join-Path $repoRoot '电脑软件/scripts/Test-CoreBundle.ps1')))
    # Replace only the SDK build in this isolated snapshot. The real source,
    # bundle, artifact hash and manifest checks still execute in the packager.
    Write-Fixture '电脑软件/scripts/build_android.ps1' @'
[CmdletBinding()]
param([string]$Configuration, [switch]$Core, [string]$ApiBaseUrl, [switch]$RunNativeTests)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$payload = Join-Path $projectRoot 'build/fixture-payload'
New-Item -ItemType Directory -Path $payload -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $payload 'AndroidManifest.xml'), 'isolated SDK fixture')
$apk = Join-Path $projectRoot "build/app/outputs/flutter-apk/app-$($Configuration.ToLowerInvariant()).apk"
New-Item -ItemType Directory -Path (Split-Path -Parent $apk) -Force | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem
[IO.Compression.ZipFile]::CreateFromDirectory($payload, $apk)
$global:LASTEXITCODE = 1
'@
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
    $tools = Join-Path $fixtureRoot 'tools'
    New-Item -ItemType Directory -Path $tools | Out-Null
    [IO.File]::WriteAllText((Join-Path $tools 'flutter.cmd'), "@echo off`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    [IO.File]::WriteAllText((Join-Path $tools 'git.cmd'), "@echo off`r`necho $fixtureCommit`r`nexit /b %SOHUN_RELEASE_FIXTURE_GIT_EXIT%`r`n", [Text.Encoding]::ASCII)
    $env:SOHUN_RELEASE_FIXTURE_GIT_EXIT = '1'
    $env:PATH = $tools + [IO.Path]::PathSeparator + $priorPath
    # The optional commit lookup may leave a nonzero native exit code even
    # after all required packaging gates pass, just as a clean rg scan can.
    $global:LASTEXITCODE = 1
    $result = & $packager -SourceStage $stage -Target Android -OutputDirectory $output
    $completedBuildRoots.Add($result.BuildRoot)
    if ($global:LASTEXITCODE -ne 0) { throw 'Successful packaging must clear the caller exit code for the GitHub PowerShell wrapper.' }
    if ($result.Artifacts -ne 1 -or -not (Test-Path -LiteralPath (Join-Path $output 'core-preview-manifest.json'))) {
        throw 'The isolated successful packaging path did not finish its artifact and manifest checks.'
    }
    $passed++
    # Exercise the actual public release signing and manifest path using only
    # isolated native SDK tools. In particular, git must complete before its
    # exit code is read, even when the caller starts with a residual code 1.
    $sdkTools = Join-Path $fixtureRoot 'sdk/build-tools/fixture'
    New-Item -ItemType Directory -Path $sdkTools -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $sdkTools 'apksigner.bat'), "@echo off`r`necho Signer #1 certificate DN: CN=sohun Release`r`necho Signer #1 certificate SHA-256 digest: $('a' * 64)`r`nexit /b 0`r`n", [Text.Encoding]::ASCII)
    Add-Type -TypeDefinition @'
using System;
public class SohunReleaseFixtureAapt {
    public static int Main(string[] args) {
        Console.WriteLine("package: name='top.sohun.consumable_tracker' versionCode='2' versionName='1.0.1'");
        return 0;
    }
}
'@ -OutputAssembly (Join-Path $sdkTools 'aapt.exe') -OutputType ConsoleApplication
    $env:ANDROID_SDK_ROOT = Join-Path $fixtureRoot 'sdk'
    $env:ANDROID_HOME = $null
    $env:SOHUN_RELEASE_FIXTURE_GIT_EXIT = '0'
    $env:GITHUB_ACTIONS = 'true'
    $env:GITHUB_SHA = $fixtureCommit
    $env:GITHUB_REF_NAME = 'v1.0.1+2'
    $env:SOHUN_TARGET = 'Android'
    $env:EXPECTED_ANDROID_CERT = 'a' * 64
    [IO.File]::WriteAllText($properties, "storeFile=$($keystore.Replace('\','/'))`nstorePassword=fixture`nkeyAlias=fixture`nkeyPassword=fixture`n")
    $identityCases = @(
        @{ gitExit = '19'; sha = $fixtureCommit; pattern = 'requires a valid source Git commit' },
        @{ gitExit = '0'; sha = 'invalid'; pattern = 'requires a valid GITHUB_SHA' },
        @{ gitExit = '0'; sha = ('c' * 40); pattern = 'does not match GITHUB_SHA' }
    )
    foreach ($case in $identityCases) {
        $env:SOHUN_RELEASE_FIXTURE_GIT_EXIT = $case.gitExit
        $env:GITHUB_SHA = $case.sha
        $identityOutput = Join-Path $fixtureRoot ('identity-failure-' + [guid]::NewGuid().ToString('N'))
        $global:LASTEXITCODE = 37
        $caught = $null
        try { & $packager -SourceStage $stage -Target Android -PublicRelease -ExpectedTag $env:GITHUB_REF_NAME -OutputDirectory $identityOutput | Out-Null } catch { $caught = $_ }
        if ($null -eq $caught -or $caught.ToString() -notmatch $case.pattern -or (Test-Path -LiteralPath $identityOutput)) {
            throw "Expected source identity rejection before building: $($case.pattern)"
        }
        if ($case.gitExit -eq '19' -and $global:LASTEXITCODE -ne 19) { throw 'A failed native Git query must not be normalized.' }
        $passed++
    }
    $env:SOHUN_RELEASE_FIXTURE_GIT_EXIT = '0'
    $env:GITHUB_SHA = $fixtureCommit
    $releaseRoot = Join-Path $fixtureRoot 'public-success'
    $releaseOutput = Join-Path $releaseRoot 'artifacts/public-release-ci'
    $global:LASTEXITCODE = 1
    $release = & $packager -SourceStage $stage -Target Android -PublicRelease -ExpectedTag $env:GITHUB_REF_NAME -OutputDirectory $releaseOutput
    $completedBuildRoots.Add($release.BuildRoot)
    $releaseManifest = Get-Content -LiteralPath (Join-Path $releaseOutput 'release-manifest.json') -Raw | ConvertFrom-Json
    if ($global:LASTEXITCODE -ne 0 -or $releaseManifest.sourceCommit -ne $fixtureCommit -or
        $releaseManifest.version -ne '1.0.1+2' -or $releaseManifest.releaseTag -ne $env:GITHUB_REF_NAME -or
        $releaseManifest.product -ne 'sohun-core' -or $releaseManifest.prerelease -ne $false -or
        $releaseManifest.androidSigningCertificateSha256 -ne $env:EXPECTED_ANDROID_CERT -or
        $releaseManifest.androidSigning -ne 'AndroidReleaseSigned' -or $releaseManifest.androidDebuggable -ne $false) {
        throw "Public packaging identity mismatch: sourceCommit='$($releaseManifest.sourceCommit)', expected='$fixtureCommit', exit=$global:LASTEXITCODE."
    }
    if (Test-Path -LiteralPath (Join-Path $release.BuildRoot 'android/key.properties')) { throw 'Successful public packaging retained its signing properties.' }
    $workflow = [IO.File]::ReadAllText((Join-Path $repoRoot '.github/workflows/public-release.yml'))
    $workflowMatch = [regex]::Match($workflow, '(?ms)^      - name: Verify final release identity and checksums\r?\n.*?^        run: \|\r?\n(?<code>(?:^          [^\r\n]*\r?\n|^\r?\n)*)')
    if (-not $workflowMatch.Success) { throw 'The actual release identity workflow script was not found.' }
    $verification = [scriptblock]::Create([regex]::Replace($workflowMatch.Groups['code'].Value, '(?m)^          ', ''))
    Set-Location $releaseRoot
    & $verification
    Set-Location $originalLocation
    $passed++
    Write-Host "$passed public release entry-point boundary checks passed."
    $global:LASTEXITCODE = 0
} finally {
    $env:SOHUN_ANDROID_SIGNING_PROPERTIES = $priorProperties
    $env:SOHUN_ANDROID_SIGNING_CERT_SHA256 = $priorFingerprint
    $env:PATH = $priorPath
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name]) }
    Set-Location $originalLocation
    foreach ($completedBuildRoot in $completedBuildRoots) {
        $resolvedBuildRoot = [IO.Path]::GetFullPath($completedBuildRoot)
        $buildBase = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
        if (-not $resolvedBuildRoot.StartsWith($buildBase, [StringComparison]::OrdinalIgnoreCase) -or
            (Split-Path -Leaf $resolvedBuildRoot) -notmatch '^sohun_core_[0-9a-f]{12}$') { throw 'Unexpected isolated build cleanup path.' }
        if (Test-Path -LiteralPath $resolvedBuildRoot) { Remove-Item -LiteralPath $resolvedBuildRoot -Recurse -Force }
    }
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($base, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^sohun-public-release-check-[0-9a-f]{32}$') { throw 'Unexpected fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
