[CmdletBinding()]
param(
    [string]$Python = 'python',
    [string]$Checkpoint = '',
    [ValidateRange(1024, 65535)][int]$Port = 27961,
    [ValidateSet('cuda', 'cpu', 'auto')][string]$Device = 'cuda'
)
$ErrorActionPreference = 'Stop'
$mifuArgs = @((Join-Path $PSScriptRoot 'mifu_server.py'), '--port', "$Port", '--device', $Device)
if ($Checkpoint) {
    $resolvedCheckpoint = (Resolve-Path -LiteralPath $Checkpoint).Path
    $mifuArgs += @('--checkpoint', $resolvedCheckpoint)
}
# This script runs in the calling terminal. It neither installs dependencies nor
# downloads weights, opens a firewall port, or starts hidden persistent services.
& $Python @mifuArgs
if ($LASTEXITCODE -ne 0) { throw "Mifu 服务退出，代码 $LASTEXITCODE" }
