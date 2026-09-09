[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ManifestPath
)

$ErrorActionPreference = "Stop"
if (!(Test-Path -LiteralPath $ManifestPath -PathType Leaf)) {
    throw "Third-party clearance manifest does not exist: $ManifestPath"
}
try {
    $manifest = Get-Content -Raw -LiteralPath $ManifestPath -Encoding utf8 | ConvertFrom-Json
} catch {
    throw "Third-party clearance manifest is not valid JSON."
}
if ($manifest.schemaVersion -ne 1 -or $manifest.product -ne "sohun-consumable-workbench") {
    throw "Third-party clearance manifest schema/product does not match this release."
}
if ($manifest.approvedForCommercialRedistribution -ne $true) {
    throw "Third-party material is not approved for commercial redistribution."
}
if ([string]::IsNullOrWhiteSpace([string]$manifest.approvedBy) -or
    [string]::IsNullOrWhiteSpace([string]$manifest.approvalReference)) {
    throw "Clearance manifest must identify the approver and written approval reference."
}
$approvedAt = [DateTimeOffset]::MinValue
if (![DateTimeOffset]::TryParse([string]$manifest.approvedAt, [ref]$approvedAt) -or
    $approvedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(5)) {
    throw "Clearance manifest approvedAt is missing, invalid, or in the future."
}

$requiredItems = @(
    "bambu-icons",
    "bambu-presets",
    "bambu-networking-binary",
    "bambu-slicer-certificate",
    "native-integration-wrappers",
    "ffmpeg-runtime",
    "msvc-runtime",
    "printer-fault-knowledge"
)
if ($manifest.items -isnot [System.Array]) {
    throw "Clearance manifest items must be an array."
}
foreach ($requiredId in $requiredItems) {
    $matches = @($manifest.items | Where-Object { $_.id -eq $requiredId })
    if ($matches.Count -ne 1) {
        throw "Clearance manifest must contain exactly one item named '$requiredId'."
    }
    $item = $matches[0]
    if ($item.status -ne "cleared" -or
        [string]::IsNullOrWhiteSpace([string]$item.rightsBasis) -or
        [string]::IsNullOrWhiteSpace([string]$item.evidenceReference)) {
        throw "Clearance item '$requiredId' is not fully cleared with rights basis and evidence."
    }
}

Write-Host "Third-party release clearance manifest passed all required gates." -ForegroundColor Green
return $manifest
