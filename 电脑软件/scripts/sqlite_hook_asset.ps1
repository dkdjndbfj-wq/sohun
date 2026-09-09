function Get-SqliteHookAsset {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$ProjectRoot)

    $lockPath = Join-Path $ProjectRoot 'pubspec.lock'
    $lock = Get-Content -Raw -LiteralPath $lockPath
    $section = [regex]::Match($lock, '(?ms)^  sqlite3:\r?\n(.*?)(?=^  [^\s]|\z)').Groups[1].Value
    $version = [regex]::Match($section, '(?m)^    version: "([^"]+)"').Groups[1].Value
    if ($version -notmatch '^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$') {
        throw 'pubspec.lock does not contain a supported sqlite3 package version.'
    }
    $configPath = Join-Path $ProjectRoot '.dart_tool\package_config.json'
    if (!(Test-Path -LiteralPath $configPath)) {
        throw 'Run flutter pub get --enforce-lockfile before resolving the SQLite native asset.'
    }
    $config = Get-Content -Raw -LiteralPath $configPath | ConvertFrom-Json
    $package = @($config.packages | Where-Object name -EQ 'sqlite3')
    if ($package.Count -ne 1) { throw 'The resolved package config must contain one sqlite3 package.' }
    $rootUri = [Uri]::new([Uri]::new([IO.Path]::GetFullPath($configPath)), [string]$package[0].rootUri)
    if (!$rootUri.IsFile) { throw 'The resolved sqlite3 package must be a local directory.' }
    $packageRoot = $rootUri.LocalPath
    $pubspec = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'pubspec.yaml')
    $resolvedVersion = [regex]::Match($pubspec, '(?m)^version:\s*([^\s]+)').Groups[1].Value.Trim('"', "'")
    if ($version -ne $resolvedVersion) {
        throw 'The resolved SQLite package differs from pubspec.lock. Run flutter pub get --enforce-lockfile.'
    }
    $hashSource = Get-Content -Raw -LiteralPath (Join-Path $packageRoot 'lib\src\hook\asset_hashes.dart')
    $hash = [regex]::Match($hashSource, "'sqlite3\.x64\.windows\.dll':\s*'(?<hash>[0-9a-f]{64})'").Groups['hash'].Value
    if (!$hash) { throw 'The locked sqlite3 package does not publish a Windows x64 DLL checksum.' }
    [pscustomobject]@{
        Version = $version
        Sha256 = $hash
        Url = "https://github.com/simolus3/sqlite3.dart/releases/download/sqlite3-$version/sqlite3.x64.windows.dll"
        HookDirectory = "download-$($hash.Substring(0, 8))"
    }
}
