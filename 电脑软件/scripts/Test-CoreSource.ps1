[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$ProjectRoot)
$ErrorActionPreference = 'Stop'
$markerPath = Join-Path $ProjectRoot 'core-build.json'
if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
    throw 'Core builds require an exported core source snapshot; run scripts/export_public_source.ps1 first.'
}
$marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($marker.schemaVersion -ne 1 -or $marker.product -ne 'sohun-core-preview' -or $marker.signedRelease -ne $false) {
    throw 'The core source marker is invalid.'
}
foreach ($relative in @('assets/bin', 'assets/tools', 'assets/images/bambu_icons', 'assets/bambu_presets', 'assets/knowledge', 'assets/calibration')) {
    $folder = Join-Path $ProjectRoot $relative
    if (Test-Path -LiteralPath $folder) {
        $unexpected = @(Get-ChildItem -LiteralPath $folder -File -Recurse -Force | Where-Object Name -ne '.gitkeep')
        if ($unexpected.Count -gt 0) { throw "Core source contains excluded reference assets: $relative" }
    }
}
foreach ($name in @('pubspec.yaml', 'pubspec.lock')) {
    if ([IO.File]::ReadAllText((Join-Path $ProjectRoot $name)) -match '(?m)^  media_kit_libs_windows_video:') {
        throw 'Core source still includes the optional native video runtime dependency.'
    }
}
Write-Host '[core] Source asset and dependency boundaries verified.'
