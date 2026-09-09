<#
.SYNOPSIS
Verifies a sohun SQLite backup and atomically stages it as the live database.
Stop the Node service before running. Existing databases are never overwritten
unless -ReplaceExisting is supplied; a timestamped safety copy is retained.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$BackupPath,
  [Parameter(Mandatory = $true)]
  [string]$DatabasePath,
  [string]$NodePath = 'node',
  [switch]$ReplaceExisting
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$backup = [IO.Path]::GetFullPath($BackupPath)
$target = [IO.Path]::GetFullPath($DatabasePath)
if (-not [IO.Path]::IsPathRooted($BackupPath) -or
    -not [IO.Path]::IsPathRooted($DatabasePath)) {
  throw 'BackupPath and DatabasePath must be absolute paths.'
}
if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) {
  throw "Backup file not found: $backup"
}
if ($backup -eq $target) {
  throw 'BackupPath and DatabasePath must be different files.'
}
if ((Test-Path -LiteralPath $target) -and -not $ReplaceExisting) {
  throw 'The live database exists. Stop the service and pass -ReplaceExisting.'
}

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
& $NodePath (Join-Path $scriptRoot 'verify_backup.mjs') $backup | Out-Null
if ($LASTEXITCODE -ne 0) {
  throw 'Backup verification failed.'
}

$targetDirectory = Split-Path -Parent $target
New-Item -ItemType Directory -Force -Path $targetDirectory | Out-Null
$partial = "$target.restore-partial-$PID"
$safety = $null
try {
  Copy-Item -LiteralPath $backup -Destination $partial -Force
  & $NodePath (Join-Path $scriptRoot 'verify_backup.mjs') $partial | Out-Null
  if ($LASTEXITCODE -ne 0) {
    throw 'Staged database verification failed.'
  }
  if (Test-Path -LiteralPath $target) {
    $stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
    $safety = "$target.pre-restore-$stamp"
    Move-Item -LiteralPath $target -Destination $safety
  }
  Move-Item -LiteralPath $partial -Destination $target
  Write-Output "Restored database: $target"
  if ($null -ne $safety) {
    Write-Output "Previous database retained: $safety"
  }
} catch {
  if (Test-Path -LiteralPath $partial) {
    Remove-Item -LiteralPath $partial -Force
  }
  if ($null -ne $safety -and
      (Test-Path -LiteralPath $safety) -and
      -not (Test-Path -LiteralPath $target)) {
    Move-Item -LiteralPath $safety -Destination $target
  }
  throw
}

