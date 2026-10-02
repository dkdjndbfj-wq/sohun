# Exercise the actual workflow verification and note-rendering scripts without
# credentials, SDK builds or GitHub mutations.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$workflow = [IO.File]::ReadAllText((Join-Path $repoRoot '.github/workflows/public-release.yml'))
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sohun-release-workflow-' + [guid]::NewGuid().ToString('N'))
$originalLocation = Get-Location
$environmentNames = @('SOHUN_TARGET', 'EXPECTED_ANDROID_CERT', 'GITHUB_REF_NAME', 'GITHUB_SHA', 'GITHUB_REPOSITORY', 'RUNNER_TEMP')
$originalEnvironment = @{}
foreach ($name in $environmentNames) { $originalEnvironment[$name] = [Environment]::GetEnvironmentVariable($name) }
$passed = 0

function Get-WorkflowScript([string]$Name) {
    $pattern = '(?ms)^      - name: ' + [regex]::Escape($Name) + '\r?\n.*?^        run: \|\r?\n(?<code>(?:^          [^\r\n]*\r?\n|^\r?\n)*)'
    $match = [regex]::Match($workflow, $pattern)
    if (-not $match.Success) { throw "Workflow script not found: $Name" }
    $code = [regex]::Replace($match.Groups['code'].Value, '(?m)^          ', '')
    return [scriptblock]::Create($code)
}
function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}
function New-Case([string]$Target) {
    $root = Join-Path $fixtureRoot ([guid]::NewGuid().ToString('N'))
    $output = Join-Path $root 'artifacts/public-release-ci'
    $artifacts = @()
    $entries = @()
    if ($Target -in @('Windows', 'All')) {
        $entries += @{file='sohun-1.0.2-4-windows-x64.zip';kind='windows-portable';signing='WindowsNotSigned'}
        $entries += @{file='sohun-setup-1.0.2-4-windows-x64.exe';kind='windows-installer';signing='WindowsNotSigned'}
    }
    if ($Target -in @('Android', 'All')) {
        $entries += @{file='sohun-1.0.2-4-android.apk';kind='android-release-apk';signing='AndroidReleaseSigned';certificateSha256=('a' * 64)}
    }
    foreach ($entry in $entries) {
        $path = Join-Path $output $entry.file
        Write-Text $path ('isolated artifact fixture: ' + $entry.file)
        $entry.bytes = (Get-Item -LiteralPath $path).Length
        $entry.sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $artifacts += $entry
    }
    $manifest = @{
        product='sohun-core';prerelease=$false;releaseTag='v1.0.2+4';version='1.0.2+4';sourceCommit=('b' * 40)
        coreDefine='SOHUN_CORE_BUILD=true';sourceExportSha256=('c' * 64)
        windowsSigning=$(if ($Target -in @('Windows', 'All')) {'WindowsNotSigned'} else {'NotBuilt'})
        androidSigning=$(if ($Target -in @('Android', 'All')) {'AndroidReleaseSigned'} else {'NotBuilt'})
        androidDebuggable=$(if ($Target -in @('Android', 'All')) {$false} else {$null})
        androidSigningCertificateSha256=$(if ($Target -in @('Android', 'All')) {('a' * 64)} else {$null})
        artifacts=$artifacts
    }
    return @{root=$root;output=$output;manifest=$manifest;target=$Target}
}
function Check-Case($Case, [string]$ExpectedFailure = '', [switch]$CorruptChecksums) {
    Set-Location $Case.root
    $env:SOHUN_TARGET = $Case.target
    Write-Text (Join-Path $Case.output 'release-manifest.json') ($Case.manifest | ConvertTo-Json -Depth 8)
    $checksums = @($Case.manifest.artifacts | ForEach-Object { "$($_.sha256)  $($_.file)" }) -join "`n"
    if ($CorruptChecksums) { $checksums = 'incorrect checksum list' }
    Write-Text (Join-Path $Case.output 'SHA256SUMS.txt') ($checksums + "`n")
    $caught = $null
    try { & $verifyRelease | Out-Null } catch { $caught = $_ }
    if ([string]::IsNullOrWhiteSpace($ExpectedFailure)) {
        if ($null -ne $caught) { throw $caught }
    } elseif ($null -eq $caught -or $caught.ToString() -notmatch $ExpectedFailure) {
        throw "Expected workflow rejection: $ExpectedFailure; received $caught"
    }
    $script:passed++
}
function Check-Notes([string]$Text, [string]$ExpectedFailure = '') {
    Write-Text $notesPath $Text
    $caught = $null
    try { & $renderNotes | Out-Null } catch { $caught = $_ }
    if ([string]::IsNullOrWhiteSpace($ExpectedFailure)) {
        if ($null -ne $caught) { throw $caught }
    } elseif ($null -eq $caught -or $caught.ToString() -notmatch $ExpectedFailure) {
        throw "Expected release-note rejection: $ExpectedFailure; received $caught"
    }
    $script:passed++
}
try {
    $verifyRelease = Get-WorkflowScript 'Verify final release identity and checksums'
    $renderNotes = Get-WorkflowScript 'Prepare illustrated release notes'
    $env:EXPECTED_ANDROID_CERT = 'a' * 64
    $env:GITHUB_REF_NAME = 'v1.0.2+4'
    $env:GITHUB_SHA = 'b' * 40
    $env:GITHUB_REPOSITORY = 'release-owner/sohun'
    $env:RUNNER_TEMP = Join-Path $fixtureRoot 'runner-temp'
    New-Item -ItemType Directory -Path $env:RUNNER_TEMP -Force | Out-Null

    foreach ($target in @('Android', 'Windows', 'All')) { Check-Case (New-Case $target) }
    $case = New-Case 'Android'; $case.manifest.androidDebuggable = $true
    Check-Case $case 'Android signing or debuggability'
    $case = New-Case 'Android'; $case.manifest.androidSigningCertificateSha256 = 'd' * 64
    Check-Case $case 'Android signing or debuggability'
    $case = New-Case 'Android'; $case.manifest.artifacts[0].signing = 'AndroidDebugSigned'
    Check-Case $case 'artifact signing identity'
    $case = New-Case 'Android'; $case.manifest.artifacts[0].certificateSha256 = 'd' * 64
    Check-Case $case 'artifact signing identity'
    $case = New-Case 'Android'; $case.manifest.artifacts[0].sha256 = '0' * 64
    Check-Case $case 'artifact checksum'
    $case = New-Case 'Android'; $case.manifest.artifacts[0].bytes++
    Check-Case $case 'artifact checksum'
    $case = New-Case 'Android'; $case.manifest.sourceCommit = 'd' * 40
    Check-Case $case 'manifest identity'
    $case = New-Case 'Android'; $case.manifest.version = '1.0.2+3'
    Check-Case $case 'manifest identity'
    $case = New-Case 'Android'; $case.manifest.windowsSigning = 'WindowsNotSigned'
    Check-Case $case 'Windows signing state'
    $case = New-Case 'Windows'; $case.manifest.androidDebuggable = $false
    Check-Case $case 'Android signing state'
    $case = New-Case 'All'; $case.manifest.artifacts[1] = $case.manifest.artifacts[0]
    Check-Case $case 'duplicate public artifact'
    $case = New-Case 'Android'; $case.manifest.artifacts += $case.manifest.artifacts[0]
    Check-Case $case 'artifact count'
    $case = New-Case 'Android'
    Write-Text (Join-Path $case.output 'unexpected.txt') 'not a release attachment'
    Check-Case $case 'Unexpected files'
    Check-Case (New-Case 'Android') 'checksum list' -CorruptChecksums

    $notesRoot = Join-Path $fixtureRoot 'notes'
    $notesPath = Join-Path $notesRoot 'docs/releases/1.0.2-4.md'
    Write-Text (Join-Path $notesRoot 'docs/previews/mobile-home.png') 'isolated image fixture'
    Set-Location $notesRoot
    $env:SOHUN_TARGET = 'Android'
    Check-Notes "# sohun`n`n![手机版](../previews/mobile-home.png)`n"
    $rendered = [IO.File]::ReadAllText((Join-Path $env:RUNNER_TEMP 'sohun-public-release-notes.md'))
    if (-not $rendered.Contains('https://raw.githubusercontent.com/release-owner/sohun/v1.0.2%2B4/docs/previews/mobile-home.png') -or
        -not $rendered.Contains('本次发布安装包：Android。') -or $rendered.Contains('](../previews/')) {
        throw 'Release images were not pinned to the exact version tag.'
    }
    $passed++
    Check-Notes '![Missing](../previews/missing.png)' 'image is missing'
    Check-Notes '![Private](../../../../outside.png)' 'outside the public source'
    Check-Notes '![Local](file:///private.png)' 'repository-relative paths or HTTPS'
    Check-Notes '![Remote](https://example.invalid/preview.png)'
    $env:GITHUB_REF_NAME = 'v1.0.3+5'
    & $renderNotes
    $fallback = [IO.File]::ReadAllText((Join-Path $env:RUNNER_TEMP 'sohun-public-release-notes.md'))
    if (-not $fallback.Contains('sohun v1.0.3+5') -or -not $fallback.Contains('Android') -or $fallback.Contains('Windows')) {
        throw 'Release-note fallback does not describe the selected version and target.'
    }
    $passed++
    Write-Host "$passed public release workflow checks passed."
    $global:LASTEXITCODE = 0
} finally {
    Set-Location $originalLocation
    foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $originalEnvironment[$name]) }
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolved) -notmatch '^sohun-release-workflow-[0-9a-f]{32}$') { throw 'Unexpected workflow fixture cleanup path.' }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
