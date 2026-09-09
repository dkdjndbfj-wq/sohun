# Pre-populates the SQLite build cache so that flutter build/run does not hang
# on downloading sqlite source from sqlite.org or the prebuilt DLL from GitHub.
#
# Two artifacts are cached:
#   1. sqlite-autoconf-3520000.tar.gz  (used by sqlite3_flutter_libs CMake
#      FetchContent). Extracted to <cache>\sqlite-src\sqlite-autoconf-3520000\
#      and exposed via the FETCHCONTENT_SOURCE_DIR_SQLITE3 environment variable.
#   2. sqlite3.x64.windows.dll         (used by the sqlite3 Dart hook, which
#      would otherwise download it from GitHub Releases). Placed as
#      sqlite3.dll in the project's shared hook output directory so the hook
#      skips the download after SHA256 verification.
#
# Re-running this script is cheap: cached files are verified by SHA256 (for the
# DLL) or by existence (for the extracted source directory) and skipped.
#
# Usage:
#   .\scripts\prepare_sqlite_cache.ps1
#   .\scripts\prepare_sqlite_cache.ps1 -Force
#
# Environment variables set (process-scoped, inherited by child flutter calls):
#   FETCHCONTENT_SOURCE_DIR_SQLITE3  -> extracted source dir
#   SQLITE3_DLL_CACHE_PATH           -> cached DLL path (for diagnostics)

