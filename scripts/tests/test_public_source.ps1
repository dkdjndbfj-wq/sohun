# Isolated public-source integrity checks plus one real repository export.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$verify = Join-Path $repoRoot 'scripts/verify_public_source.ps1'
$export = Join-Path $repoRoot 'scripts/export_public_source.ps1'
$coreBuild = Join-Path $repoRoot 'scripts/public_core_build.ps1'
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sohun-public-source-' + [Guid]::NewGuid().ToString('N'))
$repositoryExport = Join-Path $repoRoot ('public_release/verification-' + [Guid]::NewGuid().ToString('N'))
$passed = 0

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Expect-Rejection([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    if ($null -eq $caught -or $caught.ToString() -notmatch $Pattern) {
        throw "Expected public-source rejection: $Pattern"
    }
}

function Write-Text([string]$Root, [string]$Relative, [string]$Text = 'fixture') {
    $path = Join-Path $Root $Relative
    New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
    [IO.File]::WriteAllText($path, $Text, [Text.UTF8Encoding]::new($false))
    return $path
}

function Write-Manifest([string]$Root) {
    $files = @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force |
        Where-Object Name -ne 'PUBLIC_SOURCE_EXPORT.json' |
        Sort-Object FullName)
    $entries = @($files | ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($Root.Length + 1).Replace('\', '/')
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $manifest = [ordered]@{
        schemaVersion = 1
        createdAt = [DateTimeOffset]::UtcNow.ToString('o')
        purpose = 'Public source export; isolated test fixture.'
        coreAssets = $true
        fileCount = $entries.Count
        files = $entries
    }
    [IO.File]::WriteAllText(
        (Join-Path $Root 'PUBLIC_SOURCE_EXPORT.json'),
        ($manifest | ConvertTo-Json -Depth 6) + "`n",
        [Text.UTF8Encoding]::new($false)
    )
}

function New-Stage([string]$Name) {
    $root = Join-Path $fixtureRoot $Name
    [void](Write-Text $root 'README.md' '# clean fixture')
    [void](Write-Text $root '电脑软件/core-build.json' '{"schemaVersion":1,"product":"sohun-core-preview","signedRelease":false}')
    [void](Write-Text $root '电脑软件/assets/bin/.gitkeep' '')
    Write-Manifest $root
    return $root
}

function Pass([string]$Name) {
    $script:passed++
    Write-Host "PASS: $Name"
}

try {
    $clean = New-Stage 'clean'
    $result = & $verify -SourceStage $clean
    Assert-Condition ($result.Files -eq 3) 'Clean fixture file count changed.'
    Pass 'complete clean snapshot'

    $extra = New-Stage 'unlisted'
    [void](Write-Text $extra '电脑软件/lib/injected.dart' 'void main() {}')
    Expect-Rejection { & $verify -SourceStage $extra } 'unlisted:'
    Pass 'unlisted file after export'

    $changed = New-Stage 'changed'
    [IO.File]::AppendAllText((Join-Path $changed 'README.md'), "`nchanged")
    Expect-Rejection { & $verify -SourceStage $changed } 'changed after export'
    Pass 'listed file changed after export'

    $missing = New-Stage 'missing'
    Remove-Item -LiteralPath (Join-Path $missing 'README.md')
    Expect-Rejection { & $verify -SourceStage $missing } 'missing:'
    Pass 'listed file missing after export'

    $unsafe = New-Stage 'unsafe-path'
    $unsafeManifestPath = Join-Path $unsafe 'PUBLIC_SOURCE_EXPORT.json'
    $unsafeManifest = Get-Content -LiteralPath $unsafeManifestPath -Raw | ConvertFrom-Json
    $unsafeManifest.files[0].path = '../outside.txt'
    [IO.File]::WriteAllText($unsafeManifestPath, ($unsafeManifest | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
    Expect-Rejection { & $verify -SourceStage $unsafe } 'unsafe path'
    Pass 'manifest path traversal'

    $restricted = New-Stage 'restricted-core-asset'
    [void](Write-Text $restricted '电脑软件/assets/bin/bambu_networking.dll' 'binary placeholder')
    Write-Manifest $restricted
    Expect-Rejection { & $verify -SourceStage $restricted } 'private or generated file type|excluded reference asset'
    Pass 'excluded Core asset'

    $database = New-Stage 'database'
    [void](Write-Text $database '电脑软件/test.sqlite' 'private rows')
    Write-Manifest $database
    Expect-Rejection { & $verify -SourceStage $database } 'private or generated file type'
    Pass 'database file'

    $credential = New-Stage 'credential'
    $fakeCredential = 'github_pat_' + ('A' * 40)
    [void](Write-Text $credential '电脑软件/lib/accidental_secret.txt' $fakeCredential)
    Write-Manifest $credential
    Expect-Rejection { & $verify -SourceStage $credential } 'possible private data'
    Pass 'high-confidence credential content'

    $personalPath = New-Stage 'personal-path'
    $absoluteUserPathFixture = 'cd C:' + '\Users\release-owner\Desktop\sohun'
    [void](Write-Text $personalPath '手机软件/README.md' $absoluteUserPathFixture)
    Write-Manifest $personalPath
    Expect-Rejection { & $verify -SourceStage $personalPath } 'possible private data'
    Pass 'absolute Windows user profile path'

    $adminEndpoint = New-Stage 'admin-endpoint'
    $adminConnectionFixture = 'ssh root@' + '203.0.113.77'
    [void](Write-Text $adminEndpoint '电脑软件/lib/operations.txt' $adminConnectionFixture)
    Write-Manifest $adminEndpoint
    Expect-Rejection { & $verify -SourceStage $adminEndpoint } 'possible private data'
    Pass 'administrative server endpoint'

    $privateDoc = New-Stage 'private-doc'
    [void](Write-Text $privateDoc '电脑软件/docs/internal-operations.md' 'private operations')
    Write-Manifest $privateDoc
    Expect-Rejection { & $verify -SourceStage $privateDoc } 'non-public client document'
    Pass 'non-public client document'

    $exportResult = & $export -Destination $repositoryExport -CoreAssets
    $verifiedExport = & $verify -SourceStage $repositoryExport
    Assert-Condition ($exportResult.ManifestSha256 -eq $verifiedExport.ManifestSha256) 'Repository export manifest hash changed.'
    Assert-Condition ($verifiedExport.CoreAssets -eq $true) 'Repository export was not a Core snapshot.'
    Pass 'real repository Core export'

    $rejectedOutput = Join-Path $fixtureRoot 'tag-mismatch-output'
    Expect-Rejection {
        & $coreBuild -SourceStage $repositoryExport -ExpectedTag 'core-v0.0.0+0' `
            -OutputDirectory $rejectedOutput
    } 'tag must match pubspec\.yaml'
    Assert-Condition (-not (Test-Path -LiteralPath $rejectedOutput)) 'Tag mismatch started a build.'
    Pass 'Core release tag must match pubspec version'

    Write-Host "$passed public source boundary checks passed."
    $global:LASTEXITCODE = 0
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedFixture) -notmatch '^sohun-public-source-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected fixture directory: $resolvedFixture"
    }
    if (Test-Path -LiteralPath $resolvedFixture) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }

    $resolvedExport = [IO.Path]::GetFullPath($repositoryExport)
    $publicBase = [IO.Path]::GetFullPath((Join-Path $repoRoot 'public_release')).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedExport.StartsWith($publicBase, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedExport) -notmatch '^verification-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected repository export: $resolvedExport"
    }
    if (Test-Path -LiteralPath $resolvedExport) {
        Remove-Item -LiteralPath $resolvedExport -Recurse -Force
    }
}
