# Builds an explicitly unsigned core preview from a fixed, sanitized snapshot.
[CmdletBinding()]
param(
    [ValidateSet('Windows', 'Android', 'All')][string]$Target = 'All',
    [string]$SourceStage = '',
    [string]$OutputDirectory = '',
    [string]$ApiBaseUrl = 'https://api.sohun.top',
    [string]$ExpectedTag = '',
    [switch]$Installer,
    [switch]$RunTests
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$originalLocation = Get-Location
if ([string]::IsNullOrWhiteSpace($SourceStage)) {
    $export = & (Join-Path $PSScriptRoot 'export_public_source.ps1') -CoreAssets
    $SourceStage = $export.Destination
}
$SourceStage = [IO.Path]::GetFullPath($SourceStage)
$sourceVerification = & (Join-Path $PSScriptRoot 'verify_public_source.ps1') -SourceStage $SourceStage
$sourceClient = Join-Path $SourceStage '电脑软件'
& (Join-Path $sourceClient 'scripts/Test-CoreSource.ps1') -ProjectRoot $sourceClient
$sourceManifest = Join-Path $SourceStage 'PUBLIC_SOURCE_EXPORT.json'
$exportManifest = Get-Content -LiteralPath $sourceManifest -Raw -Encoding UTF8 | ConvertFrom-Json
if ($exportManifest.coreAssets -ne $true) { throw 'Only an explicitly sanitized core snapshot can build a core preview.' }
$versionMatch = Select-String -LiteralPath (Join-Path $sourceClient 'pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$' | Select-Object -First 1
if ($null -eq $versionMatch) { throw 'Unable to read the core preview version.' }
$semanticVersion = $versionMatch.Matches[0].Groups[1].Value
$buildNumber = $versionMatch.Matches[0].Groups[2].Value
$packageVersion = "$semanticVersion-$buildNumber"
$releaseTag = "core-v$semanticVersion+$buildNumber"
if (-not [string]::IsNullOrWhiteSpace($ExpectedTag) -and $ExpectedTag.Trim() -ne $releaseTag) {
    throw "Core preview tag must match pubspec.yaml: expected $releaseTag, received $($ExpectedTag.Trim())."
}
$sessionName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $repoRoot "artifacts/core-preview/$sessionName"
}
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory)
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Use a new output directory; existing release artifacts are preserved.' }
$buildBase = [IO.Path]::GetFullPath([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData))
$buildRoot = [IO.Path]::GetFullPath((Join-Path $buildBase ('sohun_core_' + [Guid]::NewGuid().ToString('N').Substring(0, 12))))
if (-not $buildRoot.StartsWith($buildBase + '\sohun_core_', [StringComparison]::OrdinalIgnoreCase) -or $buildRoot -match '[^\x00-\x7F]') {
    throw 'The native core build requires a fresh ASCII staging path below LocalApplicationData.'
}
if (Test-Path -LiteralPath $buildRoot) { throw 'The selected build stage already exists.' }
New-Item -ItemType Directory -Path $buildRoot | Out-Null
& robocopy $sourceClient $buildRoot /E /XJ /XD .git .dart_tool build dist .gradle .kotlin node_modules ephemeral /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -gt 7) { throw "Unable to copy the core build snapshot (robocopy $LASTEXITCODE)." }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$artifacts = [Collections.Generic.List[object]]::new()
function Add-Artifact([string]$Path, [string]$Kind, [string]$Signing) {
    $item = Get-Item -LiteralPath $Path
    $artifacts.Add([ordered]@{ file = $item.Name; kind = $Kind; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant(); signing = $Signing })
}
try {
    Set-Location $buildRoot
    flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Core dependencies did not match the exported lockfile.' }
    if ($RunTests) {
        & (Join-Path $SourceStage 'scripts/analyze_dart.ps1') -ProjectPath $buildRoot
        flutter test --no-pub --concurrency=2 --dart-define=SOHUN_CORE_BUILD=true
        if ($LASTEXITCODE -ne 0) { throw 'Core snapshot tests failed.' }
    }
    if ($Target -in @('Windows', 'All')) {
        & (Join-Path $buildRoot 'scripts/build_windows.ps1') -Configuration Release -Product Personal -Core -ApiBaseUrl $ApiBaseUrl
        $bundle = Join-Path $buildRoot 'dist/windows/core-preview/Release'
        & (Join-Path $buildRoot 'scripts/Test-WindowsRuntimeBundle.ps1') -BundleDirectory $bundle
        & (Join-Path $buildRoot 'scripts/Test-CoreBundle.ps1') -BundlePath $bundle
        $signature = Get-AuthenticodeSignature -LiteralPath (Join-Path $bundle 'sohun.exe')
        if ($signature.Status -ne 'NotSigned') { throw 'Expected an unsigned core preview; review the unexpected executable signature before packaging.' }
        $notice = @'
sohun core preview / 核心预览版

This Windows build is a prerelease and is NOT Authenticode signed.
本 Windows 包是未完成实机验收的核心预览版，没有 Windows 发布者签名。
完整解压后运行 sohun.exe；请保留所有 DLL、data 与运行库清单。

CUID/FUID：可反复使用的耗材资料卡；明确确认数量/净重后入库，按实物记录余量与消耗。
NTAG213：独立设备状态、故障与维护工作台，不进入耗材库存。
不附带厂商卡片、密钥、签名模板；标签兼容性和 AMS 路径仍需真实设备验收。

本包不含 Bambu 私有网络组件/证书/账户与视频桥、厂商图标/预设、FFmpeg/libmpv、
离线厂商故障文案库与预置校准模型。相关厂商集成不可用；局域网连接和核心库存功能保留。
没有离线文案时显示原始故障码并可在线查询官方说明。用户可以使用自己的切片软件/模型。
完整正式发行版仍须满足原有资源许可及签名门禁；本包不是其替代证明。
'@
        [IO.File]::WriteAllText((Join-Path $bundle 'CORE_PREVIEW_README.txt'), $notice + "`n", [Text.UTF8Encoding]::new($true))
        Copy-Item -LiteralPath (Join-Path $SourceStage 'LICENSE') -Destination (Join-Path $bundle 'LICENSE.txt')
        Copy-Item -LiteralPath (Join-Path $buildRoot 'THIRD_PARTY_NOTICES.md') -Destination $bundle
        $zipPath = Join-Path $OutputDirectory "sohun-core-preview-$packageVersion-windows-x64.zip"
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
        & (Join-Path $buildRoot 'scripts/Test-CoreBundle.ps1') -BundlePath $zipPath
        Add-Artifact $zipPath 'windows-portable' 'NotSigned (Authenticode)'
        if ($Installer) {
            & (Join-Path $buildRoot 'scripts/build_installer.ps1') -Product Personal -Core -ReleaseDir $bundle
            $setup = Join-Path $buildRoot "dist/installer/sohun-core-preview-setup-$packageVersion-windows-x64.exe"
            if ((Get-AuthenticodeSignature -LiteralPath $setup).Status -ne 'NotSigned') { throw 'Unexpected core installer signature.' }
            $publishedSetup = Join-Path $OutputDirectory ([IO.Path]::GetFileName($setup))
            Copy-Item -LiteralPath $setup -Destination $publishedSetup
            Add-Artifact $publishedSetup 'windows-installer' 'NotSigned (Authenticode)'
        }
    }
    if ($Target -in @('Android', 'All')) {
        $androidBuildFlags = @{}
        if ($RunTests) { $androidBuildFlags.RunNativeTests = $true }
        & (Join-Path $buildRoot 'scripts/build_android.ps1') -Configuration Debug -Core -ApiBaseUrl $ApiBaseUrl @androidBuildFlags
        $apk = Join-Path $buildRoot 'build/app/outputs/flutter-apk/app-debug.apk'
        & (Join-Path $buildRoot 'scripts/Test-CoreBundle.ps1') -BundlePath $apk
        $publishedApk = Join-Path $OutputDirectory "sohun-core-preview-$packageVersion-android-debug.apk"
        Copy-Item -LiteralPath $apk -Destination $publishedApk
        Add-Artifact $publishedApk 'android-debug-apk' 'Android debug certificate; not a production signing identity'
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        product = 'sohun-core-preview'
        prerelease = $true
        hardwareVerified = $false
        automatedTestsRun = [bool]$RunTests
        version = "$semanticVersion+$buildNumber"
        releaseTag = $releaseTag
        apiBaseUrl = $ApiBaseUrl
        sourceExportSha256 = $sourceVerification.ManifestSha256
        coreDefine = 'SOHUN_CORE_BUILD=true'
        artifacts = @($artifacts.ToArray())
    }
    if (Get-Command git -ErrorAction SilentlyContinue) {
        $sourceCommit = (& git -C $repoRoot rev-parse --verify HEAD 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($sourceCommit)) {
            $manifest['sourceCommit'] = $sourceCommit.Trim().ToLowerInvariant()
        }
    }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'core-preview-manifest.json'), ($manifest | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
    $checksumLines = @($artifacts | ForEach-Object { "$($_.sha256)  $($_.file)" })
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'), ($checksumLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ SourceStage = $SourceStage; BuildRoot = $buildRoot; OutputDirectory = $OutputDirectory; Artifacts = $artifacts.Count }
} finally { Set-Location $originalLocation }
