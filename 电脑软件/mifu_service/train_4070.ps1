[CmdletBinding()]
param(
    [string]$Python = 'python',
    [Parameter(Mandatory = $true)][string]$BaseCheckpoint,
    [Parameter(Mandatory = $true)][string]$TrainingData,
    [Parameter(Mandatory = $true)][string]$EvaluationData,
    [Parameter(Mandatory = $true)][string]$OutputDirectory,
    [Parameter(Mandatory = $true)][string]$Version,
    [ValidateRange(1, 100)][int]$Epochs = 4,
    [switch]$FullFinetune,
    [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
$mifuArgs = @((Join-Path $PSScriptRoot 'training.py'), 'train',
    '--base', (Resolve-Path -LiteralPath $BaseCheckpoint).Path,
    '--data', (Resolve-Path -LiteralPath $TrainingData).Path,
    '--eval', (Resolve-Path -LiteralPath $EvaluationData).Path,
    '--out', $OutputDirectory, '--version', $Version, '--epochs', "$Epochs")
if ($FullFinetune) { $mifuArgs += '--full-finetune' }
if ($DryRun) { $mifuArgs += '--dry-run' }
# Default: head-only, micro-batch 1, accumulation 8. These are conservative
# starting parameters, not a measured RTX 4070 throughput or VRAM guarantee.
& $Python @mifuArgs
if ($LASTEXITCODE -ne 0) { throw "Mifu 训练入口退出，代码 $LASTEXITCODE" }
