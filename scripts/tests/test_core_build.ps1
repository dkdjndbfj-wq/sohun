# Isolated boundary checks. No product SDK, credentials, or remote writes.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$clientRoot = Join-Path $repoRoot '电脑软件'
$sourceCheck = Join-Path $clientRoot 'scripts/Test-CoreSource.ps1'
$bundleCheck = Join-Path $clientRoot 'scripts/Test-CoreBundle.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sohun-core-check-' + [Guid]::NewGuid().ToString('N'))
$passed = 0
function Write-Fixture([string]$Relative, [string]$Text = 'fixture') {
    $file = Join-Path $fixtureRoot $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $file) -Force | Out-Null
    [IO.File]::WriteAllText($file, $Text)
    return $file
}
function Expect-Rejection([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.ToString() -notmatch $Pattern) { throw "Expected boundary rejection: $Pattern" }
}
try {
    $windowsBuild = [IO.File]::ReadAllText((Join-Path $clientRoot 'scripts/build_windows.ps1'))
    if ($windowsBuild -notmatch 'Refusing to mix old and new build files' -or
        $windowsBuild -notmatch 'if \(Test-Path -LiteralPath \$projectBuildDir\)') {
        throw 'Windows packaging must stop when the previous output remains locked.'
    }
    $passed++
    $source = Join-Path $fixtureRoot 'source'
    [void](Write-Fixture 'source/pubspec.yaml' "name: fixture`ndependencies:`n  flutter:`n    sdk: flutter`n")
    [void](Write-Fixture 'source/pubspec.lock' "packages: {}`n")
    Expect-Rejection { & $sourceCheck -ProjectRoot $source } 'require an exported core source'
    $passed++
    [void](Write-Fixture 'source/core-build.json' '{"schemaVersion":1,"product":"sohun-core-preview","signedRelease":false}')
    [void](Write-Fixture 'source/assets/bin/.gitkeep' '')
    & $sourceCheck -ProjectRoot $source
    $passed++
    $restricted = Write-Fixture 'source/assets/bin/bambu_networking.dll'
    Expect-Rejection { & $sourceCheck -ProjectRoot $source } 'excluded reference assets'
    Remove-Item -LiteralPath $restricted
    $passed++
    [void](Write-Fixture 'source/pubspec.yaml' "dependencies:`n  media_kit_libs_windows_video: ^1.0.11`n")
    Expect-Rejection { & $sourceCheck -ProjectRoot $source } 'optional native video'
    [void](Write-Fixture 'source/pubspec.yaml' "dependencies: {}`n")
    [void](Write-Fixture 'source/pubspec.lock' "packages:`n  media_kit_libs_windows_video:`n    version: 1.0.11`n")
    Expect-Rejection { & $sourceCheck -ProjectRoot $source } 'optional native video'
    $passed++
    $bundle = Join-Path $fixtureRoot 'bundle'
    [void](Write-Fixture 'bundle/sohun.exe')
    [void](Write-Fixture 'bundle/flutter_windows.dll')
    [void](Write-Fixture 'bundle/data/flutter_assets/assets/bin/.gitkeep' '')
    & $bundleCheck -BundlePath $bundle
    $passed++
    $restricted = Write-Fixture 'bundle/libmpv-2.dll'
    Expect-Rejection { & $bundleCheck -BundlePath $bundle } 'Excluded optional native'
    Remove-Item -LiteralPath $restricted
    $passed++
    $restricted = Write-Fixture 'bundle/data/flutter_assets/assets/knowledge/printer_faults_zh_CN.json' '{}'
    Expect-Rejection { & $bundleCheck -BundlePath $bundle } 'Excluded reference asset'
    Remove-Item -LiteralPath $restricted
    $passed++
    $restricted = Write-Fixture 'bundle/account.sqlite'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $apk = Join-Path $fixtureRoot 'leaking.apk'
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $apk)
    Expect-Rejection { & $bundleCheck -BundlePath $apk } 'Private data'
    Remove-Item -LiteralPath $restricted
    $passed++
    $restricted = Write-Fixture 'bundle/account.sqlite-wal'
    Expect-Rejection { & $bundleCheck -BundlePath $bundle } 'Private data'
    Remove-Item -LiteralPath $restricted
    $passed++
    $unsafeArchive = Join-Path $fixtureRoot 'unsafe.zip'
    Add-Type -AssemblyName System.IO.Compression
    $stream = [IO.File]::Open($unsafeArchive, [IO.FileMode]::CreateNew)
    try {
        $unsafeZip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false)
        try { [void]$unsafeZip.CreateEntry('../outside.txt') } finally { $unsafeZip.Dispose() }
    } finally { $stream.Dispose() }
    Expect-Rejection { & $bundleCheck -BundlePath $unsafeArchive } 'Unsafe path'
    $passed++
    $zip = Join-Path $fixtureRoot 'clean.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($bundle, $zip)
    & $bundleCheck -BundlePath $zip
    $passed++
    Write-Host "$passed core source and packaging boundary checks passed."
    $global:LASTEXITCODE = 0
} finally {
    $resolved = [IO.Path]::GetFullPath($fixtureRoot)
    $expectedBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($expectedBase, [StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $resolved) -notmatch '^sohun-core-check-[0-9a-f]{32}$') {
        throw 'Unexpected fixture directory; refusing cleanup.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
