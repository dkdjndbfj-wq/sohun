# Compile the real personal installer UI without an application payload.
[CmdletBinding()]
param(
    [ValidateSet('Setup', 'Progress', 'Finished')]
    [string]$Page = 'Progress',
    [string]$CompilerPath = ''
)

$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
if ([string]::IsNullOrWhiteSpace($CompilerPath)) {
    $candidates = @(
        $env:INNO_SETUP_COMPILER,
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
        (Join-Path $env:ProgramFiles 'Inno Setup 7\ISCC.exe')
    )
    $CompilerPath = $candidates | Where-Object {
        $_ -and (Test-Path -LiteralPath $_)
    } | Select-Object -First 1
}
if (!$CompilerPath -or !(Test-Path -LiteralPath $CompilerPath)) {
    throw 'Inno Setup 6.7+ is required. Pass -CompilerPath <ISCC.exe>.'
}

$firstPage = if ($Page -eq 'Setup') { '' } else { $Page.ToLowerInvariant() }
$outputName = 'sohun-install-' + $Page.ToLowerInvariant() + '-preview'
$defines = @('/DMyPreview=1', "/DMyPreviewPage=$firstPage", "/F$outputName")
$versionLine = Select-String -LiteralPath (Join-Path $projectRoot 'pubspec.yaml') -Pattern '^version:\s*(\S+)'
if ($versionLine) { $defines += '/DMyAppVersion=' + $versionLine.Matches[0].Groups[1].Value }
& $CompilerPath /Q $defines (Join-Path $projectRoot 'installer\sohun.iss')
if ($LASTEXITCODE -ne 0) { throw "Preview compilation failed ($LASTEXITCODE)." }
Write-Output (Join-Path $projectRoot "dist\installer\$outputName.exe")
