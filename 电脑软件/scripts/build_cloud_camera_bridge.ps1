[CmdletBinding()]
param(
    [string]$SourcePath = "",
    [string]$OutputPath = ""
)

$ErrorActionPreference = 'Stop'
# Resolve defaults in the script body (not in param defaults) so the script
# also works when $PSScriptRoot is unavailable in the caller's context.
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
    $SourcePath = Join-Path $PSScriptRoot '..\research\cloud_camera_bridge.cpp'
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = Join-Path $PSScriptRoot '..\assets\bin\cloud_camera_bridge.exe'
}
$source = (Resolve-Path -LiteralPath $SourcePath).Path
$sourceName = [System.IO.Path]::GetFileNameWithoutExtension($source)
$output = [System.IO.Path]::GetFullPath($OutputPath)
$outputDirectory = Split-Path -Parent $output
New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
# Intermediate .obj files go to a temp directory so the repo stays clean and
# every build is reproducible from research/cloud_camera_bridge.cpp alone.
$objDir = Join-Path ([System.IO.Path]::GetTempPath()) ('sohun_native_build_' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $objDir | Out-Null

$vcvarsCandidates = @(
    'C:\Program Files (x86)\Microsoft Visual Studio\18\BuildTools\VC\Auxiliary\Build\vcvars64.bat',
    'C:\Program Files\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat'
)
$vcvars = $vcvarsCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $vcvars) {
    # Hosted Windows runners commonly install the C++ workload under an
    # Enterprise or Community edition rather than the BuildTools path above.
    $visualStudioRoots = @(
        (Join-Path ${env:ProgramFiles} 'Microsoft Visual Studio'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio')
    ) | Where-Object { Test-Path -LiteralPath $_ }
    $vcvars = $visualStudioRoots |
        ForEach-Object {
            Get-ChildItem -LiteralPath $_ -Filter 'vcvars64.bat' -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -match '\\VC\\Auxiliary\\Build\\vcvars64\.bat$' }
        } |
        Sort-Object FullName -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $vcvars) {
    throw 'Visual C++ build environment was not found.'
}

$command = 'call "{0}" >nul && cl /std:c++17 /MD /EHsc /W3 /utf-8 /Fo"{1}" "{2}" /link /OUT:"{3}"' -f $vcvars, (Join-Path $objDir "$sourceName.obj"), $source, $output
try {
    & cmd.exe /d /c $command
    if ($LASTEXITCODE -ne 0) {
        throw "$sourceName.cpp compilation failed (exit $LASTEXITCODE)."
    }
} finally {
    $resolvedObjDir = [System.IO.Path]::GetFullPath($objDir)
    $nativeTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd('\')
    if (!$resolvedObjDir.StartsWith("$nativeTempRoot\sohun_native_build_", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'Refusing to remove an unexpected native build directory.'
    }
    Remove-Item -LiteralPath $resolvedObjDir -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = (Get-FileHash -LiteralPath $output -Algorithm SHA256).Hash.ToLowerInvariant()
$hash | Set-Content -LiteralPath "$output.sha256" -Encoding ascii -NoNewline
Write-Host "Native helper: $output"
Write-Host "SHA256: $hash"
