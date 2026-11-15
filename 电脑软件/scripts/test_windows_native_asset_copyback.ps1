# Filesystem-only regression for staged native-asset diagnostics. No Flutter,
# compiler, real DLLs or Pester required; the shared test DLL remains locked.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskScratch = Join-Path ([IO.Path]::GetTempPath()) ('sohun_native_copyback_' + [guid]::NewGuid().ToString('N'))
$casesPassed = 0
$lockedDll = $null
$junction = $null

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Expect-Failure([scriptblock]$Action, [string]$Pattern) {
    $caught = $null
    try { & $Action | Out-Null } catch { $caught = $_ }
    Assert-Condition ($null -ne $caught) 'Expected copyback rejection.'
    Assert-Condition ($caught.ToString() -match $Pattern) "Unexpected failure: $caught"
}

function Write-Fixture([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    [IO.File]::WriteAllText($Path, $Text)
}

try {
    New-Item -ItemType Directory -Path $taskScratch | Out-Null
    $tokens = $null
    $parseErrors = $null
    $buildScript = Join-Path $PSScriptRoot 'build_windows.ps1'
    $ast = [Management.Automation.Language.Parser]::ParseFile($buildScript, [ref]$tokens, [ref]$parseErrors)
    Assert-Condition ($parseErrors.Count -eq 0) 'Windows build script has syntax errors.'
    $copyFunction = $ast.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -eq 'Copy-SohunWindowsNativeAssetDiagnostics'
    }, $false)
    Assert-Condition ($null -ne $copyFunction) 'Diagnostic copy helper is missing.'
    # Load only the helper under test, never the native-build entry point.
    . ([scriptblock]::Create($copyFunction.Extent.Text))

    $project = Join-Path $taskScratch 'project'
    $stage = Join-Path $taskScratch 'stage'
    $sourceDll = Join-Path $stage 'build\native_assets\windows\sqlite3.dll'
    $sharedDll = Join-Path $project 'build\native_assets\windows\sqlite3.dll'
    $diagnosticRoot = Join-Path $project 'build\windows\native_assets'
    Write-Fixture $sourceDll 'new-staged-diagnostics'
    Write-Fixture $sharedDll 'shared-flutter-test-runtime'
    $sharedHash = (Get-FileHash -LiteralPath $sharedDll -Algorithm SHA256).Hash
    $lockedDll = [IO.File]::Open($sharedDll, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    Copy-SohunWindowsNativeAssetDiagnostics -BuildRoot $stage -ProjectRoot $project -Configuration Debug
    Assert-Condition ((Get-Content -LiteralPath (Join-Path $diagnosticRoot 'Debug\windows\sqlite3.dll') -Raw) -eq 'new-staged-diagnostics') 'Debug diagnostic copy is missing.'
    Assert-Condition ((Get-FileHash -LiteralPath $sharedDll -Algorithm SHA256).Hash -eq $sharedHash) 'Shared test DLL was changed.'
    $casesPassed++

    Write-Fixture (Join-Path $diagnosticRoot 'Debug\stale.txt') 'stale'
    Write-Fixture (Join-Path $diagnosticRoot 'Release\keep.txt') 'other-config'
    Copy-SohunWindowsNativeAssetDiagnostics -BuildRoot $stage -ProjectRoot $project -Configuration Debug
    Assert-Condition (-not (Test-Path -LiteralPath (Join-Path $diagnosticRoot 'Debug\stale.txt'))) 'Stale diagnostics survived a replacement.'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $diagnosticRoot 'Release\keep.txt')) 'Debug copy touched Release.'
    $casesPassed++

    Write-Fixture (Join-Path $diagnosticRoot 'Debug\keep.txt') 'debug-config'
    foreach ($config in @('Release', 'Profile')) {
        Copy-SohunWindowsNativeAssetDiagnostics -BuildRoot $stage -ProjectRoot $project -Configuration $config
        Assert-Condition (Test-Path -LiteralPath (Join-Path $diagnosticRoot "$config\windows\sqlite3.dll")) "$config diagnostics are missing."
        Assert-Condition (Test-Path -LiteralPath (Join-Path $diagnosticRoot 'Debug\keep.txt')) "$config copy touched Debug."
        $casesPassed++
    }

    Copy-SohunWindowsNativeAssetDiagnostics -BuildRoot (Join-Path $taskScratch 'absent-stage') -ProjectRoot $project -Configuration Debug
    Assert-Condition (Test-Path -LiteralPath (Join-Path $diagnosticRoot 'Debug\keep.txt')) 'Missing source removed existing diagnostics.'
    $casesPassed++

    Expect-Failure {
        Copy-SohunWindowsNativeAssetDiagnostics -BuildRoot $stage -ProjectRoot $project -Configuration '..\..\native_assets'
    } 'Configuration|ValidateSet|does not belong|不属于'
    Assert-Condition ((Get-FileHash -LiteralPath $sharedDll -Algorithm SHA256).Hash -eq $sharedHash) 'Traversal touched the shared DLL.'
    $casesPassed++

    $redirectedProject = Join-Path $taskScratch 'redirected-project'
    $redirectedTarget = Join-Path $taskScratch 'redirected-target'
    $junction = Join-Path $redirectedProject 'build\windows\native_assets'
    Write-Fixture (Join-Path $redirectedTarget 'Debug\keep.txt') 'must-survive'
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $junction) | Out-Null
    New-Item -ItemType Junction -Path $junction -Target $redirectedTarget | Out-Null
    Expect-Failure {
        Copy-SohunWindowsNativeAssetDiagnostics -BuildRoot $stage -ProjectRoot $redirectedProject -Configuration Debug
    } 'redirected'
    Assert-Condition (Test-Path -LiteralPath (Join-Path $redirectedTarget 'Debug\keep.txt')) 'Redirected destination was modified.'
    $casesPassed++

    function robocopy { $global:LASTEXITCODE = 8 }
    Expect-Failure {
        Copy-SohunWindowsNativeAssetDiagnostics -BuildRoot $stage -ProjectRoot $project -Configuration Profile
    } 'robocopy 8'
    Remove-Item Function:robocopy
    $casesPassed++

    Write-Host "Windows native-asset copyback tests passed: $casesPassed/8"
} finally {
    if ($null -ne $lockedDll) { $lockedDll.Dispose() }
    $resolved = [IO.Path]::GetFullPath($taskScratch)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (-not $resolved.StartsWith("$tempRoot\sohun_native_copyback_", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove an unexpected copyback-test fixture directory.'
    }
    if ($null -ne $junction -and (Test-Path -LiteralPath $junction)) {
        # Remove the junction itself first, without recursive target traversal.
        Remove-Item -LiteralPath $junction -Force
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
exit 0
