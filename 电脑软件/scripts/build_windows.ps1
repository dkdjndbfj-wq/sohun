# Unified Windows build helper for the consumable_tracker_desktop Flutter app.
#
# This script replaces `flutter build windows --debug|--release` for projects
# whose path contains non-ASCII characters (e.g. %USERPROFILE%\Desktop\耗材统计软件\...).
# Visual Studio / CMake mishandle such paths during the install step, causing
# `cmake -E copy_directory` to fail on the native_assets directory.
#
# What this script does:
#   1. Pre-populates the SQLite source + DLL cache (avoids hanging on
#      sqlite.org / GitHub downloads during CMake configure).
#   2. Stages the project to an ASCII temp directory via robocopy.
#   3. Runs flutter clean + pub get + build windows inside the staging dir
#      with FETCHCONTENT_SOURCE_DIR_SQLITE3 set to the cached source.
#      CMake also verifies and reuses the shared media_kit archive cache.
#   4. Copies the resulting build artifacts back to the project's build/ dir.
#   5. Cleans up the staging dir in finally.
#
# For hot-reload debugging, use scripts\run_windows_debug.ps1 instead, which
# uses `subst` to map the project to an ASCII drive letter (preserving hot
# reload by keeping the source tree in place).
#
# Usage:
#   .\scripts\build_windows.ps1                       # Debug build
#   .\scripts\build_windows.ps1 -Configuration Release
#   .\scripts\build_windows.ps1 -Configuration Release -Product Farm
#   .\scripts\build_windows.ps1 -Configuration Release -Obfuscate
#   .\scripts\build_windows.ps1 -ApiBaseUrl http://127.0.0.1:27861
#   .\scripts\build_windows.ps1 -SkipCachePrepare     # skip SQLite cache step
#   .\scripts\build_windows.ps1 -NoClean              # skip flutter clean
#
# Output:
#   Personal: <project>\dist\windows\personal\<Configuration>\sohun.exe
#   Farm:     <project>\dist\windows\farm\<Configuration>\sohun-farm.exe

[CmdletBinding()]
param(
    [ValidateSet("Debug", "Release", "Profile")]
    [string]$Configuration = "Debug",

    [ValidateSet("Personal", "Farm")]
    [string]$Product = "Personal",

    [switch]$Obfuscate,
    [switch]$SkipCachePrepare,
    [switch]$SkipBridgeBuild,
    [switch]$Core,
    [switch]$NoClean,
    [string]$SplitDebugInfoDir = "",
    [string]$ApiBaseUrl = ""
)

$ErrorActionPreference = "Stop"
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
Set-Location $projectRoot
$variant = $Product.ToLowerInvariant()
$expectedExecutable = if ($variant -eq "farm") { "sohun-farm.exe" } else { "sohun.exe" }
$previousSohunAppVariant = $env:SOHUN_APP_VARIANT
if ($Core) {
    if ($Product -ne 'Personal') { throw 'Core preview supports only the personal product.' }
    & (Join-Path $projectRoot 'scripts/Test-CoreSource.ps1') -ProjectRoot $projectRoot
    $SkipBridgeBuild = $true
} elseif (Test-Path -LiteralPath (Join-Path $projectRoot 'core-build.json')) {
    throw 'This is a core source export. Build it with -Core; full releases require their original source and release clearance.'
}

# --- Step 0: Build the cloud camera bridge from source -----------------------

# The Flutter build packages assets/bin as-is, so the bridge is recompiled
# from research/cloud_camera_bridge.cpp on every product build. This keeps a
# stale hand-copied exe from ever shipping and makes the binary reproducible.
# Re-run scripts\build_cloud_camera_bridge.ps1 to refresh assets/bin alone.
if (-not $SkipBridgeBuild) {
    Write-Host "`n=== Step 0: Build native account tools from source ===" -ForegroundColor Cyan
    & (Join-Path $projectRoot "scripts\build_native_account_tools.ps1")
    Write-Host "`n=== Step 0: Build cloud camera bridge from source ===" -ForegroundColor Cyan
    & (Join-Path $projectRoot "scripts\build_cloud_camera_bridge.ps1")
    if ($LASTEXITCODE -ne 0) {
        throw "cloud camera bridge build failed (exit $LASTEXITCODE)."
    }
} else {
    Write-Host "=== Step 0: Skipped cloud camera bridge build ===" -ForegroundColor Yellow
}

# --- Step 1: SQLite cache ---------------------------------------------------