[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# --- Configuration -----------------------------------------------------------

# SQLite source tarball (must match sqlite3_flutter_libs-0.5.42/windows/CMakeLists.txt).
$SqliteVersion = "3520000"
$SqliteYearPath = "2026"
$SqliteTarballName = "sqlite-autoconf-$SqliteVersion.tar.gz"
$SqliteTarballUrls = @(
    "https://sqlite.org/$SqliteYearPath/$SqliteTarballName",
    "https://www.sqlite.org/$SqliteYearPath/$SqliteTarballName"
)

# Resolve the native DLL from the locked package's published hashes.
$projectRoot = Split-Path -Parent $PSScriptRoot
if (!(Test-Path -LiteralPath (Join-Path $projectRoot '.dart_tool\package_config.json'))) {
    Push-Location -LiteralPath $projectRoot
    try {
        flutter pub get --enforce-lockfile
        if ($LASTEXITCODE -ne 0) { throw 'Locked Flutter dependencies could not be prepared.' }
    } finally { Pop-Location }
}
. (Join-Path $PSScriptRoot 'sqlite_hook_asset.ps1')
$SqliteHookAsset = Get-SqliteHookAsset -ProjectRoot $projectRoot
$SqliteDllSha256 = $SqliteHookAsset.Sha256
$SqliteDllName = "sqlite3.x64.windows.dll"
$SqliteHookDllName = "sqlite3.dll"
$SqliteDllUrls = @($SqliteHookAsset.Url)

# Cache root under per-user LocalAppData (always ASCII).
$CacheRoot = Join-Path `
    ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) `
    "consumable_build_cache"

$SrcCacheDir = Join-Path $CacheRoot "sqlite-src"
$DllCacheDir = Join-Path $CacheRoot "sqlite-dll\$($SqliteHookAsset.Version)"
$TarballPath = Join-Path $SrcCacheDir $SqliteTarballName
$ExtractedSrcDir = Join-Path $SrcCacheDir "sqlite-autoconf-$SqliteVersion"
$DllCachePath = Join-Path $DllCacheDir $SqliteDllName

# --- Helpers -----------------------------------------------------------------

function Write-Step([string]$msg) {
    Write-Host "[sqlite-cache] $msg" -ForegroundColor Cyan
}

function Write-Ok([string]$msg) {
    Write-Host "[sqlite-cache] $msg" -ForegroundColor Green
}

function Test-Sha256 {
    param([string]$Path, [string]$Expected)
    if (-not (Test-Path $Path)) { return $false }
    $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
    return $actual -eq $Expected.ToLower()
}

function Invoke-DownloadWithFallback {
    param(
        [string[]]$Urls,
        [string]$OutPath,
        [int]$TimeoutSeconds = 300
    )
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutPath) | Out-Null

    # Use TLS 1.2 + 1.3 to avoid handshake failures with modern CDNs.
    [System.Net.ServicePointManager]::SecurityProtocol =
        [System.Net.SecurityProtocolType]::Tls12 -bor `
        [System.Net.SecurityProtocolType]::Tls13

    $lastError = $null
    foreach ($url in $Urls) {
        Write-Step "Downloading $url"
        try {
            # Invoke-WebRequest in PS 5.1 shows a built-in progress bar and
            # supports -TimeoutSec. We download to a .tmp file first so a
            # partial download is never mistaken for a complete one.
            $tmpPath = "$OutPath.tmp"
            if (Test-Path $tmpPath) { Remove-Item -Force $tmpPath }

            # Suppress the per-iteration progress bar by overriding the
            # preference locally; we want IWR's own progress, not nested.
            $oldProgress = $ProgressPreference
            $ProgressPreference = 'Continue'
            try {
                Invoke-WebRequest -Uri $url -OutFile $tmpPath -TimeoutSec $TimeoutSeconds -UseBasicParsing
            } finally {
                $ProgressPreference = $oldProgress
            }

            if (-not (Test-Path $tmpPath) -or (Get-Item $tmpPath).Length -eq 0) {
                throw "Downloaded file is empty or missing."
            }
            if (Test-Path $OutPath) { Remove-Item -Force $OutPath }
            Move-Item -Path $tmpPath -Destination $OutPath -Force
            return $true
        } catch {
            $lastError = $_
            Write-Host "[sqlite-cache]   failed: $($_.Exception.Message)" -ForegroundColor Yellow
            if (Test-Path "$OutPath.tmp") { Remove-Item -Force "$OutPath.tmp" -ErrorAction SilentlyContinue }
            if (Test-Path $OutPath) { Remove-Item -Force $OutPath -ErrorAction SilentlyContinue }
        }
    }
    if ($lastError) { throw "All download URLs failed. Last error: $($lastError.Exception.Message)" }
    return $false
}

# --- Step 1: SQLite source tarball ------------------------------------------

New-Item -ItemType Directory -Force -Path $SrcCacheDir | Out-Null

$needSrc = $Force -or -not (Test-Path $ExtractedSrcDir) -or `
    -not (Test-Path (Join-Path $ExtractedSrcDir "sqlite3.c"))

if ($needSrc) {
    Write-Step "Caching SQLite source tarball"
    $needDownload = $Force -or -not (Test-Path $TarballPath)
    if ($needDownload) {
        Invoke-DownloadWithFallback -Urls $SqliteTarballUrls -OutPath $TarballPath -TimeoutSeconds 600 | Out-Null
    } else {
        Write-Step "Tarball already cached at $TarballPath"
    }

    # Extract using tar (bsdtar is bundled with Windows 10+).
    if (Test-Path $ExtractedSrcDir) {
        Remove-Item -Recurse -Force $ExtractedSrcDir
    }
    Write-Step "Extracting tarball"
    & tar -xzf $TarballPath -C $SrcCacheDir
    if ($LASTEXITCODE -ne 0) {
        throw "tar extraction failed (exit $LASTEXITCODE)"
    }
    if (-not (Test-Path (Join-Path $ExtractedSrcDir "sqlite3.c"))) {
        throw "Extraction did not produce expected sqlite3.c at $ExtractedSrcDir"
    }
    Write-Ok "Source extracted to $ExtractedSrcDir"
} else {
    Write-Ok "Source already extracted at $ExtractedSrcDir"
}

# Expose the source dir to CMake FetchContent override.
$env:FETCHCONTENT_SOURCE_DIR_SQLITE3 = $ExtractedSrcDir
Write-Ok "FETCHCONTENT_SOURCE_DIR_SQLITE3 = $ExtractedSrcDir"

# --- Step 2: Prebuilt Windows x64 DLL ---------------------------------------

New-Item -ItemType Directory -Force -Path $DllCacheDir | Out-Null

$needDll = $Force -or -not (Test-Sha256 -Path $DllCachePath -Expected $SqliteDllSha256)
if ($needDll -and !$Force) {
    $existingHook = Join-Path $projectRoot ".dart_tool\hooks_runner\shared\sqlite3\build\$($SqliteHookAsset.HookDirectory)\sqlite3.dll"
    if (Test-Sha256 -Path $existingHook -Expected $SqliteDllSha256) {
        Copy-Item -LiteralPath $existingHook -Destination $DllCachePath -Force
        $needDll = $false
        Write-Ok 'Reused the verified native asset from the current project.'
    }
}
if ($needDll) {
    Write-Step "Caching prebuilt sqlite3.x64.windows.dll"
    Invoke-DownloadWithFallback -Urls $SqliteDllUrls -OutPath $DllCachePath -TimeoutSeconds 300 | Out-Null
    if (-not (Test-Sha256 -Path $DllCachePath -Expected $SqliteDllSha256)) {
        throw "SHA256 mismatch for $DllCachePath (expected $SqliteDllSha256)"
    }
    Write-Ok "DLL cached and verified at $DllCachePath"
} else {
    Write-Ok "DLL already cached and verified at $DllCachePath"
}

$env:SQLITE3_DLL_CACHE_PATH = $DllCachePath
$env:SQLITE3_DLL_CACHE_SHA256 = $SqliteDllSha256

# --- Step 3: Place DLL into the project's Dart hook cache -------------------

# The sqlite3 Dart hook checks for a
# cached DLL at <project>/.dart_tool/hooks_runner/shared/sqlite3/build/
# download-<first8hashchars>/sqlite3.dll. The download source has a
# platform-qualified name, but the hook normalizes bundled Windows libraries
# to sqlite3.dll before checking the shared cache.
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$hookCacheDir = Join-Path $projectRoot ".dart_tool\hooks_runner\shared\sqlite3\build\download-$($SqliteDllSha256.Substring(0, 8))"
$hookCachePath = Join-Path $hookCacheDir $SqliteHookDllName

$needHookCopy = $Force -or -not (Test-Sha256 -Path $hookCachePath -Expected $SqliteDllSha256)
if ($needHookCopy) {
    Write-Step "Placing DLL into Dart hook cache"
    New-Item -ItemType Directory -Force -Path $hookCacheDir | Out-Null
    Copy-Item -Force $DllCachePath $hookCachePath
    Write-Ok "DLL placed at $hookCachePath"
} else {
    Write-Ok "Dart hook cache already populated at $hookCachePath"
}

# --- Step 4: Also place DLL into the staging directory copy if it exists -----
# When build_windows.ps1 stages the project to an ASCII temp dir, the
# .dart_tool directory is excluded from robocopy (too large / regeneratable).
# The Dart hook will re-create its cache in the staging dir on first build.
# We export the cache path so the staging script can pre-populate it.

Write-Host ""
Write-Ok "SQLite cache preparation complete."
Write-Host "[sqlite-cache] Source dir: $ExtractedSrcDir"
Write-Host "[sqlite-cache] DLL path:   $DllCachePath"
Write-Host "[sqlite-cache] DLL sha256: $SqliteDllSha256"
