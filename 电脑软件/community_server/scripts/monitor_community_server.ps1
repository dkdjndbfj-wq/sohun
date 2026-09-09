<#
.SYNOPSIS
Single-shot readiness and operational-metrics check for Task Scheduler or an
external uptime monitor. Exits non-zero when the service is not ready.
#>

[CmdletBinding()]
param(
  [string]$BaseUrl = $env:COMMUNITY_PUBLIC_BASE_URL,
  [string]$AdminToken = $env:COMMUNITY_ADMIN_TOKEN,
  [ValidateRange(2, 60)]
  [int]$TimeoutSeconds = 10,
  [switch]$AllowDegraded
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
  throw 'Pass -BaseUrl or set COMMUNITY_PUBLIC_BASE_URL.'
}
$uri = $null
if (-not [Uri]::TryCreate($BaseUrl.Trim(), [UriKind]::Absolute, [ref]$uri)) {
  throw 'BaseUrl must be an absolute HTTP(S) URL.'
}
if ($uri.Scheme -notin @('http', 'https') -or
    [string]::IsNullOrWhiteSpace($uri.Host) -or
    -not [string]::IsNullOrEmpty($uri.UserInfo) -or
    -not [string]::IsNullOrEmpty($uri.Query) -or
    -not [string]::IsNullOrEmpty($uri.Fragment)) {
  throw 'BaseUrl is not a safe account-server URL.'
}
if ($uri.Scheme -eq 'http' -and -not $uri.IsLoopback) {
  throw 'Non-loopback monitoring endpoints must use HTTPS.'
}

$base = $uri.AbsoluteUri.TrimEnd('/')
try {
  $ready = Invoke-RestMethod `
    -Method Get `
    -Uri "$base/ready" `
    -TimeoutSec $TimeoutSeconds `
    -ErrorAction Stop
} catch {
  throw "sohun account server is not ready: $($_.Exception.Message)"
}
if ($ready.ok -ne $true) {
  throw "sohun account server reported not ready: $($ready | ConvertTo-Json -Compress)"
}
if ($ready.degraded -eq $true -and -not $AllowDegraded) {
  throw "sohun account server is degraded: $($ready | ConvertTo-Json -Compress)"
}

$result = [ordered]@{
  ready = $true
  database = $ready.checks.database
  backup = $ready.checks.backup
  email = $ready.checks.email
}

if (-not [string]::IsNullOrWhiteSpace($AdminToken)) {
  $metrics = Invoke-RestMethod `
    -Method Get `
    -Uri "$base/v1/admin/metrics" `
    -Headers @{ Authorization = "Bearer $AdminToken" } `
    -TimeoutSec $TimeoutSeconds `
    -ErrorAction Stop
  $result.uptimeSeconds = $metrics.uptimeSeconds
  $result.accounts = $metrics.accounts
  $result.emailMetrics = $metrics.email
  $result.backupMetrics = $metrics.backup
}

[pscustomobject]$result
