[CmdletBinding()]
param(
    [switch]$CheckOfficialCatalog,
    [switch]$SkipTests
)

$ErrorActionPreference = 'Stop'
$workspaceRoot = Split-Path -Parent $PSScriptRoot
$appPath = Get-ChildItem -LiteralPath $workspaceRoot -Directory |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'lib/data/external/printer/bambu_print_feed.dart') } |
    Select-Object -First 1 -ExpandProperty FullName
if ([string]::IsNullOrWhiteSpace($appPath)) { throw 'Main Flutter project not found.' }

if ($CheckOfficialCatalog) {
    # Independently reviewed names from official BBL.json on 2026-09-05.
    # A mismatch requires a source review, not an automatic capability guess.
    $expectedModels = @(
        'Bambu Lab X1 Carbon', 'Bambu Lab X1', 'Bambu Lab X1E',
        'Bambu Lab P1P', 'Bambu Lab P1S', 'Bambu Lab P2S',
        'Bambu Lab A1 mini', 'Bambu Lab A1', 'Bambu Lab A2L',
        'Bambu Lab H2D', 'Bambu Lab H2D Pro', 'Bambu Lab H2S',
        'Bambu Lab H2C', 'Bambu Lab X2D'
    )
    $catalog = Invoke-RestMethod -Uri 'https://raw.githubusercontent.com/bambulab/BambuStudio/master/resources/profiles/BBL.json' -TimeoutSec 30
    $actualModels = @($catalog.machine_model_list | ForEach-Object { $_.name })
    if ($actualModels.Count -eq 0) { throw 'Official model catalog could not be read.' }
    $difference = @(Compare-Object ($expectedModels | Sort-Object) ($actualModels | Sort-Object))
    if ($difference.Count -gt 0) {
        $difference | Format-Table | Out-String | Write-Output
        throw 'Bambu model catalog changed. Review sources, capabilities and regression expectations before release.'
    }
    Write-Host "Official model catalog matches all $($expectedModels.Count) reviewed models."
}

if (-not $SkipTests) {
    Push-Location $appPath
    try {
        & flutter test --no-pub --concurrency=2 `
            test/bambu_feed_capabilities_test.dart `
            test/bambu_feed_incremental_test.dart `
            test/printer_feed_configuration_test.dart `
            test/ams_unit_summary_test.dart `
            test/bambu_telemetry_facts_test.dart `
            test/scheduler_enhancement_test.dart `
            test/spool_change_workflow_test.dart `
            test/external_multicolor_workflow_test.dart `
            test/external_multicolor_dialog_test.dart `
            test/fleet_queue_twin_closure_test.dart `
            test/studio_dispatch_service_test.dart `
            test/threemf_parser_test.dart `
            test/ui_regression_test.dart `
            test/add_printer_feed_config_test.dart `
            test/personal_spool_maintenance_test.dart `
            test/parameter_compatibility_service_test.dart
        if ($LASTEXITCODE -ne 0) { throw 'Bambu feed regression tests failed.' }
    } finally {
        Pop-Location
    }
}
