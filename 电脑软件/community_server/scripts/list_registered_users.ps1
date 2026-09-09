<#
.SYNOPSIS
Lists accounts registered on the owner-operated sohun server (all pages).

.EXAMPLE
$env:COMMUNITY_PUBLIC_BASE_URL = 'https://accounts.example.com'
$env:COMMUNITY_ADMIN_TOKEN = '<set securely; do not save in scripts or shell history>'
.\scripts\list_registered_users.ps1 -Status active -Query 'example.com' -PageSize 100

BaseUrl and AdminToken can also be passed explicitly. The script emits structured
objects suitable for Where-Object, Format-Table, and other pipeline commands.
#>

[CmdletBinding()]
param(
  [Parameter()]
  [string]$BaseUrl = $env:COMMUNITY_PUBLIC_BASE_URL,

  [Parameter()]
  [string]$AdminToken = $env:COMMUNITY_ADMIN_TOKEN,

  [Parameter()]
  [ValidateLength(0, 256)]
  [string]$Query = '',

  [Parameter()]
  [ValidateSet('active', 'disabled', 'all')]
  [string]$Status = 'all',

  [Parameter()]
  [ValidateRange(1, 100)]
  [int]$PageSize = 50
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
  throw 'Missing server URL. Pass -BaseUrl or set COMMUNITY_PUBLIC_BASE_URL.'
}
if ([string]::IsNullOrWhiteSpace($AdminToken)) {
  throw 'Missing admin token. Pass -AdminToken or set COMMUNITY_ADMIN_TOKEN.'
}
if ($AdminToken.Contains("`r") -or $AdminToken.Contains("`n")) {
  throw 'The admin token has an invalid format.'
}

$normalizedBaseUrl = $BaseUrl.Trim()
$serverUri = $null
if (-not [System.Uri]::TryCreate(
    $normalizedBaseUrl,
    [System.UriKind]::Absolute,
    [ref]$serverUri
  )) {
  throw 'The server URL must be an absolute HTTP(S) URL.'
}

if ($serverUri.Scheme -notin @('http', 'https')) {
  throw 'The server URL must use HTTP or HTTPS.'
}
if ([string]::IsNullOrWhiteSpace($serverUri.Host)) {
  throw 'The server URL must include a host.'
}
if (-not [string]::IsNullOrEmpty($serverUri.UserInfo)) {
  throw 'The server URL must not contain user information.'
}
if ($normalizedBaseUrl.Contains('?') -or
    $normalizedBaseUrl.Contains('#') -or
    -not [string]::IsNullOrEmpty($serverUri.Query) -or
    -not [string]::IsNullOrEmpty($serverUri.Fragment)) {
  throw 'The server URL must not contain a query string or fragment.'
}
if ($serverUri.Scheme -eq 'http' -and -not $serverUri.IsLoopback) {
  throw 'Non-loopback servers must use HTTPS. HTTP is allowed only for localhost, 127.0.0.0/8, or ::1.'
}

$endpoint = $serverUri.AbsoluteUri.TrimEnd('/') + '/v1/admin/users'
$headers = @{
  Accept = 'application/json'
  Authorization = 'Bearer ' + $AdminToken
}
$cursor = $null
$seenCursors = New-Object 'System.Collections.Generic.HashSet[string]'
$results = New-Object 'System.Collections.Generic.List[object]'

while ($true) {
  $queryParts = New-Object 'System.Collections.Generic.List[string]'
  [void]$queryParts.Add(
    'status=' + [System.Uri]::EscapeDataString($Status)
  )
  [void]$queryParts.Add('limit=' + $PageSize.ToString(
      [System.Globalization.CultureInfo]::InvariantCulture
    ))
  if (-not [string]::IsNullOrWhiteSpace($Query)) {
    [void]$queryParts.Add(
      'q=' + [System.Uri]::EscapeDataString($Query.Trim())
    )
  }
  if ($null -ne $cursor) {
    [void]$queryParts.Add(
      'cursor=' + [System.Uri]::EscapeDataString($cursor)
    )
  }

  $requestUri = $endpoint + '?' + ($queryParts -join '&')
  try {
    $response = Invoke-RestMethod `
      -Method Get `
      -Uri $requestUri `
      -Headers $headers `
      -TimeoutSec 30 `
      -ErrorAction Stop
  } catch {
    $detail = [string]$_.Exception.Message
    if (-not [string]::IsNullOrEmpty($AdminToken)) {
      $detail = $detail.Replace($AdminToken, '[REDACTED]')
    }
    $detail = ($detail -replace '[\r\n]+', ' ').Trim()
    if ($detail.Length -gt 300) {
      $detail = $detail.Substring(0, 300) + '...'
    }
    throw "Failed to read registered accounts: $detail"
  }

  if ($null -eq $response) {
    throw 'The account server returned an empty response.'
  }
  $itemsProperty = $response.PSObject.Properties['items']
  $nextCursorProperty = $response.PSObject.Properties['nextCursor']
  if ($null -eq $itemsProperty -or $null -eq $nextCursorProperty) {
    throw 'The account server response is incompatible: items or nextCursor is missing.'
  }

  foreach ($item in @($itemsProperty.Value)) {
    if ($null -eq $item) {
      continue
    }
    if ($null -eq $item.PSObject.Properties['id'] -or
        $null -eq $item.PSObject.Properties['email'] -or
        $null -eq $item.PSObject.Properties['status']) {
      throw 'The account server response is incompatible: a user record is missing required fields.'
    }
    $safeItem = $item | Select-Object `
      id, `
      email, `
      handle, `
      displayName, `
      emailVerified, `
      status, `
      termsVersion, `
      privacyVersion, `
      termsAcceptedAt, `
      lastLoginAt, `
      createdAt, `
      updatedAt
    [void]$results.Add($safeItem)
  }

  $nextCursor = $nextCursorProperty.Value
  if ($null -eq $nextCursor -or
      [string]::IsNullOrWhiteSpace([string]$nextCursor)) {
    break
  }
  $cursor = [string]$nextCursor
  if (-not $seenCursors.Add($cursor)) {
    throw 'The account server returned a repeated nextCursor; stopped to prevent an infinite loop.'
  }
}

$results
