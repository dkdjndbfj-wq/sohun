[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundlePath,
    [ValidateSet('Personal', 'Farm')]
    [string]$Product = 'Personal'
)

$ErrorActionPreference = 'Stop'
$resolved = [IO.Path]::GetFullPath($BundlePath)
if (!(Test-Path -LiteralPath $resolved -PathType Container)) {
    throw "Personal Windows bundle was not found: $resolved"
}

$assetsRoot = Join-Path $resolved 'data\flutter_assets'
$requiredFiles = @(
    (Join-Path $resolved $(if ($Product -eq 'Farm') { 'sohun-farm.exe' } else { 'sohun.exe' })),
    (Join-Path $resolved 'flutter_windows.dll'),
    (Join-Path $resolved 'window_manager_plugin.dll'),
    (Join-Path $assetsRoot 'AssetManifest.bin'),
    (Join-Path $assetsRoot 'FontManifest.json'),
    (Join-Path $assetsRoot 'fonts\MaterialIcons-Regular.otf'),
    (Join-Path $assetsRoot 'assets\images\sohun.png'),
    (Join-Path $assetsRoot 'assets\images\app_icon.ico')
)
foreach ($requiredFile in $requiredFiles) {
    if (!(Test-Path -LiteralPath $requiredFile -PathType Leaf) -or
        (Get-Item -LiteralPath $requiredFile).Length -le 0) {
        throw "Required personal bundle file is missing or empty: $requiredFile"
    }
}

$fontManifest = Get-Content -LiteralPath (Join-Path $assetsRoot 'FontManifest.json') -Raw
if ($fontManifest -notmatch 'MaterialIcons' -or
    $fontManifest -notmatch 'MaterialIcons-Regular\.otf') {
    throw 'FontManifest.json does not declare MaterialIcons.'
}

$requiredDirs = @(
    (Join-Path $assetsRoot 'assets\images\icons'),
    (Join-Path $assetsRoot 'assets\images\branding'),
    (Join-Path $assetsRoot 'assets\images\printers')
)
if ($Product -eq 'Personal') {
    $requiredDirs += (Join-Path $assetsRoot 'assets\images\bambu_icons')
}
foreach ($requiredDir in $requiredDirs) {
    $files = @(Get-ChildItem -LiteralPath $requiredDir -File -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne '.gitkeep' -and $_.Length -gt 0 })
    if ($files.Count -eq 0) {
        throw "Required personal asset directory is empty: $requiredDir"
    }
}

Write-Host "[personal] Verified Flutter assets, MaterialIcons, branding and plugin binaries."