if (-not $SkipCachePrepare) {
    Write-Host "=== Step 1: Prepare SQLite cache ===" -ForegroundColor Cyan
    $cacheScript = Join-Path $projectRoot "scripts\prepare_sqlite_cache.ps1"
    & $cacheScript
    # prepare_sqlite_cache.ps1 has $ErrorActionPreference = "Stop" and throws
    # on failure, so reaching here means success. $LASTEXITCODE is unreliable
    # because the cache script may not call any external command on the happy
    # path (so $LASTEXITCODE can be $null or stale).
    if (-not $env:FETCHCONTENT_SOURCE_DIR_SQLITE3) {
        throw "SQLite cache preparation did not set FETCHCONTENT_SOURCE_DIR_SQLITE3."
    }
} else {
    Write-Host "=== Step 1: Skipped SQLite cache preparation ===" -ForegroundColor Yellow
    if (-not $env:FETCHCONTENT_SOURCE_DIR_SQLITE3) {
        Write-Host "[build] Warning: FETCHCONTENT_SOURCE_DIR_SQLITE3 not set;" `
            "CMake may hang on sqlite.org download." -ForegroundColor Yellow
    }
}

# --- Step 2: Determine build root (ASCII staging if needed) -----------------

Write-Host "`n=== Step 2: Set up build root ===" -ForegroundColor Cyan

$buildRoot = $projectRoot
$stagingRoot = $null

# Always stage when the project path contains non-ASCII characters, regardless
# of configuration. The CMake install step fails on Chinese paths in both Debug
# and Release builds.
if ($projectRoot -match '[^\x00-\x7F]') {
    $stagingBase = [System.IO.Path]::GetFullPath(
        [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    ).TrimEnd('\')
    # Native-assets hooks create deeply nested cache paths. Keep the staging
    # component deliberately short to stay below Windows path-length limits.
    $stagingRoot = Join-Path $stagingBase "sohun_b_$PID"
    $resolvedStagingRoot = [System.IO.Path]::GetFullPath($stagingRoot)

    if (!$resolvedStagingRoot.StartsWith("$stagingBase\sohun_b_", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to create an unexpected staging directory."
    }

    if (Test-Path $resolvedStagingRoot) {
        Remove-Item -Recurse -Force $resolvedStagingRoot
    }
    New-Item -ItemType Directory -Force -Path $resolvedStagingRoot | Out-Null

    Write-Host "[build] Staging project to ASCII path: $resolvedStagingRoot"
    # Exclude large/regeneratable dirs to keep robocopy fast.
    # windows/flutter/ephemeral contains junctions created for the source tree.
    # Copying those junctions makes -NoClean reuse invalid plugin_symlinks in
    # the staging tree and causes flutter pub get/CMake to fail.
    $ephemeralSource = Join-Path $projectRoot "windows\flutter\ephemeral"
    & robocopy $projectRoot $resolvedStagingRoot /E `
        /XD build dist .dart_tool .git .idea .vscode $ephemeralSource `
        /XF *.log *.py *.js *.ps1 *.bat `
        /NFL /NDL /NJH /NJS /NP | Out-Null
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -gt 7) {
        throw "Unable to copy project to staging directory (robocopy $copyExitCode)."
    }
    # Defense in depth for robocopy versions whose /XD path matching differs.
    $stagedEphemeral = Join-Path $resolvedStagingRoot "windows\flutter\ephemeral"
    if (Test-Path -LiteralPath $stagedEphemeral) {
        Remove-Item -LiteralPath $stagedEphemeral -Recurse -Force
    }
    $buildRoot = $resolvedStagingRoot
} else {
    Write-Host "[build] Project path is ASCII; building in place: $buildRoot"
}

# --- Step 3: Build ----------------------------------------------------------

try {
    Set-Location $buildRoot
    $env:SOHUN_APP_VARIANT = $variant
    Write-Host "`n=== Step 3: flutter build windows --$Configuration ===" -ForegroundColor Cyan

    # Locate cpp_client_wrapper before the clean, then seed it after clean has
    # removed the ephemeral directory. This avoids the VS generation race.
    $flutterInfo = flutter --version --machine | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw "Unable to locate the Flutter SDK." }
    $wrapperSource = Join-Path $flutterInfo.flutterRoot "bin\cache\artifacts\engine\windows-x64\cpp_client_wrapper"
    if (!(Test-Path $wrapperSource)) {
        throw "Flutter Windows wrapper artifacts are missing: $wrapperSource"
    }

    if (-not $NoClean) {
        Write-Host "[build] flutter clean"
        flutter clean
        if ($LASTEXITCODE -ne 0) { throw "flutter clean failed." }
    }

    $wrapperTarget = Join-Path $buildRoot "windows\flutter\ephemeral\cpp_client_wrapper"
    New-Item -ItemType Directory -Force -Path $wrapperTarget | Out-Null
    Copy-Item -Path (Join-Path $wrapperSource "*") -Destination $wrapperTarget -Recurse -Force
    Write-Host "[build] Seeded cpp_client_wrapper"

    Write-Host "[build] flutter pub get"
    flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed." }

    # windows/cmake/prepare_media_kit.cmake verifies and stages the shared
    # video archive cache for both this helper and direct Flutter builds.

    # flutter clean removes this cache in ASCII projects too. Restore it after
    # cleaning and pub get for every build root, retaining SHA-256 validation.
    if ($env:SQLITE3_DLL_CACHE_PATH) {
        . (Join-Path $projectRoot 'scripts\sqlite_hook_asset.ps1')
        $dllSha = (Get-SqliteHookAsset -ProjectRoot $buildRoot).Sha256
        if (-not (Test-Path -LiteralPath $env:SQLITE3_DLL_CACHE_PATH) -or
            (Get-FileHash -LiteralPath $env:SQLITE3_DLL_CACHE_PATH -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dllSha) {
            throw 'The shared SQLite DLL cache is missing or failed SHA-256 verification.'
        }
        $hookCacheDir = Join-Path $buildRoot ".dart_tool\hooks_runner\shared\sqlite3\build\download-$($dllSha.Substring(0, 8))"
        # sqlite3 downloads a platform-qualified asset, then stores it under
        # the normalized dynamic-library name in the shared hook cache.
        $hookCachePath = Join-Path $hookCacheDir "sqlite3.dll"
        if (-not (Test-Path -LiteralPath $hookCachePath) -or
            (Get-FileHash -LiteralPath $hookCachePath -Algorithm SHA256).Hash.ToLowerInvariant() -ne $dllSha) {
            New-Item -ItemType Directory -Force -Path $hookCacheDir | Out-Null
            Copy-Item -Force $env:SQLITE3_DLL_CACHE_PATH $hookCachePath
            Write-Host "[build] Restored verified Dart hook DLL cache after clean"
        }
    }

    $buildArgs = @("build", "windows", "--$Configuration".ToLower())
    $buildArgs += "--dart-define=SOHUN_APP_VARIANT=$variant"
    if ($Core) { $buildArgs += '--dart-define=SOHUN_CORE_BUILD=true' }
    if ($Configuration -eq "Release" -and $Obfuscate) {
        $buildArgs += @("--obfuscate")
        if ($SplitDebugInfoDir -ne "") {
            $symbolsDir = $SplitDebugInfoDir
        } else {
            $symbolsDir = Join-Path $buildRoot "build\symbols"
        }
        New-Item -ItemType Directory -Force -Path $symbolsDir | Out-Null
        $buildArgs += @("--split-debug-info=$symbolsDir")
    }
    if (-not [string]::IsNullOrWhiteSpace($ApiBaseUrl)) {
        $buildArgs += @("--dart-define=APP_API_BASE_URL=$($ApiBaseUrl.Trim().TrimEnd('/'))")
    }

    Write-Host "[build] flutter $($buildArgs -join ' ')"
    & flutter @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "flutter build windows --$Configuration failed (exit $LASTEXITCODE)."
    }
    & (Join-Path $projectRoot 'scripts\Test-WindowsRuntimeBundle.ps1') `
        -BundleDirectory (Join-Path $buildRoot "build\windows\x64\runner\$Configuration")
    if ($Core) {
        & (Join-Path $projectRoot 'scripts/Test-CoreBundle.ps1') `
            -BundlePath (Join-Path $buildRoot "build/windows/x64/runner/$Configuration")
    } else {
        & (Join-Path $projectRoot 'scripts\test_native_account_tools.ps1') `
            -BinDirectory (Join-Path $buildRoot 'assets\bin') `
            -RuntimeBundle (Join-Path $buildRoot "build\windows\x64\runner\$Configuration")
    }

    # --- Step 4: Copy artifacts back to the project's build/ dir -------------
    if ($stagingRoot) {
        Write-Host "`n=== Step 4: Copy build artifacts back to project ===" -ForegroundColor Cyan
        $configDir = $Configuration  # "Debug" or "Release"
        $stagingBuildDir = Join-Path $buildRoot "build\windows\x64\runner\$configDir"
        $projectBuildDir = Join-Path $projectRoot "build\windows\x64\runner\$configDir"

        if (-not (Test-Path $stagingBuildDir)) {
            throw "Expected build output not found: $stagingBuildDir"
        }

        if (Test-Path $projectBuildDir) {
            # Windows can briefly hold a freshly built media/graphics DLL while
            # the build process and security scanner finish. A locked output
            # must fail the publish step: incrementally copying into it can mix
            # binaries and resources from different builds.
            $lastRemovalError = $null
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                try {
                    Remove-Item -LiteralPath $projectBuildDir -Recurse -Force -ErrorAction Stop
                    $lastRemovalError = $null
                    break
                } catch {
                    $lastRemovalError = $_
                    if ($attempt -eq 5) {
                        break
                    }
                    Write-Host "[build] Existing $configDir output is still in use; retrying ($attempt/5)..." -ForegroundColor Yellow
                    Start-Sleep -Milliseconds (500 * $attempt)
                }
            }
            if (Test-Path -LiteralPath $projectBuildDir) {
                $reason = if ($null -ne $lastRemovalError) {
                    $lastRemovalError.Exception.Message
                } else {
                    'the directory still exists after removal'
                }
                throw "Existing $configDir output could not be removed. Refusing to mix old and new build files: $reason"
            }
        }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $projectBuildDir) | Out-Null

        # Copy the entire <Configuration> dir (exe, dll, data, flutter_assets).
        & robocopy $stagingBuildDir $projectBuildDir /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        $copyExitCode = $LASTEXITCODE
        if ($copyExitCode -gt 7) {
            throw "Failed to copy build artifacts back (robocopy $copyExitCode)."
        }
        Write-Host "[build] Artifacts copied to: $projectBuildDir"

        # Also copy the build/native_assets dir for diagnostics.
        $stagingNativeAssets = Join-Path $buildRoot "build\native_assets"
        $projectNativeAssets = Join-Path $projectRoot "build\native_assets"
        if (Test-Path $stagingNativeAssets) {
            if (Test-Path $projectNativeAssets) {
                Remove-Item -Recurse -Force $projectNativeAssets
            }
            & robocopy $stagingNativeAssets $projectNativeAssets /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        }
    } else {
        Write-Host "`n=== Step 4: Skipped (built in place) ===" -ForegroundColor Yellow
    }

    $sourceBuildDir = Join-Path $projectRoot "build\windows\x64\runner\$Configuration"
    if (-not (Test-Path -LiteralPath $sourceBuildDir)) {
        throw "Expected project build output not found: $sourceBuildDir"
    }

    # Keep final products in stable, version-specific directories. The shared
    # Flutter build directory is only an intermediate and is overwritten by
    # the next product build.
    $artifactRoot = [System.IO.Path]::GetFullPath((Join-Path $projectRoot "dist\windows"))
    $artifactVariant = if ($Core) { 'core-preview' } else { $variant }
    $artifactDir = [System.IO.Path]::GetFullPath(
        (Join-Path $artifactRoot "$artifactVariant\$Configuration")
    )
    if (-not $artifactDir.StartsWith("$artifactRoot\", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write artifacts outside dist\\windows."
    }
    if (Test-Path -LiteralPath $artifactDir) {
        Remove-Item -LiteralPath $artifactDir -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $artifactDir | Out-Null
    & robocopy $sourceBuildDir $artifactDir /E /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
    $copyExitCode = $LASTEXITCODE
    if ($copyExitCode -gt 7) {
        throw "Failed to copy final $Product artifacts (robocopy $copyExitCode)."
    }

    Write-Host "`n=== Build complete ($Product / $Configuration) ===" -ForegroundColor Green
    $finalExe = Join-Path $artifactDir $expectedExecutable
    if (-not (Test-Path -LiteralPath $finalExe)) {
        throw "Expected product executable was not produced: $finalExe"
    }
    if ($Core) { & (Join-Path $projectRoot 'scripts/Test-CoreBundle.ps1') -BundlePath $artifactDir }
    Write-Host "Executable: $finalExe"

} finally {
    Set-Location $projectRoot
    if ($null -eq $previousSohunAppVariant) {
        Remove-Item Env:SOHUN_APP_VARIANT -ErrorAction SilentlyContinue
    } else {
        $env:SOHUN_APP_VARIANT = $previousSohunAppVariant
    }
    if ($null -ne $stagingRoot -and (Test-Path $stagingRoot)) {
        $stagingBase = [System.IO.Path]::GetFullPath(
            [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        ).TrimEnd('\')
        $resolvedStagingRoot = [System.IO.Path]::GetFullPath($stagingRoot)
        if ($resolvedStagingRoot.StartsWith("$stagingBase\sohun_b_", [System.StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedStagingRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# Robocopy returns 1 when it successfully copies files. Do not leak that
# success status as a failed process exit to build_products.ps1 or CI.
exit 0
