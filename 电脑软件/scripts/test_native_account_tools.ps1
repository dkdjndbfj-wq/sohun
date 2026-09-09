# Starts helpers with synthetic credentials and NO networking DLL. They must
# fail locally before networking/configuration, without leaking credential text.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$BinDirectory,
    [Parameter(Mandatory = $true)][string]$RuntimeBundle
)
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'Test-WindowsRuntimeBundle.ps1') -BundleDirectory $RuntimeBundle
$taskNativeScratch = Join-Path ([IO.Path]::GetTempPath()) ('sohun_native_privacy_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $taskNativeScratch | Out-Null
$fakeAccess = 'TEST_ACCESS_TOKEN_PREFIX_' + ('x' * 80)
$fakeRefresh = 'TEST_REFRESH_TOKEN_PREFIX_' + ('y' * 80)
$fakePin = '654321'
try {
    foreach ($name in @('bind_tool', 'switch_user_tool')) {
        $directory = Join-Path $taskNativeScratch $name
        New-Item -ItemType Directory -Path $directory | Out-Null
        Copy-Item -LiteralPath (Join-Path $BinDirectory "$name.exe") -Destination $directory
        foreach ($line in Get-Content -LiteralPath (Join-Path $RuntimeBundle 'msvc-runtime.sha256')) {
            $dllName = ($line -split '  ', 2)[1]
            Copy-Item -LiteralPath (Join-Path $RuntimeBundle $dllName) -Destination $directory
        }
        $tokenFile = Join-Path $directory 'synthetic-token.json'
        $fixture = @{ accessToken=$fakeAccess; refreshToken=$fakeRefresh; uid='1234567890'; region='China' } | ConvertTo-Json -Compress
        [IO.File]::WriteAllText($tokenFile, $fixture, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath (Join-Path $directory 'bambu_networking.dll')) {
            throw 'Privacy fixture must never contain the networking DLL.'
        }
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = Join-Path $directory "$name.exe"
        $startInfo.WorkingDirectory = $directory
        $startInfo.Arguments = if ($name -eq 'bind_tool') { '--stdin "' + $tokenFile + '"' } else { '"' + $tokenFile + '"' }
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardInput = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        try {
            [void]$process.Start()
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            if ($name -eq 'bind_tool') { $process.StandardInput.WriteLine($fakePin) }
            $process.StandardInput.Close()
            if (!$process.WaitForExit(5000)) {
                $process.Kill()
                throw "Synthetic helper test timed out: $name"
            }
            $output = $stdoutTask.Result + $stderrTask.Result
            if ($process.ExitCode -ne 1 -or !$output.Contains('credential input loaded')) {
                throw "Helper did not reach the expected local fail-closed path: $name"
            }
            foreach ($secret in @('TEST_ACCESS_TOKEN_PREFIX_', 'TEST_REFRESH_TOKEN_PREFIX_', $fakePin)) {
                if ($output.Contains($secret)) { throw "Helper leaked synthetic credential output: $name" }
            }
            Write-Host "[native privacy] $name passed (no network DLL, no real credentials)."
        } finally {
            $process.Dispose()
        }
    }
    Write-Host 'Native account helper privacy tests passed: 2/2'
} finally {
    $resolved = [IO.Path]::GetFullPath($taskNativeScratch)
    $nativeTemp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    if (!$resolved.StartsWith("$nativeTemp\sohun_native_privacy_", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove an unexpected native privacy fixture.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
