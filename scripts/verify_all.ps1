[CmdletBinding()]
param(
    [ValidateSet('All', 'Client', 'Server', 'Website', 'Prototype', 'Inventory')]
    [string[]]$Scope = @('All'),
    [switch]$IncludeBuild,
    [switch]$Core,
    [switch]$SkipInstall
)

$ErrorActionPreference = "Stop"
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$selectedScopes = @($Scope | Select-Object -Unique)
if ($selectedScopes -contains 'All') {
    $selectedScopes = @('Client', 'Server', 'Website', 'Prototype', 'Inventory')
}
if ($selectedScopes.Count -eq 0) { throw 'Select at least one verification scope.' }
if ($IncludeBuild -and $selectedScopes -notcontains 'Client') {
    throw '-IncludeBuild requires the Client or All scope.'
}

function Find-Project {
    param([string[]]$Markers)
    $projects = @(Get-ChildItem -LiteralPath $workspaceRoot -Directory | Where-Object {
        $directory = $_.FullName
        @($Markers | Where-Object {
            -not (Test-Path -LiteralPath (Join-Path $directory $_))
        }).Count -eq 0
    })
    if ($projects.Count -ne 1) {
        throw "Expected one project matching $($Markers -join ', '); found $($projects.Count)."
    }
    return $projects[0].FullName
}

function Invoke-CheckedCommand {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$Executable,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )
    Push-Location -LiteralPath $WorkingDirectory
    try {
        & $Executable @Arguments
        if ($LASTEXITCODE -ne 0) {
            throw "$Executable failed with exit code $LASTEXITCODE in $WorkingDirectory"
        }
    } finally {
        Pop-Location
    }
}

$needsFlutter = $selectedScopes -contains 'Client' -or $selectedScopes -contains 'Inventory'
$needsServer = $selectedScopes -contains 'Server' -or $selectedScopes -contains 'Inventory'
if ($needsFlutter -or $needsServer) {
    $mainProject = Find-Project @('pubspec.yaml', 'community_server/package.json')
    $serverProject = Join-Path $mainProject 'community_server'
}
if (-not $SkipInstall) {
    if ($needsServer) { Invoke-CheckedCommand $serverProject 'npm' @('ci') }
    if ($needsFlutter) { Invoke-CheckedCommand $mainProject 'flutter' @('pub', 'get') }
}

if ($selectedScopes -contains 'Client') {
    & (Join-Path $mainProject 'scripts/test_windows_runtime_bundle.ps1')
    & (Join-Path $PSScriptRoot 'analyze_dart.ps1') -ProjectPath $mainProject
    # Historical database migration fixtures exhaust native resources at the
    # default tester concurrency. Two workers keep this gate deterministic.
    $testArguments = @('test', '--no-pub', '--concurrency=2')
    if ($Core) { $testArguments += '--dart-define=SOHUN_CORE_BUILD=true' }
    if ($selectedScopes -contains 'Inventory') {
        $testArguments += '--dart-define=RUN_INVENTORY_HTTP_TESTS=true'
    }
    Invoke-CheckedCommand $mainProject 'flutter' $testArguments
} elseif ($selectedScopes -contains 'Inventory') {
    # Uses an isolated local API and temporary databases, never production.
    Invoke-CheckedCommand $mainProject 'flutter' @(
        'test', '--no-pub', '--concurrency=1',
        '--dart-define=RUN_INVENTORY_HTTP_TESTS=true',
        'test/integration'
    )
}

$auditArguments = @(
    "audit", "--omit=dev", "--registry=https://registry.npmjs.org",
    "--fetch-retries=2", "--fetch-retry-factor=2",
    "--fetch-retry-maxtimeout=60000", "--fetch-timeout=30000"
)
if ($selectedScopes -contains 'Server') {
    Invoke-CheckedCommand $serverProject 'npm' @('test')
    Invoke-CheckedCommand $serverProject 'npm' $auditArguments
}
if ($selectedScopes -contains 'Website') {
    $websiteProject = Find-Project @('package.json', 'src/server.js', 'src/public_site.js')
    if (-not $SkipInstall) { Invoke-CheckedCommand $websiteProject 'npm' @('ci') }
    Invoke-CheckedCommand $websiteProject 'npm' @('test')
    Invoke-CheckedCommand $websiteProject 'node' @('--check', 'src/server.js')
    Invoke-CheckedCommand $websiteProject 'node' @('--check', 'src/public_site.js')
}
if ($selectedScopes -contains 'Prototype') {
    $mobileProject = Find-Project @('package.json', 'index.html', 'src/main.jsx')
    if (-not $SkipInstall) { Invoke-CheckedCommand $mobileProject 'npm' @('ci') }
    Invoke-CheckedCommand $mobileProject 'npm' @('run', 'build')
    Invoke-CheckedCommand $mobileProject 'npm' $auditArguments
}

if ($IncludeBuild) {
    # Android is a second target of the main Flutter project. Compile the
    # actual mobile entry point in the release gate; 手机软件 is only the
    # browser prototype and cannot validate native Android plugins.
    $buildFlags = @{}
    if ($Core) { $buildFlags.Core = $true }
    & (Join-Path $mainProject "scripts\build_android.ps1") -Configuration Debug @buildFlags
    # The build helpers throw on failure. Do not inspect $LASTEXITCODE here:
    # robocopy returns 1 after successfully copying output artifacts.
    & (Join-Path $mainProject "scripts\build_windows.ps1") -Configuration Release @buildFlags
}

$global:LASTEXITCODE = 0
Write-Host "Requested checks passed: $($selectedScopes -join ', ')." -ForegroundColor Green
