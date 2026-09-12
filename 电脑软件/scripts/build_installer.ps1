# Builds the branded per-user Windows installer from an existing Release tree.

[CmdletBinding()]
param(
    [string]$ReleaseDir = "",
    [string]$CompilerPath = "",
    [switch]$Core,
    [switch]$PublicRelease,
    [ValidateSet("Personal", "Farm")]
    [string]$Product = "Personal"
)

$ErrorActionPreference = "Stop"
if ($PublicRelease -and (-not $Core -or $Product -ne 'Personal')) {
    throw 'PublicRelease packages only the explicitly cleared personal core build; pass -Core -Product Personal.'
}
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $projectRoot

if ([string]::IsNullOrWhiteSpace($ReleaseDir)) {
    $variant = if ($Core) { 'core-preview' } else { $Product.ToLowerInvariant() }
    $ReleaseDir = Join-Path $projectRoot "dist\windows\$variant\Release"
}
$resolvedReleaseDir = [System.IO.Path]::GetFullPath($ReleaseDir)
$variant = $Product.ToLowerInvariant()
$expectedExecutable = if ($variant -eq "farm") { "sohun-farm.exe" } else { "sohun.exe" }
$requiredPaths = @(
    (Join-Path $resolvedReleaseDir $expectedExecutable),
    (Join-Path $resolvedReleaseDir "flutter_windows.dll"),
    (Join-Path $resolvedReleaseDir "msvcp140.dll"),
    (Join-Path $resolvedReleaseDir "vcruntime140.dll"),
    (Join-Path $resolvedReleaseDir "vcruntime140_1.dll"),
    (Join-Path $resolvedReleaseDir "msvc-runtime.sha256"),
    (Join-Path $resolvedReleaseDir "data\flutter_assets")
)
foreach ($requiredPath in $requiredPaths) {
    if (!(Test-Path -LiteralPath $requiredPath)) {
        throw "Release artifact is missing: $requiredPath"
    }
}
& (Join-Path $projectRoot 'scripts\Test-WindowsRuntimeBundle.ps1') `
    -BundleDirectory $resolvedReleaseDir
if ($Core) {
    if ($Product -ne 'Personal') { throw 'Core preview supports only the personal product.' }
    & (Join-Path $projectRoot 'scripts/Test-CoreSource.ps1') -ProjectRoot $projectRoot
    & (Join-Path $projectRoot 'scripts/Test-CoreBundle.ps1') -BundlePath $resolvedReleaseDir
}

if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($env:INNO_SETUP_COMPILER)) {
        $candidates += $env:INNO_SETUP_COMPILER
    }
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $candidates += Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
    }
    if (-not [string]::IsNullOrWhiteSpace($env:ProgramFiles)) {
        $candidates += Join-Path $env:ProgramFiles "Inno Setup 7\ISCC.exe"
    }
    $candidates += Join-Path $env:LOCALAPPDATA "Programs\Inno Setup 6\ISCC.exe"
    $CompilerPath = $candidates |
        Where-Object { Test-Path -LiteralPath $_ } |
        Select-Object -First 1
    if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
        $command = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        if ($null -ne $command) { $CompilerPath = $command.Source }
    }
}
if ([string]::IsNullOrWhiteSpace($CompilerPath) -or !(Test-Path -LiteralPath $CompilerPath)) {
    throw "Inno Setup 6.7+ compiler was not found. Install it or pass -CompilerPath <ISCC.exe>."
}

$versionMatch = Select-String -LiteralPath (Join-Path $projectRoot "pubspec.yaml") `
    -Pattern '^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)\s*$' | Select-Object -First 1
if ($null -eq $versionMatch) { throw "Unable to parse pubspec.yaml version." }
$groups = $versionMatch.Matches[0].Groups
$appVersion = "$($groups[1].Value).$($groups[2].Value).$($groups[3].Value)+$($groups[4].Value)"
$numericVersion = "$($groups[1].Value).$($groups[2].Value).$($groups[3].Value).$($groups[4].Value)"
$packageVersion = $appVersion.Replace('+', '-')

$installerDir = Join-Path $projectRoot "dist\installer"
New-Item -ItemType Directory -Force -Path $installerDir | Out-Null
$scriptPath = Join-Path $projectRoot "installer\sohun.iss"

if ($PublicRelease) {
    $productDefines = @(
        '/DMyProductDisplayName=sohun',
        '/DMyProductSlug=sohun',
        '/DMyProductInstallName=sohun',
        '/DMySetupAppId={{51358463-A026-4AB6-8D95-C6CDB8AA0B3E}'
    )
    $expectedOutputName = "sohun-setup-$packageVersion-windows-x64.exe"
} elseif ($Core) {
    $productDefines = @(
        '/DMyProductDisplayName=sohun Core Preview (unsigned)',
        '/DMyProductSlug=sohun-core-preview',
        '/DMyProductInstallName=sohun-core-preview',
        '/DMySetupAppId={{51358463-A026-4AB6-8D95-C6CDB8AA0B3E}'
    )
    $expectedOutputName = "sohun-core-preview-setup-$packageVersion-windows-x64.exe"
} elseif ($Product -eq "Farm") {
    $productDefines = @(
        "/DMyProductDisplayName=sohun 农场",
        "/DMyProductSlug=sohun-farm",
        "/DMyProductInstallName=sohun-farm",
        "/DMyExecutableName=sohun-farm.exe",
        "/DMySetupAppId={{7A3F47C3-9A4A-4D5F-9E4E-9B9E3C7A1F24}",
        "/DMyAppMutex=Local\sohun-farm-desktop-05f685a9-4f66-4f9e-9a6b-5e9131cd7317"
    )
    $expectedOutputName = "sohun-farm-setup-$packageVersion-windows-x64.exe"
} else {
    $productDefines = @()
    $expectedOutputName = "sohun-setup-$packageVersion-windows-x64.exe"
}

Write-Host "[installer] Compiler: $CompilerPath"
Write-Host "[installer] Source:   $resolvedReleaseDir"
& $CompilerPath /Qp `
    "/DMyAppVersion=$appVersion" `
    "/DMyPackageVersion=$packageVersion" `
    "/DMyNumericVersion=$numericVersion" `
    "/DMyBuildSource=$resolvedReleaseDir" `
    $productDefines `
    $scriptPath
if ($LASTEXITCODE -ne 0) { throw "Inno Setup compilation failed (exit $LASTEXITCODE)." }

$outputPath = Join-Path $installerDir $expectedOutputName
if (!(Test-Path -LiteralPath $outputPath)) {
    throw "Installer output was not produced: $outputPath"
}
Write-Host "[installer] Built: $outputPath" -ForegroundColor Green
