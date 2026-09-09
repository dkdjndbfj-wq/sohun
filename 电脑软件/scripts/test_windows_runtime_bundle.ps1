# Filesystem-only packaging regressions; no compiler, real DLLs or Pester needed.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$taskScratch = Join-Path ([System.IO.Path]::GetTempPath()) ('sohun_crt_gate_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskScratch | Out-Null
$validator = Join-Path $PSScriptRoot 'Test-WindowsRuntimeBundle.ps1'
$ascii = [System.Text.Encoding]::ASCII
$casesPassed = 0

function New-Fixture([string]$Name) {
    $directory = Join-Path $taskScratch $Name
    New-Item -ItemType Directory -Path $directory | Out-Null
    $lines = @()
    foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $file = Join-Path $directory $dll
        [System.IO.File]::WriteAllText($file, "fixture:$dll", $ascii)
        $lines += (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $dll
    }
    [System.IO.File]::WriteAllLines((Join-Path $directory 'msvc-runtime.sha256'), [string[]]$lines, $ascii)
    return $directory
}

function Assert-Rejected([string]$Directory, [string]$Name) {
    $rejected = $false
    try { & $validator -BundleDirectory $Directory } catch { $rejected = $true }
    if (!$rejected) { throw "Unsafe runtime fixture unexpectedly passed: $Name" }
    Write-Host "[test] Rejected: $Name"
}

try {
    $valid = New-Fixture 'valid'
    & $validator -BundleDirectory $valid
    $casesPassed++

    foreach ($case in @('no-manifest', 'no-dll', 'empty-dll', 'modified-dll', 'missing-entry', 'duplicate', 'traversal', 'debug-dll')) {
        $fixture = New-Fixture $case
        $manifest = Join-Path $fixture 'msvc-runtime.sha256'
        $dllPath = Join-Path $fixture 'vcruntime140_1.dll'
        $lines = @(Get-Content -LiteralPath $manifest -Encoding ascii)
        switch ($case) {
            'no-manifest' { Remove-Item -LiteralPath $manifest }
            'no-dll' { Remove-Item -LiteralPath $dllPath }
            'empty-dll' { [System.IO.File]::WriteAllText($dllPath, '', $ascii) }
            'modified-dll' { [System.IO.File]::WriteAllText($dllPath, 'changed', $ascii) }
            'missing-entry' { [System.IO.File]::WriteAllLines($manifest, [string[]]$lines[0..1], $ascii) }
            'duplicate' { [System.IO.File]::AppendAllText($manifest, $lines[0] + "`n", $ascii) }
            'traversal' { [System.IO.File]::AppendAllText($manifest, ('0' * 64) + "  ../outside.dll`n", $ascii) }
            'debug-dll' { [System.IO.File]::AppendAllText($manifest, ('0' * 64) + "  msvcp140d.dll`n", $ascii) }
        }
        Assert-Rejected $fixture $case
        $casesPassed++
    }
    Write-Host "Windows runtime packaging tests passed: $casesPassed/9"
} finally {
    # Only this invocation's unique, resolved fixture directory may be removed.
    $resolved = [System.IO.Path]::GetFullPath($taskScratch)
    $tempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if (!$resolved.StartsWith("$tempRoot\sohun_crt_gate_", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove an unexpected runtime-test fixture directory.'
    }
    if (Test-Path -LiteralPath $resolved) { Remove-Item -LiteralPath $resolved -Recurse -Force }
}
