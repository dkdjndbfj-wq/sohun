[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BundleDirectory
)

$ErrorActionPreference = 'Stop'
$manifestPath = Join-Path $BundleDirectory 'msvc-runtime.sha256'
if (!(Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
    throw 'Windows runtime manifest is missing. Rebuild with the app-local MSVC runtime packaging step.'
}
$allowedNames = @(
    'msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll',
    'concrt140.dll', 'msvcp140_1.dll', 'msvcp140_2.dll',
    'msvcp140_atomic_wait.dll', 'msvcp140_codecvt_ids.dll',
    'vcruntime140_threads.dll', 'vccorlib140.dll'
)
$verified = @{}
foreach ($line in (Get-Content -LiteralPath $manifestPath -Encoding ascii)) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    if ($line -notmatch '^([a-fA-F0-9]{64})  ([a-zA-Z0-9_]+\.dll)$') {
        throw 'Invalid Windows runtime manifest entry.'
    }
    $expectedHash = $Matches[1]
    $runtimeName = $Matches[2].ToLowerInvariant()
    if ($runtimeName -notin $allowedNames -or $verified.ContainsKey($runtimeName)) {
        throw "Unexpected or duplicated Windows runtime entry: $runtimeName"
    }
    $runtimePath = Join-Path $BundleDirectory $runtimeName
    if (!(Test-Path -LiteralPath $runtimePath -PathType Leaf) -or
        (Get-Item -LiteralPath $runtimePath).Length -le 0) {
        throw "Required Windows runtime is missing or empty: $runtimeName"
    }
    if ((Get-FileHash -LiteralPath $runtimePath -Algorithm SHA256).Hash -ne $expectedHash) {
        throw "Windows runtime does not match the build manifest: $runtimeName"
    }
    $verified[$runtimeName] = $true
}
foreach ($requiredName in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
    if (!$verified.ContainsKey($requiredName)) {
        throw "Required Windows runtime is absent from the manifest: $requiredName"
    }
}
Write-Host "[runtime] Verified $($verified.Count) compiler-provided retail DLLs."
