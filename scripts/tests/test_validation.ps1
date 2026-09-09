# Behavioral checks for verification routing and analyzer failure propagation.
# Uses isolated fixtures and fake commands; no SDK, network or product build.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$sourceScripts = Split-Path -Parent $PSScriptRoot
$fixtureRoot = Join-Path ([IO.Path]::GetTempPath()) ('sohun-validation-' + [guid]::NewGuid().ToString('N'))
$validationState = @{
    Calls = [Collections.Generic.List[object]]::new()
    AnalysisOutput = @()
    AnalysisExit = 0
    FailCommand = ''
    Passed = 0
}

function Assert-Condition {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Expect-Failure {
    param([scriptblock]$Action, [string]$Pattern)
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-Condition ($null -ne $caught) 'Expected a failure, but the command passed.'
    Assert-Condition ($caught.ToString() -match $Pattern) "Unexpected failure: $caught"
}

function Record-ToolCall {
    param([string]$Tool, [string[]]$ToolArguments)
    $validationState.Calls.Add([pscustomobject]@{
        Tool = $Tool
        Arguments = $ToolArguments
        Directory = (Get-Location).Path
    })
    $global:LASTEXITCODE = if ("$Tool $($ToolArguments -join ' ')" -eq $validationState.FailCommand) { 7 } else { 0 }
}

function dart {
    Record-ToolCall 'dart' $args
    $validationState.AnalysisOutput
    $global:LASTEXITCODE = $validationState.AnalysisExit
}
function flutter { Record-ToolCall 'flutter' $args }
function npm { Record-ToolCall 'npm' $args }
function node { Record-ToolCall 'node' $args }

function New-Fixture {
    param([string]$Name, [switch]$WebsiteOnly)
    $root = Join-Path $fixtureRoot $Name
    $files = @('website/package.json', 'website/src/server.js', 'website/src/public_site.js')
    if (-not $WebsiteOnly) {
        $files += @('client/pubspec.yaml', 'client/community_server/package.json',
            'prototype/package.json', 'prototype/index.html', 'prototype/src/main.jsx')
    }
    foreach ($file in $files) {
        $target = Join-Path $root $file
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
        [IO.File]::WriteAllText($target, '')
    }
    $scripts = Join-Path $root 'scripts'
    New-Item -ItemType Directory -Force -Path $scripts | Out-Null
    foreach ($name in @('analyze_dart.ps1', 'verify_all.ps1')) {
        Copy-Item -LiteralPath (Join-Path $sourceScripts $name) -Destination $scripts
    }
    if (-not $WebsiteOnly) {
        $clientScripts = Join-Path $root 'client/scripts'
        New-Item -ItemType Directory -Force -Path $clientScripts | Out-Null
        [IO.File]::WriteAllText((Join-Path $clientScripts 'test_windows_runtime_bundle.ps1'), "Record-ToolCall 'runtime-gate' @()")
        [IO.File]::WriteAllText((Join-Path $clientScripts 'build_android.ps1'), @'
param([string]$Configuration)
Record-ToolCall 'android-build' @($Configuration)
$global:LASTEXITCODE = 1
'@)
        [IO.File]::WriteAllText((Join-Path $clientScripts 'build_windows.ps1'), @'
param([string]$Configuration, [switch]$NoClean)
Record-ToolCall 'windows-build' @($Configuration, [string]$NoClean)
$global:LASTEXITCODE = 1
'@)
    }
    return $root
}

function Run-Case {
    param([string]$Name, [scriptblock]$Action)
    $validationState.Calls.Clear()
    $validationState.AnalysisOutput = @()
    $validationState.AnalysisExit = 0
    $validationState.FailCommand = ''
    $before = (Get-Location).Path
    & $Action
    Assert-Condition ((Get-Location).Path -eq $before) "$Name changed the caller's directory."
    $validationState.Passed++
    Write-Host "PASS: $Name"
}

try {
    $projectRoot = New-Fixture 'complete'
    $websiteRoot = New-Fixture 'website-only' -WebsiteOnly
    $verify = Join-Path $projectRoot 'scripts/verify_all.ps1'
    $analyze = Join-Path $projectRoot 'scripts/analyze_dart.ps1'
    $client = Join-Path $projectRoot 'client'

    $analyzerCases = @(
        @{ Name = 'clean'; Code = 0; Lines = @(); Pass = $true },
        @{ Name = 'info with zero'; Code = 0; Lines = @('INFO|LINT|sample'); Pass = $true },
        @{ Name = 'info with one'; Code = 1; Lines = @('INFO|LINT|sample'); Pass = $true },
        @{ Name = 'warning'; Code = 2; Lines = @('WARNING|STATIC_WARNING|sample'); Pass = $false },
        @{ Name = 'error'; Code = 3; Lines = @('ERROR|COMPILE_TIME_ERROR|sample'); Pass = $false },
        @{ Name = 'warning despite zero'; Code = 0; Lines = @('WARNING|STATIC_WARNING|sample'); Pass = $false },
        @{ Name = 'empty failure'; Code = 1; Lines = @(); Pass = $false },
        @{ Name = 'unknown failure'; Code = 2; Lines = @('Unable to start analyzer'); Pass = $false },
        @{ Name = 'crash'; Code = 99; Lines = @('Analyzer crashed'); Pass = $false },
        @{ Name = 'info cannot mask failure'; Code = 2; Lines = @('INFO|LINT|sample'); Pass = $false },
        @{ Name = 'partial info output cannot mask a crash'; Code = 1; Lines = @('INFO|LINT|sample', 'Analyzer crashed'); Pass = $false }
    )
    foreach ($case in $analyzerCases) {
        Run-Case "Analyzer: $($case.Name)" {
            $validationState.AnalysisOutput = $case.Lines
            $validationState.AnalysisExit = $case.Code
            if ($case.Pass) {
                & $analyze -ProjectPath $client | Out-Null
                Assert-Condition ($LASTEXITCODE -eq 0) 'Successful analysis left a failing exit code.'
            } else {
                Expect-Failure { & $analyze -ProjectPath $client } 'Dart analy'
            }
        }
    }

    Run-Case 'Website scope works without unrelated projects' {
        & (Join-Path $websiteRoot 'scripts/verify_all.ps1') -Scope Website -SkipInstall | Out-Null
        Assert-Condition ($validationState.Calls.Count -eq 3) 'Expected npm test and two syntax checks.'
        Assert-Condition (@($validationState.Calls | Where-Object { $_.Directory -ne (Join-Path $websiteRoot 'website') }).Count -eq 0) 'Touched an unrelated project.'
    }
    Run-Case 'Client reuses dependencies and runs one suite' {
        & $verify -Scope Client -SkipInstall | Out-Null
        Assert-Condition (($validationState.Calls.Tool -join ',') -eq 'runtime-gate,dart,flutter') 'Client scope invoked unrelated checks or installs.'
        Assert-Condition ($validationState.Calls[2].Arguments -contains '--concurrency=2') 'Lost the Windows concurrency limit.'
    }
    Run-Case 'Inventory prepares the local API before its focused test' {
        & $verify -Scope Inventory | Out-Null
        Assert-Condition (($validationState.Calls.Tool -join ',') -eq 'npm,flutter,flutter') 'Unexpected inventory preparation.'
        Assert-Condition ($validationState.Calls[0].Arguments[0] -eq 'ci') 'Server dependencies were not prepared first.'
        Assert-Condition ($validationState.Calls[2].Arguments -contains 'test/integration') 'Inventory must include snapshot, stock-receipt, and device HTTP integration.'
    }
    Run-Case 'All folds HTTP integration into a single Flutter suite' {
        & $verify | Out-Null
        $flutterTests = @($validationState.Calls | Where-Object { $_.Tool -eq 'flutter' -and $_.Arguments[0] -eq 'test' })
        Assert-Condition ($flutterTests.Count -eq 1) 'Full verification repeated Flutter tests.'
        Assert-Condition ($flutterTests[0].Arguments -contains '--dart-define=RUN_INVENTORY_HTTP_TESTS=true') 'Full verification omitted HTTP integration.'
        Assert-Condition (@($validationState.Calls | Where-Object { $_.Tool -eq 'npm' -and $_.Arguments[0] -eq 'ci' }).Count -eq 3) 'Dependencies were omitted or installed twice.'
        Assert-Condition (@($validationState.Calls | Where-Object { $_.Tool -eq 'npm' -and $_.Arguments[0] -eq 'audit' }).Count -eq 2) 'Existing dependency audit gates were lost.'
    }
    Run-Case 'Combined scopes deduplicate work' {
        & $verify -Scope Server,Website,Website -SkipInstall | Out-Null
        Assert-Condition (@($validationState.Calls | Where-Object { $_.Tool -eq 'npm' -and $_.Arguments[0] -eq 'test' }).Count -eq 2) 'Repeated a selected scope.'
        Assert-Condition (@($validationState.Calls | Where-Object { $_.Tool -eq 'flutter' }).Count -eq 0) 'Combined Node scopes invoked Flutter.'
    }
    Run-Case 'Builds run once per platform and normalize robocopy success' {
        & $verify -Scope Client -IncludeBuild -SkipInstall | Out-Null
        Assert-Condition (@($validationState.Calls | Where-Object { $_.Tool -eq 'android-build' }).Count -eq 1) 'Android build count changed.'
        Assert-Condition (@($validationState.Calls | Where-Object { $_.Tool -eq 'windows-build' }).Count -eq 1) 'Repeated the Windows build.'
        Assert-Condition ($LASTEXITCODE -eq 0) 'Successful builds leaked the robocopy exit code.'
    }
    Run-Case 'Invalid build scope stops before work' {
        Expect-Failure { & $verify -Scope Website -IncludeBuild } 'requires the Client'
        Assert-Condition ($validationState.Calls.Count -eq 0) 'Invalid scope started work.'
    }
    Run-Case 'Native command failure stops downstream checks' {
        $validationState.FailCommand = 'npm test'
        Expect-Failure { & $verify -Scope Server,Website -SkipInstall } 'failed with exit code 7'
        Assert-Condition ($validationState.Calls.Count -eq 1) 'Continued after a failed command.'
    }
    Run-Case 'Analyzer failure stops Flutter tests' {
        $validationState.AnalysisExit = 2
        Expect-Failure { & $verify -Scope Client -SkipInstall } 'Dart analyzer failed'
        Assert-Condition (@($validationState.Calls | Where-Object { $_.Tool -eq 'flutter' }).Count -eq 0) 'Ran tests after a failed analysis gate.'
    }
    Run-Case 'Android ASCII build preserves its already in-place APK' {
        $repositoryRoot = Split-Path -Parent $sourceScripts
        $androidSource = @(Get-ChildItem -LiteralPath $repositoryRoot -Directory |
            ForEach-Object { Join-Path $_.FullName 'scripts/build_android.ps1' } |
            Where-Object { Test-Path -LiteralPath $_ -PathType Leaf })
        Assert-Condition ($androidSource.Count -eq 1) 'Expected exactly one Android build helper.'
        $androidFixture = New-Fixture 'android-ascii'
        $androidClient = Join-Path $androidFixture 'client'
        Assert-Condition ($androidClient -notmatch '[^\x00-\x7F]') 'This regression requires an ASCII temporary path.'
        $helper = Join-Path $androidClient 'scripts/build_android.ps1'
        Copy-Item -LiteralPath $androidSource[0] -Destination $helper -Force
        $outputDirectory = Join-Path $androidClient 'build/app/outputs/flutter-apk'
        New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
        foreach ($configuration in @('Debug', 'Release')) {
            $apk = Join-Path $outputDirectory ("app-$($configuration.ToLowerInvariant()).apk")
            [IO.File]::WriteAllText($apk, 'isolated fake APK')
            & $helper -Configuration $configuration | Out-Null
            Assert-Condition ([IO.File]::ReadAllText($apk) -eq 'isolated fake APK') 'The existing APK changed.'
        }
        Assert-Condition ($validationState.Calls.Count -eq 4) 'Expected pub get and one build per configuration.'
    }
    $global:LASTEXITCODE = 0
    Write-Host "$($validationState.Passed) validation behavior checks passed." -ForegroundColor Green
} finally {
    $resolvedFixture = [IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolvedFixture.StartsWith($tempPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedFixture) -notmatch '^sohun-validation-[0-9a-f]{32}$') {
        throw "Refusing to remove unexpected fixture directory: $resolvedFixture"
    }
    if (Test-Path -LiteralPath $resolvedFixture) {
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}
