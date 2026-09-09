# Builds the two immutable Sohun Windows desktop products.
#
# Output:
#   dist\windows\personal\<Configuration>\sohun.exe
#   dist\windows\farm\<Configuration>\sohun-farm.exe

[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release", "Profile")]
    [string]$Configuration = "Release",

    [switch]$Obfuscate,
    [switch]$SkipCachePrepare,
    [string]$SplitDebugInfoDir = "",
    [string]$ApiBaseUrl = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$buildScript = Join-Path $projectRoot "scripts\build_windows.ps1"

$common = @{
    Configuration = $Configuration
    Obfuscate = $Obfuscate
    SkipCachePrepare = $SkipCachePrepare
    SplitDebugInfoDir = $SplitDebugInfoDir
    ApiBaseUrl = $ApiBaseUrl
}

& $buildScript @common -Product Personal
& $buildScript @common -Product Farm

Write-Host "Both products are ready under dist\\windows." -ForegroundColor Green
