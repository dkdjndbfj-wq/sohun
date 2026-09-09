[CmdletBinding()]
param(
    [string]$ProjectPath = (Get-Location).Path,
    [string[]]$Paths = @('lib', 'test')
)

$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath $ProjectPath
try {
    $analysis = @(& dart analyze @Paths --format machine 2>&1)
    $analysisExitCode = $LASTEXITCODE
    $analysis | Write-Output

    if ($analysis | Where-Object { $_ -match '^(ERROR|WARNING)\|' }) {
        throw "Dart analysis reported errors or warnings in $ProjectPath."
    }
    # Older analyzer versions can return 1 for informational diagnostics.
    # Accept that only with evidence; an unexplained failure must stay red.
    $diagnostics = @($analysis | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    $infoOnly = $diagnostics.Count -gt 0 -and
        @($diagnostics | Where-Object { $_ -notmatch '^INFO\|' }).Count -eq 0
    if ($analysisExitCode -ne 0 -and -not ($analysisExitCode -eq 1 -and $infoOnly)) {
        throw "Dart analyzer failed with exit code $analysisExitCode in $ProjectPath."
    }
    # GitHub's PowerShell wrapper propagates LASTEXITCODE at the end of a step.
    # Normalize successful info-only runs without terminating the caller.
    $global:LASTEXITCODE = 0
} finally {
    Pop-Location
}
