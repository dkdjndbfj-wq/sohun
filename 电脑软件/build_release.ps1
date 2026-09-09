# Formal, fail-closed Windows release build.
#
# Developer/internal builds remain available through scripts\build_windows.ps1.
# This script is only for packages intended for external distribution and
# therefore requires both a real code-signing certificate and a reviewed
# third-party redistribution clearance manifest.
#
# Usage:
#   .\build_release.ps1 `
#     -ApiBaseUrl https://api.example.com `
#     -CertThumbprint <SHA1> `
#     -ThirdPartyClearanceManifest C:\secure\sohun-release-clearance.json

[CmdletBinding()]
param(
    [string]$ApiBaseUrl = $env:APP_API_BASE_URL,
    [string]$CertThumbprint = "",
    [string]$ThirdPartyClearanceManifest = "",
    [string]$TimestampUrl = "http://timestamp.digicert.com",
    [switch]$SkipCachePrepare
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $projectRoot

function Resolve-CodeSigningCertificate([string]$Thumbprint) {
    $normalized = $Thumbprint.Replace(" ", "").ToUpperInvariant()
    if ($normalized -notmatch '^[0-9A-F]{40}$') {
        throw "CertThumbprint is required and must be a 40-character SHA-1 certificate thumbprint."
    }
    $certificate = @(
        Get-ChildItem -Path Cert:\CurrentUser\My -ErrorAction SilentlyContinue
        Get-ChildItem -Path Cert:\LocalMachine\My -ErrorAction SilentlyContinue
    ) | Where-Object {
        $_.Thumbprint.Replace(" ", "").ToUpperInvariant() -eq $normalized
    } | Select-Object -First 1
    if ($null -eq $certificate) {
        throw "The requested code-signing certificate is not installed in CurrentUser/My or LocalMachine/My."
    }
    if ($certificate.NotAfter -le (Get-Date)) {
        throw "The requested code-signing certificate has expired."
    }
    return $certificate
}

if ([string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
    throw "ApiBaseUrl is required. Pass -ApiBaseUrl https://your-api-domain.example"
}
try {
    $apiUri = [System.Uri]::new($ApiBaseUrl.Trim())
} catch {
    throw "ApiBaseUrl is not a valid absolute HTTPS URL."
}
if (!$apiUri.IsAbsoluteUri -or $apiUri.Scheme -ne "https" -or [string]::IsNullOrWhiteSpace($apiUri.Host)) {
    throw "ApiBaseUrl must be an absolute HTTPS URL."
}
if (![string]::IsNullOrEmpty($apiUri.UserInfo) -or ![string]::IsNullOrEmpty($apiUri.Query) -or ![string]::IsNullOrEmpty($apiUri.Fragment)) {
    throw "ApiBaseUrl must not contain credentials, query parameters, or fragments."
}
$ApiBaseUrl = $ApiBaseUrl.Trim().TrimEnd('/')

if ([string]::IsNullOrWhiteSpace($ThirdPartyClearanceManifest)) {
    throw "ThirdPartyClearanceManifest is required for an external release. No redistribution clearance is currently recorded."
}
$clearanceScript = Join-Path $projectRoot "scripts\Test-ReleaseClearance.ps1"
$clearance = & $clearanceScript -ManifestPath $ThirdPartyClearanceManifest
$clearancePath = (Resolve-Path -LiteralPath $ThirdPartyClearanceManifest).Path
$clearanceHash = (Get-FileHash -LiteralPath $clearancePath -Algorithm SHA256).Hash.ToLowerInvariant()

$certificate = Resolve-CodeSigningCertificate $CertThumbprint
$normalizedThumbprint = $certificate.Thumbprint.Replace(" ", "").ToUpperInvariant()
$signToolCommand = Get-Command signtool.exe -ErrorAction SilentlyContinue
$signToolPath = if ($null -ne $signToolCommand) { $signToolCommand.Source } else { $null }
if ([string]::IsNullOrWhiteSpace($signToolPath)) {
    $windowsSdkBin = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
    $signToolPath = Get-ChildItem -LiteralPath $windowsSdkBin -Filter 'signtool.exe' -File -Recurse -ErrorAction SilentlyContinue |
        Sort-Object `
            @{ Expression = { if ($_.Directory.Name -eq 'x64') { 0 } else { 1 } }; Ascending = $true },
            @{ Expression = { $_.FullName }; Descending = $true } |
        Select-Object -First 1 -ExpandProperty FullName
}
if ([string]::IsNullOrWhiteSpace($signToolPath)) {
    throw "signtool.exe was not found. Install the Windows SDK signing tools."
}

function Write-AssetHashManifests([string]$AssetDirectory, [string[]]$FileNames) {
    foreach ($fileName in $FileNames) {
        $filePath = Join-Path $AssetDirectory $fileName
        if (!(Test-Path -LiteralPath $filePath -PathType Leaf)) {
            throw "Required release asset is missing before Flutter build: $filePath"
        }
        $fileInfo = Get-Item -LiteralPath $filePath
        if ($fileInfo.Length -le 0) {
            throw "Required release asset is empty before Flutter build: $filePath"
        }
        $hash = (Get-FileHash -LiteralPath $filePath -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $fileName" | Out-File -LiteralPath (Join-Path $AssetDirectory "$fileName.sha256") -Encoding ascii -NoNewline
    }
}

$assetHashFiles = @(
    "bind_tool.exe",
    "switch_user_tool.exe",
    "cloud_camera_bridge.exe",
    "bambu_networking.dll",
    "slicer_base64.cer"
)
Write-Host "=== Prepare runtime integrity manifests before Flutter build ===" -ForegroundColor Cyan
Write-AssetHashManifests (Join-Path $projectRoot "assets\bin") $assetHashFiles

Write-Host "=== 1. Build obfuscated Release artifacts ===" -ForegroundColor Cyan
$buildScript = Join-Path $projectRoot "scripts\build_windows.ps1"
$buildParameters = @{
    Configuration = "Release"
    Obfuscate = $true
    ApiBaseUrl = $ApiBaseUrl
    SplitDebugInfoDir = (Join-Path $projectRoot "build\symbols")
}
if ($SkipCachePrepare) { $buildParameters.SkipCachePrepare = $true }
& $buildScript @buildParameters

$releaseDir = Join-Path $projectRoot "build\windows\x64\runner\Release"
$mainExecutable = Join-Path $releaseDir "sohun.exe"
if (!(Test-Path -LiteralPath $mainExecutable)) {
    throw "Expected release executable was not produced: $mainExecutable"
}

Write-Host "`n=== 2. Create clean distribution tree ===" -ForegroundColor Cyan
$distDir = Join-Path $projectRoot "dist\sohun-windows-x64"
$resolvedProjectRoot = [System.IO.Path]::GetFullPath($projectRoot).TrimEnd('\')
$resolvedDistDir = [System.IO.Path]::GetFullPath($distDir)
if (!$resolvedDistDir.StartsWith("$resolvedProjectRoot\dist\", [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to clean a path outside the project dist directory: $resolvedDistDir"
}
if (Test-Path -LiteralPath $resolvedDistDir) {
    Remove-Item -LiteralPath $resolvedDistDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $resolvedDistDir | Out-Null
Copy-Item -Path (Join-Path $releaseDir "*") -Destination $resolvedDistDir -Recurse -Force
Copy-Item -LiteralPath (Join-Path $projectRoot "THIRD_PARTY_NOTICES.md") `
    -Destination (Join-Path $resolvedDistDir "THIRD_PARTY_NOTICES.txt") -Force

# FFmpeg is an external runtime used by the farm camera relay. It is not a
# Flutter asset: the relay resolves it next to the installed executable, so
# copy the reviewed binary into the path the runtime actually probes.
$ffmpegSource = Join-Path $projectRoot "assets\tools\ffmpeg\ffmpeg.exe"
if (!(Test-Path -LiteralPath $ffmpegSource -PathType Leaf)) {
    throw "Required FFmpeg runtime is missing from the cleared release assets: $ffmpegSource"
}
$ffmpegSourceInfo = Get-Item -LiteralPath $ffmpegSource
if ($ffmpegSourceInfo.Length -le 0) {
    throw "Required FFmpeg runtime is empty: $ffmpegSource"
}
$ffmpegTarget = Join-Path $resolvedDistDir "tools\ffmpeg\ffmpeg.exe"
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ffmpegTarget) | Out-Null
Copy-Item -LiteralPath $ffmpegSource -Destination $ffmpegTarget -Force

Write-Host "`n=== 3. Sign first-party executables and verify signatures ===" -ForegroundColor Cyan
$signTargets = @(
    (Join-Path $resolvedDistDir "sohun.exe"),
    (Join-Path $resolvedDistDir "data\flutter_assets\assets\bin\bind_tool.exe"),
    (Join-Path $resolvedDistDir "data\flutter_assets\assets\bin\switch_user_tool.exe"),
    (Join-Path $resolvedDistDir "data\flutter_assets\assets\bin\cloud_camera_bridge.exe")
)
foreach ($target in $signTargets) {
    if (!(Test-Path -LiteralPath $target)) {
        throw "Required signing target is missing: $target"
    }
    & $signToolPath sign /tr $TimestampUrl /td sha256 /fd sha256 /sha1 $normalizedThumbprint $target
    if ($LASTEXITCODE -ne 0) { throw "Signing failed: $target" }
    $signature = Get-AuthenticodeSignature -LiteralPath $target
    if ($signature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
        throw "Signature verification failed for $target ($($signature.Status))."
    }
}

$bambuDll = Join-Path $resolvedDistDir "data\flutter_assets\assets\bin\bambu_networking.dll"
if (!(Test-Path -LiteralPath $bambuDll)) {
    throw "Required Bambu networking component is missing from the distribution."
}
$bambuSignature = Get-AuthenticodeSignature -LiteralPath $bambuDll
if ($bambuSignature.Status -ne [System.Management.Automation.SignatureStatus]::Valid) {
    throw "The upstream bambu_networking.dll signature is not valid; release stopped."
}

$assetBinDir = Join-Path $resolvedDistDir "data\flutter_assets\assets\bin"
Write-AssetHashManifests $assetBinDir $assetHashFiles

Write-Host "`n=== 4. Generate release manifest and contamination check ===" -ForegroundColor Cyan
$versionMatch = Select-String -LiteralPath (Join-Path $projectRoot "pubspec.yaml") -Pattern '^version:\s*(\S+)\s*$' | Select-Object -First 1
if ($null -eq $versionMatch) { throw "Unable to read the application version from pubspec.yaml." }
$version = $versionMatch.Matches[0].Groups[1].Value
$manifestPath = Join-Path $resolvedDistDir "release-manifest.json"
function Get-ReleaseRelativePath([string]$BaseDirectory, [string]$TargetPath) {
    # Windows PowerShell 5.1 runs on .NET Framework, which does not provide
    # System.IO.Path.GetRelativePath. Uri.MakeRelativeUri is available there
    # and preserves the same relative-path semantics for the manifest.
    $baseUri = [System.Uri]::new((Resolve-Path -LiteralPath $BaseDirectory).Path.TrimEnd('\') + '\')
    $targetUri = [System.Uri]::new((Resolve-Path -LiteralPath $TargetPath).Path)
    return [System.Uri]::UnescapeDataString(
        $baseUri.MakeRelativeUri($targetUri).ToString()
    ).Replace('/', '\')
}
$fileEntries = @(Get-ChildItem -LiteralPath $resolvedDistDir -Recurse -File | Where-Object {
    $_.FullName -ne $manifestPath
} | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = (Get-ReleaseRelativePath $resolvedDistDir $_.FullName).Replace('\', '/')
        bytes = $_.Length
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})
$manifest = [ordered]@{
    schemaVersion = 1
    product = "sohun-consumable-workbench"
    version = $version
    builtAtUtc = (Get-Date).ToUniversalTime().ToString("o")
    apiBaseUrl = $ApiBaseUrl
    signing = [ordered]@{
        certificateThumbprint = $normalizedThumbprint
        certificateSubject = $certificate.Subject
        timestampUrl = $TimestampUrl
    }
    thirdPartyClearance = [ordered]@{
        manifestFile = [System.IO.Path]::GetFileName($clearancePath)
        sha256 = $clearanceHash
        approvedBy = $clearance.approvedBy
        approvedAt = $clearance.approvedAt
    }
    files = $fileEntries
}
$manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $manifestPath -Encoding utf8

$blockedExtensions = @('.py', '.js', '.ps1', '.bat', '.md', '.log')
$blockedFiles = Get-ChildItem -LiteralPath $resolvedDistDir -Recurse -File | Where-Object {
    $blockedExtensions -contains $_.Extension.ToLowerInvariant()
}
if ($blockedFiles) {
    $names = ($blockedFiles | ForEach-Object { $_.FullName }) -join "`n"
    throw "Scripts, logs, or internal documents were found in the distribution:`n$names"
}

Write-Host "`n=== Signed release complete ===" -ForegroundColor Green
Write-Host "Distribution: $resolvedDistDir"
Write-Host "Manifest: $manifestPath"
Write-Host "Keep private symbols outside the distribution: $(Join-Path $projectRoot 'build\symbols')" -ForegroundColor Yellow
