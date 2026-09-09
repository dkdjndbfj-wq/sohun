[CmdletBinding()]
param(
    [string]$NodePath = 'node',
    [string]$FlutterPath = 'flutter',
    [ValidateRange(5, 120)]
    [int]$StartupTimeoutSeconds = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-CryptographicSecret {
    param([ValidateRange(32, 256)][int]$ByteCount = 48)

    $bytes = New-Object byte[] $ByteCount
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    return [Convert]::ToBase64String($bytes)
}

function Get-AvailableLoopbackPort {
    $listener = [System.Net.Sockets.TcpListener]::new(
        [System.Net.IPAddress]::Loopback,
        0
    )
    try {
        $listener.Start()
        return ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    }
    finally {
        $listener.Stop()
    }
}

function Get-ValidatedSmokeDirectory {
    param([Parameter(Mandatory = $true)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $tempRoot = [System.IO.Path]::GetFullPath(
        [System.IO.Path]::GetTempPath()
    ).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $directoryName = [System.IO.Path]::GetFileName($fullPath)
    $requiredPrefix = $tempRoot + [System.IO.Path]::DirectorySeparatorChar

    if (-not $directoryName.StartsWith(
        'sohun-account-chain-',
        [System.StringComparison]::Ordinal
    )) {
        throw "Refusing cleanup: unexpected smoke directory name: $fullPath"
    }
    if (-not $fullPath.StartsWith(
        $requiredPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )) {
        throw "Refusing cleanup: smoke directory is outside the OS temp root: $fullPath"
    }
    return $fullPath
}

function Get-HttpFailureStatusCode {
    param([Parameter(Mandatory = $true)]$ErrorRecord)

    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) {
        return $null
    }
    return [int]$response.StatusCode
}

$appRoot = Split-Path -Parent $PSScriptRoot
$serverRoot = Join-Path $appRoot 'community_server'
$serverEntryPoint = Join-Path $serverRoot 'src\server.js'
$clientSmokeTest = Join-Path $appRoot 'tool\account_chain_smoke.dart'
if (-not (Test-Path -LiteralPath $serverEntryPoint -PathType Leaf)) {
    throw "Community server entry point was not found: $serverEntryPoint"
}
if (-not (Test-Path -LiteralPath $clientSmokeTest -PathType Leaf)) {
    throw "Client smoke test was not found: $clientSmokeTest"
}

$runId = [Guid]::NewGuid().ToString('N').Substring(0, 16)
$expectedEmail = "sohun.smoke.$runId@example.test"
$expectedHandle = "smoke_$runId"
$port = Get-AvailableLoopbackPort
$baseUrl = "http://127.0.0.1:$port"
$adminToken = New-CryptographicSecret
$tempCandidate = Join-Path ([System.IO.Path]::GetTempPath()) "sohun-account-chain-$runId"
$tempDirectory = Get-ValidatedSmokeDirectory -Path $tempCandidate
$null = New-Item -ItemType Directory -Path $tempDirectory
$databasePath = Join-Path $tempDirectory 'community.sqlite'
$backupDirectory = Join-Path $tempDirectory 'backups'
$serverStdout = Join-Path $tempDirectory 'server.stdout.log'
$serverStderr = Join-Path $tempDirectory 'server.stderr.log'
$serverProcess = $null

$serverEnvironment = @{
    'HOST'                                 = '127.0.0.1'
    'PORT'                                 = [string]$port
    'NODE_ENV'                             = 'production'
    'COMMUNITY_DATABASE_PATH'              = $databasePath
    'COMMUNITY_BACKUP_DIRECTORY'           = $backupDirectory
    'COMMUNITY_BACKUP_RETENTION_DAYS'      = '30'
    'COMMUNITY_BACKUP_INTERVAL_HOURS'      = '24'
    'COMMUNITY_PASSWORD_PEPPER'            = New-CryptographicSecret
    'COMMUNITY_ADMIN_TOKEN'                = $adminToken
    'COMMUNITY_SUPPORT_EMAIL'              = 'support@example.test'
    'COMMUNITY_ALLOWED_ORIGIN'              = 'http://127.0.0.1'
    'COMMUNITY_REGISTRATION_ENABLED'        = 'true'
    'COMMUNITY_REQUIRE_EMAIL_VERIFICATION'  = 'false'
    'COMMUNITY_TERMS_VERSION'               = '2026-07-29'
    'COMMUNITY_PRIVACY_VERSION'             = '2026-07-29'
}
$previousEnvironment = @{}

try {
    foreach ($name in $serverEnvironment.Keys) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable(
            $name,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            $name,
            $serverEnvironment[$name],
            [EnvironmentVariableTarget]::Process
        )
    }

    try {
        $serverProcess = Start-Process `
            -FilePath $NodePath `
            -ArgumentList @('src/server.js') `
            -WorkingDirectory $serverRoot `
            -WindowStyle Hidden `
            -RedirectStandardOutput $serverStdout `
            -RedirectStandardError $serverStderr `
            -PassThru
    }
    finally {
        foreach ($name in $serverEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $previousEnvironment[$name],
                [EnvironmentVariableTarget]::Process
            )
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds($StartupTimeoutSeconds)
    $health = $null
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($serverProcess.HasExited) {
            throw "Community server exited before becoming healthy (exit $($serverProcess.ExitCode))."
        }
        try {
            $health = Invoke-RestMethod `
                -Method Get `
                -Uri "$baseUrl/health" `
                -TimeoutSec 2
            if ($health.ok -eq $true) {
                break
            }
        }
        catch {
            Start-Sleep -Milliseconds 200
        }
    }
    if ($null -eq $health -or $health.ok -ne $true) {
        throw "Community server did not become healthy within $StartupTimeoutSeconds seconds."
    }
    if (
        $health.service -ne 'sohun-community' -or
        [int]$health.apiVersion -ne 1 -or
        $health.registrationEnabled -ne $true
    ) {
        throw 'Community server health metadata is incompatible with this client.'
    }
    $ready = Invoke-RestMethod `
        -Method Get `
        -Uri "$baseUrl/ready" `
        -TimeoutSec 5
    if (
        $ready.ok -ne $true -or
        $ready.checks.database -ne 'ok' -or
        $ready.checks.backup -ne 'ok'
    ) {
        throw 'Community server readiness or startup backup check failed.'
    }

    Push-Location $appRoot
    try {
        & $FlutterPath `
            test `
            'tool/account_chain_smoke.dart' `
            "--dart-define=ACCOUNT_CHAIN_BASE_URL=$baseUrl" `
            "--dart-define=ACCOUNT_CHAIN_RUN_ID=$runId" `
            '--reporter=expanded' `
            '--concurrency=1'
        if ($LASTEXITCODE -ne 0) {
            throw "Flutter account-chain test failed with exit code $LASTEXITCODE."
        }
    }
    finally {
        Pop-Location
    }

    try {
        $null = Invoke-WebRequest `
            -Method Get `
            -Uri "$baseUrl/v1/admin/users?limit=1" `
            -UseBasicParsing `
            -TimeoutSec 5
        throw 'Admin user directory unexpectedly allowed an unauthenticated request.'
    }
    catch {
        $statusCode = Get-HttpFailureStatusCode -ErrorRecord $_
        if ($statusCode -ne 403) {
            throw
        }
    }

    $encodedEmail = [Uri]::EscapeDataString($expectedEmail)
    $adminResponse = Invoke-WebRequest `
        -Method Get `
        -Uri "$baseUrl/v1/admin/users?q=$encodedEmail&limit=10" `
        -Headers @{ Authorization = "Bearer $adminToken" } `
        -UseBasicParsing `
        -TimeoutSec 5
    $adminJson = [string]$adminResponse.Content
    if ($adminJson -match '(?i)"[^"]*(password|token|hash)[^"]*"\s*:') {
        throw 'Admin user directory exposed a password, token, or hash field.'
    }
    $directory = $adminJson | ConvertFrom-Json
    $matchingUsers = @($directory.items | Where-Object {
        $_.email -eq $expectedEmail -and $_.handle -eq $expectedHandle
    })
    if ($matchingUsers.Count -ne 1) {
        throw "Expected exactly one registered account in the owner directory; found $($matchingUsers.Count)."
    }
    $registeredUser = $matchingUsers[0]
    if (
        $registeredUser.status -ne 'active' -or
        $registeredUser.termsVersion -ne '2026-07-29' -or
        $registeredUser.privacyVersion -ne '2026-07-29' -or
        [string]::IsNullOrWhiteSpace([string]$registeredUser.termsAcceptedAt)
    ) {
        throw 'Owner directory returned incomplete account or consent metadata.'
    }

    $metrics = Invoke-RestMethod `
        -Method Get `
        -Uri "$baseUrl/v1/admin/metrics" `
        -Headers @{ Authorization = "Bearer $adminToken" } `
        -TimeoutSec 5
    if (
        $metrics.database.healthy -ne $true -or
        [int]$metrics.database.schemaVersion -lt 10 -or
        $metrics.backup.configured -ne $true
    ) {
        throw 'Owner monitoring metrics did not confirm database and backup readiness.'
    }

    Write-Host "[PASS] Real client account lifecycle completed at $baseUrl"
    Write-Host "[PASS] Logout revoked both current access and refresh credentials"
    Write-Host "[PASS] Protected owner directory contains $expectedEmail"
    Write-Host '[PASS] Owner directory exposes no password, token, or hash fields'
    Write-Host '[PASS] Versioned policy documents, readiness, metrics and startup backup are healthy'
}
catch {
    Write-Host "Account-chain smoke failed: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath $serverStdout -PathType Leaf) {
        Write-Host '--- community server stdout ---'
        Get-Content -LiteralPath $serverStdout
    }
    if (Test-Path -LiteralPath $serverStderr -PathType Leaf) {
        Write-Host '--- community server stderr ---'
        Get-Content -LiteralPath $serverStderr
    }
    throw
}
finally {
    if ($null -ne $serverProcess -and -not $serverProcess.HasExited) {
        Stop-Process -Id $serverProcess.Id -Force
        $null = $serverProcess.WaitForExit(5000)
    }
    if (Test-Path -LiteralPath $tempDirectory) {
        $safeDirectory = Get-ValidatedSmokeDirectory -Path $tempDirectory
        Remove-Item -LiteralPath $safeDirectory -Recurse -Force
    }
}
