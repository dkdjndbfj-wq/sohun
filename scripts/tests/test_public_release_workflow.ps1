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

function Get-WorkflowScriptText([string]$Name) {
    $pattern = '(?ms)^      - name: ' + [regex]::Escape($Name) + '\r?\n.*?^        run: \|\r?\n(?<code>(?:^          [^\r\n]*\r?\n|^\r?\n)*)'
    $match = [regex]::Match($workflow, $pattern)
    if (-not $match.Success) { throw "Workflow script not found: $Name" }
    $code = [regex]::Replace($match.Groups['code'].Value, '(?m)^          ', '')
    return $code
}
function Get-WorkflowScript([string]$Name) {
    return [scriptblock]::Create((Get-WorkflowScriptText $Name))
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
    $result = Invoke-NotesScript
    if ([string]::IsNullOrWhiteSpace($ExpectedFailure)) {
        if ($result.exitCode -ne 0) { throw "Release-note script failed: $($result.output)" }
    } elseif ($result.exitCode -eq 0 -or $result.output -notmatch $ExpectedFailure) {
        throw "Expected release-note rejection: $ExpectedFailure; received $($result.output)"
    }
    $script:passed++
}
function Invoke-NotesScript {
    # Run the real GitHub inline script from a UTF-8/no-BOM file in the selected
    # shell. ScriptBlock.Create would bypass the encoding failure we must catch.
    $log = Join-Path $fixtureRoot 'notes-process.log'
    $priorPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $notesShell -NoLogo -NoProfile -NonInteractive -File $renderNotesPath *> $log
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $priorPreference }
    return @{exitCode=$exitCode;output=[IO.File]::ReadAllText($log)}
}
function Read-RenderedNotes {
    $path = Join-Path $env:RUNNER_TEMP 'sohun-public-release-notes.md'
    $bytes = [IO.File]::ReadAllBytes($path)
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        throw 'Rendered release notes must use UTF-8 without BOM.'
    }
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}
try {
    $verifyRelease = Get-WorkflowScript 'Verify final release identity and checksums'
    $notesStep = [regex]::Match($workflow, '(?ms)^      - name: Prepare illustrated release notes\r?\n(?<step>.*?)(?=^      - |\z)')
    if (-not $notesStep.Success -or $notesStep.Groups['step'].Value -notmatch '(?m)^        shell: pwsh\s*$') {
        throw 'Chinese release-note inline scripts must execute with pwsh.'
    }
    $passed++
    $verifiedPosition = $workflow.IndexOf('      - name: Verify final release identity and checksums')
    $uploadPosition = $workflow.IndexOf('      - uses: actions/upload-artifact@v4')
    $notesPosition = $notesStep.Index
    $publishPosition = $workflow.IndexOf('      - name: Publish the public release')
    if ($verifiedPosition -lt 0 -or $uploadPosition -le $verifiedPosition -or
        $notesPosition -le $uploadPosition -or $publishPosition -le $notesPosition -or
        $workflow -notmatch '(?ms)uses: actions/upload-artifact@v4\r?\n        with:\r?\n          name: sohun-public-release\r?\n          path: artifacts/public-release-ci/\*\r?\n          if-no-files-found: error') {
        throw 'Only verified release artifacts may be preserved before note rendering and publication.'
    }
    $passed++
    $notesShell = (Get-Command pwsh -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
    $renderNotesPath = Join-Path $fixtureRoot 'github-inline-release-notes.ps1'
    Write-Text $renderNotesPath (Get-WorkflowScriptText 'Prepare illustrated release notes')
    $inlineBytes = [IO.File]::ReadAllBytes($renderNotesPath)
    if ($inlineBytes[0] -eq 0xEF -and $inlineBytes[1] -eq 0xBB -and $inlineBytes[2] -eq 0xBF) {
        throw 'Inline-script fixture must reproduce GitHub UTF-8 without BOM.'
    }
    $passed++
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
    $rendered = Read-RenderedNotes
    if (-not $rendered.Contains('https://raw.githubusercontent.com/release-owner/sohun/v1.0.2%2B4/docs/previews/mobile-home.png') -or
        -not $rendered.Contains('本次发布安装包：Android。') -or $rendered.Contains('](../previews/')) {
        throw 'Release images were not pinned to the exact version tag.'
    }
    $passed++
    Check-Notes '![Missing](../previews/missing.png)' 'image is missing'
    Check-Notes '![Private](../../../../outside.png)' 'outside the public source'
    Check-Notes '![Local](file:///private.png)' 'repository-relative paths or HTTPS'
    Check-Notes '![Remote](https://example.invalid/preview.png)'

    # Use the actual illustrated notes, including all eight pinned HTTPS images,
    # to catch Chinese corruption or URL changes in the child-shell boundary.
    $pubspec = [IO.File]::ReadAllText((Join-Path $repoRoot '电脑软件/pubspec.yaml'))
    $versionMatch = [regex]::Match($pubspec, '(?m)^version:\s*(?<version>\d+\.\d+\.\d+\+\d+)\s*$')
    if (-not $versionMatch.Success) { throw 'The current release version was not found in pubspec.' }
    $currentVersion = $versionMatch.Groups['version'].Value
    $currentNotesRelative = 'docs/releases/' + $currentVersion.Replace('+', '-') + '.md'
    $actualNotes = [IO.File]::ReadAllText((Join-Path $repoRoot $currentNotesRelative))
    $env:GITHUB_REF_NAME = 'v' + $currentVersion
    $env:GITHUB_REPOSITORY = 'dkdjndbfj-wq/sohun'
    $notesPath = Join-Path $notesRoot $currentNotesRelative
    Check-Notes $actualNotes
    $rendered = Read-RenderedNotes
    $images = @([regex]::Matches($rendered, '<img src="(?<url>https://[^"]+)"'))
    $expectedImages = @('reader-light.png', 'reader-dark.png', 'read-dialog-light.png', 'new-card-dialog-dark.png',
        'inventory-light.png', 'inventory-dark.png', 'navigation-light.png', 'navigation-dark.png')
    $expectedImagePrefix = 'https://raw.githubusercontent.com/' + $env:GITHUB_REPOSITORY + '/' +
        [Uri]::EscapeDataString($env:GITHUB_REF_NAME) + '/docs/images/mobile-1.0.2/'
    $urls = @($images | ForEach-Object { $_.Groups['url'].Value })
    if (-not $rendered.StartsWith($actualNotes, [StringComparison]::Ordinal) -or $images.Count -ne 8 -or
        @($expectedImages | Where-Object { ($expectedImagePrefix + $_) -cnotin $urls }).Count -gt 0 -or
        -not $rendered.Contains('本次发布安装包：Android。完整文件哈希与签名状态见附件')) {
        throw 'Actual Chinese release notes and eight exact-tag preview URLs must survive UTF-8 script execution.'
    }
    $passed++

    $env:GITHUB_REF_NAME = 'v1.0.3+5'
    foreach ($target in @('Android', 'Windows', 'All')) {
        $env:SOHUN_TARGET = $target
        $result = Invoke-NotesScript
        if ($result.exitCode -ne 0) { throw "Release-note fallback script failed: $($result.output)" }
        $fallback = Read-RenderedNotes
        $expectedPlatforms = if ($target -eq 'All') { 'Android / Windows' } else { $target }
        if (-not $fallback.Contains('sohun v1.0.3+5') -or
            -not $fallback.Contains("${expectedPlatforms} 公开核心版。") -or
            -not $fallback.Contains("本次发布安装包：${expectedPlatforms}。") -or
            -not $fallback.Contains('真机 NFC / AMS 兼容性以设备实测为准。') -or
            ($target -eq 'Android' -and (-not $fallback.Contains('Android 使用长期发行密钥签名。') -or $fallback.Contains('Windows'))) -or
            ($target -eq 'Windows' -and (-not $fallback.Contains('Windows 包未进行 Authenticode 发布者签名。') -or $fallback.Contains('Android')))) {
            throw 'Release-note fallback must retain Chinese and describe the selected version and target.'
        }
        $passed++
    }
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
