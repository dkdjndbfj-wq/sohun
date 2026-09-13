# Builds core previews or explicit public releases from a fixed sanitized snapshot.
[CmdletBinding()]
param(
    [ValidateSet('Windows', 'Android', 'All')][string]$Target = 'All',
    [string]$SourceStage = '',
    [string]$OutputDirectory = '',
    [string]$ApiBaseUrl = 'https://api.sohun.top',
    [string]$ExpectedTag = '',
    [switch]$Installer,
    [switch]$RunTests,
    [switch]$PublicRelease
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$originalLocation = Get-Location
$originalPubHostedUrl = $env:PUB_HOSTED_URL
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
if ($exportManifest.coreAssets -ne $true) { throw 'Only an explicitly sanitized core snapshot can build this product.' }
$versionMatch = Select-String -LiteralPath (Join-Path $sourceClient 'pubspec.yaml') -Pattern '^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$' | Select-Object -First 1
if ($null -eq $versionMatch) { throw 'Unable to read the core preview version.' }
$semanticVersion = $versionMatch.Matches[0].Groups[1].Value
$buildNumber = $versionMatch.Matches[0].Groups[2].Value
$packageVersion = "$semanticVersion-$buildNumber"
$releaseTag = if ($PublicRelease) { "v$semanticVersion+$buildNumber" } else { "core-v$semanticVersion+$buildNumber" }
if ($PublicRelease -and [string]::IsNullOrWhiteSpace($ExpectedTag)) {
    throw 'PublicRelease requires an explicit version tag matching pubspec.yaml.'
}
if (-not [string]::IsNullOrWhiteSpace($ExpectedTag) -and $ExpectedTag.Trim() -ne $releaseTag) {
    throw "Release tag must match pubspec.yaml: expected $releaseTag, received $($ExpectedTag.Trim())."
}
$androidSigningSource = $null
$expectedAndroidCertificateSha256 = $null
if ($PublicRelease -and $Target -in @('Android', 'All')) {
    if ([string]::IsNullOrWhiteSpace($env:SOHUN_ANDROID_SIGNING_PROPERTIES)) {
        throw 'A public Android release requires SOHUN_ANDROID_SIGNING_PROPERTIES outside the source snapshot.'
    }
    $androidSigningSource = [IO.Path]::GetFullPath($env:SOHUN_ANDROID_SIGNING_PROPERTIES)
    foreach ($protectedRoot in @($SourceStage, $repoRoot)) {
        if ($androidSigningSource.StartsWith($protectedRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Android signing properties must stay outside the repository and sanitized export.'
        }
    }
    if (-not (Test-Path -LiteralPath $androidSigningSource -PathType Leaf)) { throw 'Android signing properties were not supplied.' }
    $signingText = [IO.File]::ReadAllText($androidSigningSource)
    foreach ($field in @('keyAlias', 'keyPassword', 'storeFile', 'storePassword')) {
        if ($signingText -notmatch ('(?m)^' + $field + '=\S[^\r\n]*\r?$')) { throw "Android signing properties are missing $field." }
    }
    $storeFileMatch = [regex]::Match($signingText, '(?m)^storeFile=([^\r\n]+)\r?$')
    $storeFile = $storeFileMatch.Groups[1].Value
    if (-not [IO.Path]::IsPathRooted($storeFile) -or $storeFile.Contains('\')) {
        throw 'Android storeFile must be an absolute path using forward slashes.'
    }
    $resolvedKeyStore = [IO.Path]::GetFullPath($storeFile)
    foreach ($protectedRoot in @($SourceStage, $repoRoot)) {
        if ($resolvedKeyStore.StartsWith($protectedRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Android keystore must stay outside the repository and sanitized export.'
        }
    }
    if (-not (Test-Path -LiteralPath $resolvedKeyStore -PathType Leaf)) { throw 'Android release keystore does not exist.' }
    $signingText = $null
    $expectedAndroidCertificateSha256 = ($env:SOHUN_ANDROID_SIGNING_CERT_SHA256 -replace ':|\s', '').ToLowerInvariant()
    if ($expectedAndroidCertificateSha256 -notmatch '^[0-9a-f]{64}$') {
        throw 'Public Android release requires the expected SOHUN_ANDROID_SIGNING_CERT_SHA256 fingerprint.'
    }
}
$sessionName = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $artifactDirectory = if ($PublicRelease) { 'public-release' } else { 'core-preview' }
    $OutputDirectory = Join-Path $repoRoot "artifacts/$artifactDirectory/$sessionName"
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
$temporarySigningFile = Join-Path $buildRoot 'android/key.properties'
$androidCertificateSha256 = $null
function Add-Artifact([string]$Path, [string]$Kind, [string]$Signing, [string]$CertificateSha256 = '') {
    $item = Get-Item -LiteralPath $Path
    $entry = [ordered]@{ file = $item.Name; kind = $Kind; bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant(); signing = $Signing }
    if (-not [string]::IsNullOrWhiteSpace($CertificateSha256)) { $entry['certificateSha256'] = $CertificateSha256 }
    $artifacts.Add($entry)
}
function Invoke-ApkVerificationTool([string]$Tool, [string[]]$Arguments) {
    # Windows PowerShell treats native stderr as ErrorRecords. Capture SDK/JVM
    # warnings and rely on the tool exit code without weakening build errors.
    $priorErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $toolOutput = & $Tool @Arguments 2>&1
        $toolExitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $priorErrorAction }
    if ($toolExitCode -ne 0) { throw "Android artifact verification failed: $([IO.Path]::GetFileName($Tool))." }
    return (($toolOutput | ForEach-Object { $_.ToString() }) -join "`n")
}
try {
    Set-Location $buildRoot
    # Pub treats the registry URL as part of a locked package's identity.
    # Honor the single registry already recorded by this snapshot instead of
    # silently rewriting an otherwise identical set of versions on CI.
    $lockContent = [IO.File]::ReadAllText((Join-Path $buildRoot 'pubspec.lock'))
    $lockedRegistries = @([regex]::Matches($lockContent, '(?m)^\s+url:\s+"(https://[^"\s]+)"\s*$') |
        ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
    if ($lockedRegistries.Count -eq 1) {
        $env:PUB_HOSTED_URL = $lockedRegistries[0]
    }
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
        if ($signature.Status -ne 'NotSigned') { throw 'This core Windows packaging path expects WindowsNotSigned; review the unexpected executable signature.' }
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
        $noticeFile = 'CORE_PREVIEW_README.txt'
        if ($PublicRelease) {
            $noticeFile = 'SOHUN_README.txt'
            $notice = @'
sohun / 个人版

这是 sohun 首个正式公开版本，提供已获授权公开的精简核心功能。
本 Windows 包没有 Authenticode 发布者签名；这是签名状态，不是软件版本状态。
完整解压后运行 sohun.exe；请保留所有 DLL、data 与运行库清单。

CUID/FUID：可重复使用的耗材资料卡；确认数量后按每卷固定 1000 g 入库，
余料保留实际剩余克数，只有大于 30 g 才能继续使用。NTAG213 仅用于设备工作台。
不附带厂商卡片、密钥、签名模板；真实 NFC/AMS 兼容性以设备实测为准。

本包不含 Bambu 私有网络组件/证书/账户与视频桥、厂商图标/预设、FFmpeg/libmpv、
离线厂商故障文案库与预置校准模型；局域网连接和核心库存功能保留。
受限制组件的资源许可边界继续生效；公开核心版不代表闭源组件已获再分发许可。
官网：https://sohun.top
'@
        }
        [IO.File]::WriteAllText((Join-Path $bundle $noticeFile), $notice + "`n", [Text.UTF8Encoding]::new($true))
        Copy-Item -LiteralPath (Join-Path $SourceStage 'LICENSE') -Destination (Join-Path $bundle 'LICENSE.txt')
        Copy-Item -LiteralPath (Join-Path $buildRoot 'THIRD_PARTY_NOTICES.md') -Destination $bundle
        $zipName = if ($PublicRelease) { "sohun-$packageVersion-windows-x64.zip" } else { "sohun-core-preview-$packageVersion-windows-x64.zip" }
        $zipPath = Join-Path $OutputDirectory $zipName
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
        & (Join-Path $buildRoot 'scripts/Test-CoreBundle.ps1') -BundlePath $zipPath
        $windowsSigning = if ($PublicRelease) { 'WindowsNotSigned' } else { 'NotSigned (Authenticode)' }
        Add-Artifact $zipPath 'windows-portable' $windowsSigning
        if ($Installer) {
            $installerFlags = @{}
            if ($PublicRelease) { $installerFlags.PublicRelease = $true }
            & (Join-Path $buildRoot 'scripts/build_installer.ps1') -Product Personal -Core -ReleaseDir $bundle @installerFlags
            $setupName = if ($PublicRelease) { "sohun-setup-$packageVersion-windows-x64.exe" } else { "sohun-core-preview-setup-$packageVersion-windows-x64.exe" }
            $setup = Join-Path $buildRoot "dist/installer/$setupName"
            if ((Get-AuthenticodeSignature -LiteralPath $setup).Status -ne 'NotSigned') { throw 'Unexpected core installer signature.' }
            $publishedSetup = Join-Path $OutputDirectory ([IO.Path]::GetFileName($setup))
            Copy-Item -LiteralPath $setup -Destination $publishedSetup
            Add-Artifact $publishedSetup 'windows-installer' $windowsSigning
        }
    }
    if ($Target -in @('Android', 'All')) {
        $androidBuildFlags = @{}
        if ($RunTests) { $androidBuildFlags.RunNativeTests = $true }
        $androidConfiguration = if ($PublicRelease) { 'Release' } else { 'Debug' }
        if ($PublicRelease) {
            if (Test-Path -LiteralPath $temporarySigningFile) { throw 'Fresh Android build unexpectedly contains signing properties.' }
            Copy-Item -LiteralPath $androidSigningSource -Destination $temporarySigningFile
        }
        & (Join-Path $buildRoot 'scripts/build_android.ps1') -Configuration $androidConfiguration -Core -ApiBaseUrl $ApiBaseUrl @androidBuildFlags
        $apk = Join-Path $buildRoot "build/app/outputs/flutter-apk/app-$($androidConfiguration.ToLowerInvariant()).apk"
        & (Join-Path $buildRoot 'scripts/Test-CoreBundle.ps1') -BundlePath $apk
        if ($PublicRelease) {
            $sdkRoots = @($env:ANDROID_SDK_ROOT, $env:ANDROID_HOME) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $apksigner = $sdkRoots | ForEach-Object {
                Get-ChildItem -LiteralPath (Join-Path $_ 'build-tools') -Filter apksigner.bat -File -Recurse -ErrorAction SilentlyContinue
            } | Sort-Object FullName -Descending | Select-Object -First 1
            if ($null -eq $apksigner) { throw 'Android SDK apksigner is required to verify the public APK.' }
            $certificateOutput = Invoke-ApkVerificationTool $apksigner.FullName @('verify', '--verbose', '--print-certs', $apk)
            $certificateText = $certificateOutput -replace '\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))', ''
            $certificateText = $certificateText -replace '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]', ' '
            $certificateText = $certificateText.Replace([char]0xA0, ' ')
            if ($certificateText -match '(?i)CN\s*=\s*Android Debug') { throw 'Public APK used the Android debug identity.' }
            $digestMarkers = [regex]::Matches($certificateText, '(?i)certificate\s+SHA[\s-]+256\s+digest\s*:')
            if ($digestMarkers.Count -ne 1) { throw 'Unable to identify the public APK signing certificate.' }
            $expectedPairs = for ($index = 0; $index -lt $expectedAndroidCertificateSha256.Length; $index += 2) {
                [regex]::Escape($expectedAndroidCertificateSha256.Substring($index, 2))
            }
            $expectedDigestPattern = $expectedPairs -join '[\s:.-]*'
            $digestPattern = '(?is)certificate\s+SHA[\s-]+256\s+digest\s*:\s*[^0-9a-fA-F]*' + $expectedDigestPattern
            if (-not [regex]::IsMatch($certificateText, $digestPattern)) {
                throw 'Public APK does not match the configured long-term Android signing identity.'
            }
            $androidCertificateSha256 = $expectedAndroidCertificateSha256
            $aapt = Join-Path $apksigner.Directory.FullName 'aapt.exe'
            if (-not (Test-Path -LiteralPath $aapt -PathType Leaf)) { throw 'Android SDK aapt is required to verify release debuggability.' }
            $apkBadging = Invoke-ApkVerificationTool $aapt @('dump', 'badging', $apk)
            if ($apkBadging -notmatch "(?m)^package: name='top\.sohun\.consumable_tracker'" -or
                $apkBadging -match '(?m)^application-debuggable(?:\s|$)') {
                throw 'Public APK package identity or android:debuggable=false verification failed.'
            }
        }
        $apkName = if ($PublicRelease) { "sohun-$packageVersion-android.apk" } else { "sohun-core-preview-$packageVersion-android-debug.apk" }
        $publishedApk = Join-Path $OutputDirectory $apkName
        Copy-Item -LiteralPath $apk -Destination $publishedApk
        if ($PublicRelease) {
            Add-Artifact $publishedApk 'android-release-apk' 'AndroidReleaseSigned' $androidCertificateSha256
        } else {
            Add-Artifact $publishedApk 'android-debug-apk' 'Android debug certificate; not a production signing identity'
        }
    }
    $manifest = [ordered]@{
        schemaVersion = 1
        product = $(if ($PublicRelease) { 'sohun-core' } else { 'sohun-core-preview' })
        prerelease = -not [bool]$PublicRelease
        windowsSigning = $(if ($Target -in @('Windows', 'All')) { 'WindowsNotSigned' } else { 'NotBuilt' })
        androidSigning = $(if ($Target -notin @('Android', 'All')) { 'NotBuilt' } elseif ($PublicRelease) { 'AndroidReleaseSigned' } else { 'AndroidDebugSigned' })
        androidSigningCertificateSha256 = $androidCertificateSha256
        androidDebuggable = $(if ($Target -notin @('Android', 'All')) { $null } else { -not [bool]$PublicRelease })
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
    $manifestName = if ($PublicRelease) { 'release-manifest.json' } else { 'core-preview-manifest.json' }
    [IO.File]::WriteAllText((Join-Path $OutputDirectory $manifestName), ($manifest | ConvertTo-Json -Depth 6) + "`n", [Text.UTF8Encoding]::new($false))
    $checksumLines = @($artifacts | ForEach-Object { "$($_.sha256)  $($_.file)" })
    [IO.File]::WriteAllText((Join-Path $OutputDirectory 'SHA256SUMS.txt'), ($checksumLines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
    [pscustomobject]@{ SourceStage = $SourceStage; BuildRoot = $buildRoot; OutputDirectory = $OutputDirectory; Artifacts = $artifacts.Count }
} finally {
    try {
        if ($PublicRelease -and (Test-Path -LiteralPath $temporarySigningFile)) {
            Remove-Item -LiteralPath $temporarySigningFile -Force
        }
    } finally {
        $env:PUB_HOSTED_URL = $originalPubHostedUrl
        Set-Location $originalLocation
    }
}
