# Verifies that a public source snapshot is complete, immutable and free of
# material that is excluded from the public Core preview.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$SourceStage
)

$ErrorActionPreference = 'Stop'
if (-not (Get-Command rg -ErrorAction SilentlyContinue)) {
    throw 'ripgrep is required to verify a public source snapshot.'
}

$SourceStage = [IO.Path]::GetFullPath($SourceStage).TrimEnd('\', '/')
if (-not (Test-Path -LiteralPath $SourceStage -PathType Container)) {
    throw "Public source snapshot does not exist: $SourceStage"
}
$manifestPath = Join-Path $SourceStage 'PUBLIC_SOURCE_EXPORT.json'
if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'The public source snapshot has no export manifest.'
}

$linkedItems = @(Get-ChildItem -LiteralPath $SourceStage -Recurse -Force |
    Where-Object { ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0 })
if ($linkedItems.Count -gt 0) {
    $linkedNames = @($linkedItems | ForEach-Object {
        $_.FullName.Substring($SourceStage.Length + 1).Replace('\', '/')
    })
    throw "Public source snapshots must not contain linked files or directories: $($linkedNames -join ', ')"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
if ($manifest.schemaVersion -ne 1 -or $manifest.purpose -notmatch '^Public source export;') {
    throw 'The public source export manifest is invalid.'
}
$entries = @($manifest.files)
if ([int64]$manifest.fileCount -ne $entries.Count) {
    throw 'The public source export manifest file count is inconsistent.'
}

$expected = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($entry in $entries) {
    $relative = [string]$entry.path
    if ([string]::IsNullOrWhiteSpace($relative) -or
        $relative.Contains('\') -or
        $relative.StartsWith('/') -or
        $relative.Contains('//') -or
        $relative -match '(^|/)\.\.?(/|$)' -or
        $relative -match '^[A-Za-z]:' -or
        $relative.IndexOf([char]0) -ge 0) {
        throw "Public source manifest contains an unsafe path: $relative"
    }
    if ($expected.ContainsKey($relative)) {
        throw "Public source manifest contains a duplicate path: $relative"
    }
    $expected.Add($relative, $entry)
}

$actual = [Collections.Generic.Dictionary[string, IO.FileInfo]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($file in @(Get-ChildItem -LiteralPath $SourceStage -File -Recurse -Force)) {
    $relative = $file.FullName.Substring($SourceStage.Length + 1).Replace('\', '/')
    if ($relative -eq 'PUBLIC_SOURCE_EXPORT.json') { continue }
    if ($actual.ContainsKey($relative)) {
        throw "Public source snapshot contains case-colliding paths: $relative"
    }
    $actual.Add($relative, $file)
}

$unlisted = @($actual.Keys | Where-Object { -not $expected.ContainsKey($_) } | Sort-Object)
$missing = @($expected.Keys | Where-Object { -not $actual.ContainsKey($_) } | Sort-Object)
if ($unlisted.Count -gt 0 -or $missing.Count -gt 0) {
    $details = @()
    if ($unlisted.Count -gt 0) { $details += "unlisted: $($unlisted -join ', ')" }
    if ($missing.Count -gt 0) { $details += "missing: $($missing -join ', ')" }
    throw "Public source snapshot does not match its complete file manifest ($($details -join '; '))."
}

$excludedSegments = @(
    '.git', '.gradle', '.kotlin', '.dart_tool', '.dart-tool-home', '.deploy',
    '.playwright-cli', 'node_modules', 'build', 'dist', 'coverage', 'ephemeral',
    'failures', '.cxx', '__pycache__', 'public_release'
)
$excludedExtensions = @(
    '.pem', '.key', '.p12', '.pfx', '.jks', '.keystore', '.db', '.db3',
    '.sqlite', '.sqlite3', '.log', '.bak', '.backup', '.zip', '.7z', '.rar',
    '.exe', '.dll', '.so', '.dylib', '.cer', '.class', '.jar', '.iml', '.pyc', '.pyo'
)
$privatePrefixes = @(
    '客户信息运营台/', '电脑软件/tool/', '电脑软件/test/failures/',
    '官网网页制作/output/'
)
$allowedClientGuides = @(
    '电脑软件/docs/手机RFID模板使用说明.md',
    '电脑软件/docs/NTAG213设备工作台使用说明.md'
)
$coreAssetPrefixes = @(
    '电脑软件/assets/images/bambu_icons/',
    '电脑软件/assets/bambu_presets/',
    '电脑软件/assets/bin/',
    '电脑软件/assets/tools/',
    '电脑软件/assets/knowledge/',
    '电脑软件/assets/calibration/'
)

foreach ($relative in $actual.Keys) {
    $segments = $relative.Split('/')
    foreach ($segment in $segments) {
        if ($segment -in $excludedSegments) {
            throw "Public source contains a generated or private directory: $relative"
        }
    }
    foreach ($prefix in $privatePrefixes) {
        if ($relative.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Public source contains private workspace material: $relative"
        }
    }
    if ($relative.StartsWith('电脑软件/docs/', [StringComparison]::OrdinalIgnoreCase) -and
        $relative -notin $allowedClientGuides) {
        throw "Public source contains a non-public client document: $relative"
    }
    $leaf = $segments[-1]
    $extension = [IO.Path]::GetExtension($leaf).ToLowerInvariant()
    if ($extension -in $excludedExtensions -or $leaf -match '\.(db|sqlite|sqlite3)-(wal|shm|journal)$') {
        throw "Public source contains a private or generated file type: $relative"
    }
    if (($leaf -like '.env*' -and $leaf -ne '.env.example') -or
        $leaf -in @('local.properties', 'key.properties', 'release-clearance.json')) {
        throw "Public source contains local configuration or release credentials: $relative"
    }
    if ($manifest.coreAssets -eq $true) {
        foreach ($prefix in $coreAssetPrefixes) {
            if ($relative.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and $leaf -ne '.gitkeep') {
                throw "Public Core source contains an excluded reference asset: $relative"
            }
        }
    }

    $entry = $expected[$relative]
    if ([int64]$entry.bytes -ne $actual[$relative].Length -or
        [string]$entry.sha256 -notmatch '^[0-9a-f]{64}$' -or
        (Get-FileHash -LiteralPath $actual[$relative].FullName -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$entry.sha256) {
        throw "Public source snapshot changed after export: $relative"
    }
}

# Report only file names. Matching credential text is never printed.
$secretPattern = 'github_pat_[A-Za-z0-9_]{30,}|gh[pousr]_[A-Za-z0-9]{30,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_-]{30,}|-----BEGIN (RSA |OPENSSH |EC )?PRIVATE KEY-----|root@(?:[0-9]{1,3}\.){3}[0-9]{1,3}|(?i:[A-Z]:[\\/]+Users[\\/])|(?i:%5CUser[s]%5C)'
$secretFiles = @(& rg -l --hidden --no-ignore --glob '!PUBLIC_SOURCE_EXPORT.json' -- $secretPattern $SourceStage)
$secretExit = $LASTEXITCODE
if ($secretExit -gt 1) { throw 'Public source credential scan could not complete.' }
if ($secretFiles.Count -gt 0) {
    $safeNames = @($secretFiles | ForEach-Object {
        $resolved = [IO.Path]::GetFullPath($_)
        if ($resolved.StartsWith($SourceStage + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
            $resolved.Substring($SourceStage.Length + 1).Replace('\', '/')
        } else {
            [IO.Path]::GetFileName($resolved)
        }
    })
    throw "Public source review required; possible private data in: $($safeNames -join ', ')"
}

if ($manifest.coreAssets -eq $true) {
    $markerPath = Join-Path $SourceStage '电脑软件/core-build.json'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'Public Core source is missing its core-build.json marker.'
    }
    $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($marker.schemaVersion -ne 1 -or $marker.product -ne 'sohun-core-preview' -or $marker.signedRelease -ne $false) {
        throw 'Public Core source marker is invalid.'
    }
}

Write-Host "[public-source] Verified $($actual.Count) files against the complete export manifest."
[pscustomobject]@{
    SourceStage = $SourceStage
    Files = $actual.Count
    CoreAssets = [bool]$manifest.coreAssets
    ManifestSha256 = (Get-FileHash -LiteralPath $manifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
}
