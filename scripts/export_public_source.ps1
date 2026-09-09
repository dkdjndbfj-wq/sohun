[CmdletBinding()]
param(
    [string]$Destination,
    [switch]$CoreAssets = $true
)

$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Split-Path -Parent $PSScriptRoot))
$publicRoot = Join-Path $repoRoot 'public_release'
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $publicRoot ("sohun-source-" + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0, 8))
}
$Destination = [IO.Path]::GetFullPath($Destination)
if (-not $Destination.StartsWith($publicRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Public source exports must use a new directory beneath public_release.'
}
if (Test-Path -LiteralPath $Destination) { throw 'The export destination already exists; existing exports are never overwritten.' }
if (-not (Get-Command rg -ErrorAction SilentlyContinue)) { throw 'ripgrep is required for the source export.' }

# Enumerate only maintained source trees. Operational notes, personal files and
# local release artifacts are outside the candidate set from the beginning.
$sourceDirectories = @(
    '.github', '.agents/skills/sohun-validation', 'scripts',
    '电脑软件/lib', '电脑软件/test', '电脑软件/windows', '电脑软件/android',
    '电脑软件/installer', '电脑软件/scripts', '电脑软件/assets',
    '电脑软件/community_server/src', '电脑软件/community_server/test',
    '电脑软件/community_server/scripts', '电脑软件/community_server/policies',
    '官网网页制作/src', '官网网页制作/test', '官网网页制作/public',
    '手机软件/src', '手机软件/public'
)
$sourceFiles = @(
    '.gitignore', 'AGENTS.md', 'README.md', 'LICENSE', 'DEPLOYMENT.md', 'PUBLIC_RELEASE_MANIFEST.md',
    '电脑软件/.gitignore', '电脑软件/.metadata', '电脑软件/pubspec.yaml', '电脑软件/pubspec.lock',
    '电脑软件/analysis_options.yaml', '电脑软件/build_release.ps1', '电脑软件/README.md',
    '电脑软件/THIRD_PARTY_NOTICES.md', '电脑软件/release-clearance.example.json',
    '电脑软件/community_server/package.json', '电脑软件/community_server/package-lock.json',
    '电脑软件/community_server/README.md', '电脑软件/community_server/.gitignore',
    '官网网页制作/package.json', '官网网页制作/package-lock.json', '官网网页制作/README.md',
    '官网网页制作/.gitignore', '官网网页制作/.env.example',
    '手机软件/package.json', '手机软件/package-lock.json', '手机软件/index.html',
    '手机软件/README.md', '手机软件/.gitignore',
    'docs/development-workflow.md', 'docs/app-update-policy.md', 'docs/bambu-feed-compatibility.md',
    'docs/bambu-printer-fault-alerts.md', 'docs/windows-build-repair-2026-09-06.md',
    'docs/glass-button-system.md', 'docs/agent-workflow-audit-2026-09-06.md',
    '电脑软件/docs/手机RFID模板使用说明.md', '电脑软件/docs/NTAG213设备工作台使用说明.md'
)
$excludedTrees = @(
    '电脑软件/assets/images/bambu_icons/', '电脑软件/assets/bambu_presets/',
    '电脑软件/assets/bin/', '电脑软件/assets/tools/'
)
if ($CoreAssets) {
    # The core prerelease does not redistribute the imported manufacturer fault
    # prose or calibration model. Online lookups and user-provided files remain
    # available; this switch does not manufacture third-party clearance.
    $excludedTrees += @('电脑软件/assets/knowledge/', '电脑软件/assets/calibration/')
}
$excludedSegments = @('.git', '.gradle', '.kotlin', '.dart_tool', '.dart-tool-home', '.deploy', '.playwright-cli', 'node_modules', 'build', 'dist', 'coverage', 'ephemeral', 'failures', '.cxx', '__pycache__')
$excludedExtensions = @('.pem', '.key', '.p12', '.pfx', '.jks', '.keystore', '.db', '.db3', '.sqlite', '.sqlite3', '.log', '.bak', '.backup', '.zip', '.7z', '.rar', '.exe', '.dll', '.so', '.dylib', '.cer', '.class', '.jar', '.iml', '.pyc', '.pyo')

function Test-PublicCandidate([string]$Relative) {
    $segments = $Relative.Split('/')
    foreach ($segment in $segments) { if ($segment -in $excludedSegments) { return $false } }
    foreach ($prefix in $excludedTrees) { if ($Relative.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $false } }
    $leaf = $segments[-1]
    if ([IO.Path]::GetExtension($leaf).ToLowerInvariant() -in $excludedExtensions) { return $false }
    if ($leaf -match '\.(db|sqlite|sqlite3)-(wal|shm|journal)$') { return $false }
    if ($leaf -like '.env*' -and $leaf -ne '.env.example') { return $false }
    if ($leaf -in @('local.properties', 'key.properties', 'release-clearance.json')) { return $false }
    if ($Relative -like '电脑软件/android/*' -and $leaf -in @('gradlew', 'gradlew.bat', 'GeneratedPluginRegistrant.java')) { return $false }
    if ($Relative.StartsWith('电脑软件/scripts/') -and $leaf -like '*.py') { return $false }
    return $true
}

Push-Location $repoRoot
try {
    $rgArguments = @('--files', '--hidden', '--no-ignore')
    foreach ($segment in $excludedSegments) { $rgArguments += @('--glob', "!**/$segment/**") }
    $rgArguments += $sourceDirectories
    $enumerated = @(& rg @rgArguments)
    if ($LASTEXITCODE -ne 0) { throw "Unable to enumerate maintained source trees (exit $LASTEXITCODE)." }
    $candidates = @($enumerated + $sourceFiles | ForEach-Object { $_.Replace('\', '/') } | Sort-Object -Unique)
    $selected = @($candidates | Where-Object { Test-PublicCandidate $_ })
    foreach ($relative in $selected) {
        $source = Join-Path $repoRoot $relative
        if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Required public source file is missing: $relative" }
        if (((Get-Item -LiteralPath $source -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Public source must not follow linked files: $relative"
        }
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    foreach ($relative in $selected) {
        $target = Join-Path $Destination $relative
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $target
    }

    # Flutter asset directories remain present without copying restricted bytes.
    foreach ($directory in @('电脑软件/assets/images/bambu_icons', '电脑软件/assets/bambu_presets/process', '电脑软件/assets/bambu_presets/filament', '电脑软件/assets/bambu_presets/machine', '电脑软件/assets/bin', '电脑软件/assets/tools', '电脑软件/assets/knowledge', '电脑软件/assets/calibration')) {
        $folder = Join-Path $Destination $directory
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $folder '.gitkeep'), '', [Text.UTF8Encoding]::new($false))
    }
    $ignore = Join-Path $Destination '.gitignore'
    [IO.File]::AppendAllText($ignore, "`n# Public end-user guides and required SQLite build helpers.`n!/电脑软件/docs/手机RFID模板使用说明.md`n!/电脑软件/docs/NTAG213设备工作台使用说明.md`n!/电脑软件/scripts/sqlite_hook_asset.ps1`n!/电脑软件/scripts/test_sqlite_hook_asset.ps1`n", [Text.UTF8Encoding]::new($false))
    $serverReadme = Join-Path $Destination '电脑软件/community_server/README.md'
    $readme = [IO.File]::ReadAllText($serverReadme)
    $readme = [regex]::Replace($readme, '(?s)\A(# 耗材工作台社区服务\r?\n).*?(这是软件账号和参数广场的自托管 API。)', '$1' + "`n自托管配置见仓库根目录 [DEPLOYMENT.md](../../DEPLOYMENT.md)。`n`n" + '$2', 1)
    [IO.File]::WriteAllText($serverReadme, $readme, [Text.UTF8Encoding]::new($false))
    if ($CoreAssets) {
        $clientRoot = Join-Path $Destination '电脑软件'
        $pubspecPath = Join-Path $clientRoot 'pubspec.yaml'
        $pubspec = [IO.File]::ReadAllText($pubspecPath)
        $pubspec = [regex]::Replace($pubspec, '(?m)^  media_kit_libs_windows_video:[^\r\n]*\r?\n', '')
        [IO.File]::WriteAllText($pubspecPath, $pubspec, [Text.UTF8Encoding]::new($false))
        $lockPath = Join-Path $clientRoot 'pubspec.lock'
        $lock = [IO.File]::ReadAllText($lockPath)
        # This optional package depends only on Flutter, already required by
        # the app; no other locked dependencies are removed or re-resolved.
        $lock = [regex]::Replace($lock, '(?ms)^  media_kit_libs_windows_video:\r?\n.*?(?=^  [a-zA-Z0-9_]+:|^sdks:)', '')
        [IO.File]::WriteAllText($lockPath, $lock, [Text.UTF8Encoding]::new($false))
        $coreMarker = [ordered]@{ schemaVersion = 1; product = 'sohun-core-preview'; signedRelease = $false; omittedAssets = $excludedTrees; optionalNativeVideo = $false }
        [IO.File]::WriteAllText((Join-Path $clientRoot 'core-build.json'), ($coreMarker | ConvertTo-Json -Depth 4) + "`n", [Text.UTF8Encoding]::new($false))
        & (Join-Path $clientRoot 'scripts/Test-CoreSource.ps1') -ProjectRoot $clientRoot
    }

    $files = @(& rg --files --hidden --no-ignore $Destination | Sort-Object)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate the exported files.' }
    $entries = @($files | ForEach-Object {
        $item = Get-Item -LiteralPath $_ -Force
        [ordered]@{ path = $item.FullName.Substring($Destination.Length + 1).Replace('\', '/'); bytes = $item.Length; sha256 = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = [ordered]@{
        schemaVersion = 1
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        purpose = 'Public source export; not a signed binary or third-party release clearance.'
        coreAssets = [bool]$CoreAssets
        omittedAssetTrees = $excludedTrees
        omittedPrivateMaterial = @('credentials', 'databases and backups', 'operational client docs', 'local logs and screenshots', 'build caches', 'native runtime binaries')
        preservedCapabilities = @('CUID/FUID inventory and reusable tag lifecycle source', 'Android NFC and local encrypted template source without template data', 'NTAG213 independent device workbench', 'personal inventory and device APIs', 'official website', 'related tests and build scripts')
        resourceReview = 'THIRD_PARTY_NOTICES.md remains authoritative. Keeping attributed source data is not a clearance declaration for a distributable binary.'
        fileCount = $entries.Count
        files = $entries
    }
    $manifestPath = Join-Path $Destination 'PUBLIC_SOURCE_EXPORT.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json -Depth 8) + "`n", [Text.UTF8Encoding]::new($false))
    $verification = & (Join-Path $PSScriptRoot 'verify_public_source.ps1') -SourceStage $Destination
    [pscustomobject]@{ Destination = $Destination; Files = $verification.Files; ManifestSha256 = $verification.ManifestSha256 }
} finally { Pop-Location }
