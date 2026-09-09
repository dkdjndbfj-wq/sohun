# One-time development environment setup for the consumable_tracker_desktop
# Flutter Windows desktop app.
#
# This script addresses three problems caused by the project living under a
# Chinese path (%USERPROFILE%\Desktop\耗材统计软件\电脑软件):
#
#   1. `flutter build windows` hangs on downloading SQLite source/DLL from
#      sqlite.org / GitHub (no progress, no timeout, no mirror).
#   2. `flutter build windows --debug` fails at the install step because CMake
#      cannot `copy_directory` the native_assets dir whose path contains CJK
#      characters.
#   3. `flutter run -d windows` (hot reload) needs an ASCII source path so
#      CMake's install step succeeds, but staging the project to a temp dir
#      breaks file watchers.
#
# Solution:
#   - Pre-populate SQLite source + DLL cache (idempotent, ~3MB total).
#   - Mount the project at W: via `subst` (preserves hot reload).
#   - Instruct the user to open W:\ in their IDE and run flutter from there.
#
# Usage:
#   .\scripts\setup_dev_env.ps1            # set up cache + subst
#   .\scripts\setup_dev_env.ps1 -NoSubst   # cache only
#   .\scripts\setup_dev_env.ps1 -Clean     # unmount subst and clear cache

[CmdletBinding()]
param(
    [switch]$NoSubst,
    [switch]$Clean
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $projectRoot

if ($Clean) {
    Write-Host "=== Cleaning dev environment ===" -ForegroundColor Cyan

    # Unmount any W: (or other) subst pointing to this project.
    & subst 2>&1 | ForEach-Object {
        # subst with no args lists current mappings as "W:\: => C:\path"
        if ($_ -match '^([A-Z]):\\: => (.+)$') {
            $letter = $matches[1]
            $target = $matches[2].Trim()
            if ($target -ieq $projectRoot) {
                Write-Host "[clean] Unmounting ${letter}:"
                & subst "${letter}:" /D | Out-Null
            }
        }
    }

    # Clear SQLite cache.
    $cacheRoot = Join-Path `
        ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) `
        "consumable_build_cache"
    if (Test-Path $cacheRoot) {
        Write-Host "[clean] Removing $cacheRoot"
        Remove-Item -Recurse -Force $cacheRoot
    }

    Write-Host "Done. Run .\scripts\setup_dev_env.ps1 again to rebuild." -ForegroundColor Green
    return
}

# --- 1. SQLite cache --------------------------------------------------------

Write-Host "=== 1. Preparing SQLite cache ===" -ForegroundColor Cyan
$cacheScript = Join-Path $projectRoot "scripts\prepare_sqlite_cache.ps1"
& $cacheScript
if (-not $env:FETCHCONTENT_SOURCE_DIR_SQLITE3) {
    throw "SQLite cache preparation did not set FETCHCONTENT_SOURCE_DIR_SQLITE3."
}

# --- 2. Flutter SDK sanity check -------------------------------------------

Write-Host "`n=== 2. Flutter SDK sanity check ===" -ForegroundColor Cyan
$flutterInfo = flutter --version --machine 2>&1 | ConvertFrom-Json -ErrorAction SilentlyContinue
if ($null -eq $flutterInfo) {
    Write-Host "[setup] WARNING: `flutter` not found on PATH." -ForegroundColor Yellow
    Write-Host "[setup] Install Flutter 3.22+ and ensure it is on PATH." -ForegroundColor Yellow
} else {
    Write-Host "[setup] Flutter: $($flutterInfo.frameworkVersion)"
    Write-Host "[setup] Dart:    $($flutterInfo.dartSdkVersion)"
    Write-Host "[setup] Root:    $($flutterInfo.flutterRoot)"
}

# --- 3. Subst drive ---------------------------------------------------------

if (-not $NoSubst) {
    Write-Host "`n=== 3. Mounting ASCII drive via subst ===" -ForegroundColor Cyan
    $substScript = Join-Path $projectRoot "scripts\subst_drive.ps1"
    & $substScript
    # subst_drive.ps1 throws on failure; reaching here means success.
} else {
    Write-Host "`n=== 3. Skipped subst (use -NoSubst was set) ===" -ForegroundColor Yellow
}

# --- 4. Next steps ----------------------------------------------------------

Write-Host "`n=== Next steps ===" -ForegroundColor Green
if (-not $NoSubst) {
    Write-Host "1. Open the project from W:\ in VSCode or IntelliJ (NOT the Chinese path)."
    Write-Host "2. Run `flutter run -d windows` from W:\ for hot-reload debugging."
    Write-Host "3. For one-shot builds, use .\scripts\build_windows.ps1 -Configuration Debug|Release"
} else {
    Write-Host "1. For one-shot builds, use .\scripts\build_windows.ps1 (handles ASCII staging)."
    Write-Host "2. For hot-reload debugging, run .\scripts\setup_dev_env.ps1 without -NoSubst."
}
Write-Host ""
Write-Host "SQLite cache and FETCHCONTENT_SOURCE_DIR_SQLITE3 are set for this session."
Write-Host "If you open a new terminal, re-run .\scripts\prepare_sqlite_cache.ps1 first."
