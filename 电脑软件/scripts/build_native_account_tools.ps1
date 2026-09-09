[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$nativeProject = Split-Path -Parent $PSScriptRoot
foreach ($helperName in @('bind_tool', 'switch_user_tool')) {
    & (Join-Path $PSScriptRoot 'build_cloud_camera_bridge.ps1') `
        -SourcePath (Join-Path $nativeProject "research\$helperName.cpp") `
        -OutputPath (Join-Path $nativeProject "assets\bin\$helperName.exe")
}
