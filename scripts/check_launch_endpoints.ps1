# Read-only production acceptance. A healthy old API is not sufficient:
# require inventory routes, the selected email policy, and release metadata.
[CmdletBinding()]
param(
    [string]$ApiBaseUrl = 'https://api.sohun.top',
    [string]$WebsiteBaseUrl = 'https://sohun.top',
    [string]$AppVersion = '1.0.0',
    [switch]$RequireEmailVerification
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Net.Http
foreach ($base in @($ApiBaseUrl, $WebsiteBaseUrl)) {
    $uri = [Uri]$base
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https' -or $uri.UserInfo -or $uri.Query -or $uri.Fragment) {
        throw 'Production check URLs must use HTTPS without credentials, query, or fragment.'
    }
}
$ApiBaseUrl = $ApiBaseUrl.TrimEnd('/')
$WebsiteBaseUrl = $WebsiteBaseUrl.TrimEnd('/')
$handler = [System.Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$client = [System.Net.Http.HttpClient]::new($handler)
$client.Timeout = [TimeSpan]::FromSeconds(15)
$failures = [Collections.Generic.List[string]]::new()

function Read-Endpoint {
    param([string]$Url)
    $response = $client.GetAsync($Url).GetAwaiter().GetResult()
    try {
        return [pscustomobject]@{
            Status = [int]$response.StatusCode
            Body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            Location = [string]$response.Headers.Location
            NoStore = $null -ne $response.Headers.CacheControl -and $response.Headers.CacheControl.NoStore
        }
    } finally { $response.Dispose() }
}

function Check-Endpoint {
    param([string]$Name, [scriptblock]$Check)
    try {
        & $Check
        Write-Output "PASS $Name"
    } catch {
        $message = "$Name : $($_.Exception.Message)"
        $failures.Add($message)
        Write-Output "FAIL $message"
    }
}

try {
    Check-Endpoint 'API readiness and email' {
        $result = Read-Endpoint "$ApiBaseUrl/ready"
        if ($result.Status -ne 200) { throw "HTTP $($result.Status)" }
        $ready = $result.Body | ConvertFrom-Json
        if ($ready.service -ne 'sohun-community' -or $ready.ok -ne $true -or $ready.degraded -eq $true) {
            throw 'Unexpected service or degraded readiness.'
        }
        foreach ($check in @('database', 'backup')) {
            if ($ready.checks.$check -ne 'ok') { throw "$check is not ready ($($ready.checks.$check))." }
        }
        $acceptedEmailStates = if ($RequireEmailVerification) { @('ok') } else { @('ok', 'not_required') }
        if ($ready.checks.email -notin $acceptedEmailStates) {
            throw "Email readiness does not match the selected policy ($($ready.checks.email))."
        }
    }
    foreach ($route in @('/v1/me/inventory/snapshot', '/v1/me/inventory/events', '/v1/me/printer-faults', '/v1/notifications/printer-faults', '/v1/me/devices', '/v1/me/devices/maintenance')) {
        Check-Endpoint "Authenticated private route $route" {
            $result = Read-Endpoint "$ApiBaseUrl$route"
            if ($result.Status -ne 401) {
                throw "Expected 401 without a token, received HTTP $($result.Status)."
            }
            if (-not $result.NoStore) { throw 'Private responses must prohibit caching.' }
        }
    }
    Check-Endpoint 'Desktop release metadata' {
        $version = [Uri]::EscapeDataString($AppVersion)
        $result = Read-Endpoint "$ApiBaseUrl/v1/config?appVersion=$version&platform=windows"
        if ($result.Status -ne 200) { throw "HTTP $($result.Status)" }
        $config = $result.Body | ConvertFrom-Json
        if ($config.flags.desktop_latest_version -notmatch '^v?\d+\.\d+\.\d+(\+\d+)?$') {
            throw 'desktop_latest_version is missing or invalid.'
        }
        $download = [Uri]$config.flags.desktop_download_url
        if ($null -eq $download -or -not $download.IsAbsoluteUri -or $download.Scheme -ne 'https' -or $download.UserInfo) {
            throw 'desktop_download_url must be a valid HTTPS installer URL.'
        }
    }
    Check-Endpoint 'Website health' {
        $result = Read-Endpoint "$WebsiteBaseUrl/health"
        if ($result.Status -ne 200) { throw "HTTP $($result.Status)" }
    }
    Check-Endpoint 'Website download redirect' {
        $result = Read-Endpoint "$WebsiteBaseUrl/download"
        if ($result.Status -notin @(301, 302, 303, 307, 308)) {
            throw "Expected an installer redirect, received HTTP $($result.Status)."
        }
        $target = [Uri]$result.Location
        if (-not $target.IsAbsoluteUri -or $target.Scheme -ne 'https' -or $target.UserInfo) {
            throw 'Download redirect is not a safe HTTPS target.'
        }
    }
} finally {
    $client.Dispose()
    $handler.Dispose()
}

if ($failures.Count -gt 0) {
    throw "Production acceptance failed: $($failures.Count) checks require deployment/configuration changes."
}
Write-Output 'Production read-only acceptance passed. Continue with signed-installer and real-device acceptance.'
