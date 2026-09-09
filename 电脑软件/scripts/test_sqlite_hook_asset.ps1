$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'sqlite_hook_asset.ps1')
$temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
$fixture = Join-Path $temporaryRoot ('sohun_sqlite_asset_test_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path "$fixture\client\.dart_tool", "$fixture\cache\sqlite3\lib\src\hook" -Force | Out-Null
try {
    $client = "$fixture\client"
    $package = "$fixture\cache\sqlite3"
    $expected = 'a' * 64
    "packages:`n  sqlite3:`n    dependency: direct main`n    version: `"9.9.9`"`nsdks:`n  dart: `">=3.10.0`"" |
        Set-Content -LiteralPath "$client\pubspec.lock" -Encoding utf8
    'version: 9.9.9' | Set-Content -LiteralPath "$package\pubspec.yaml" -Encoding utf8
    "const hashes = {'sqlite3.x64.windows.dll': '$expected'};" |
        Set-Content -LiteralPath "$package\lib\src\hook\asset_hashes.dart" -Encoding utf8
    @{ packages = @(@{ name='sqlite3'; rootUri='../../cache/sqlite3/' }) } |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$client\.dart_tool\package_config.json" -Encoding utf8
    $asset = Get-SqliteHookAsset -ProjectRoot $client
    if ($asset.Version -ne '9.9.9' -or $asset.Sha256 -ne $expected -or
        $asset.Url -notmatch '/sqlite3-9\.9\.9/' -or $asset.HookDirectory -ne 'download-aaaaaaaa') {
        throw 'The asset must be resolved from the locked package, including relative package URIs.'
    }
    Write-Output 'PASS: SQLite DLL version and hash come from the locked package'
    'version: 9.9.8' | Set-Content -LiteralPath "$package\pubspec.yaml" -Encoding utf8
    $rejected = $false
    try { Get-SqliteHookAsset -ProjectRoot $client | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'A stale package configuration was accepted.' }
    Write-Output 'PASS: mismatched package configuration fails before downloading'
    'version: 9.9.9' | Set-Content -LiteralPath "$package\pubspec.yaml" -Encoding utf8
    "const hashes = {'sqlite3.x64.windows.dll': 'invalid'};" |
        Set-Content -LiteralPath "$package\lib\src\hook\asset_hashes.dart" -Encoding utf8
    $rejected = $false
    try { Get-SqliteHookAsset -ProjectRoot $client | Out-Null } catch { $rejected = $true }
    if (!$rejected) { throw 'An invalid native asset hash was accepted.' }
    Write-Output 'PASS: missing or malformed upstream checksum is rejected'
} finally {
    $resolved = [IO.Path]::GetFullPath($fixture)
    if (!$resolved.StartsWith("$temporaryRoot\sohun_sqlite_asset_test_", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unexpected test fixture cleanup path.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
