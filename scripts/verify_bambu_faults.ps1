param([switch]$CheckOfficialVersion)
$ErrorActionPreference = 'Stop'
$taskRoot = Split-Path -Parent $PSScriptRoot
$taskApp = Join-Path $taskRoot '电脑软件'
if ($CheckOfficialVersion) {
    $taskCatalog = Get-Content -LiteralPath (Join-Path $taskApp 'assets/knowledge/printer_faults_zh_CN.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $taskRemote = Invoke-RestMethod -Uri 'https://e.bambulab.com/query.php?lang=zh-cn&v=0'
    if ($taskRemote.result -ne 0 -or [string]$taskRemote.ver -ne $taskCatalog.sourceVersion) {
        throw '官方故障库版本有变化或查询失败，请运行 update_bambu_fault_catalog.py 后复核设备文案差异。'
    }
}
Push-Location -LiteralPath $taskApp
try {
    & flutter test --no-pub test/printer_fault_monitor_test.dart test/printer_fault_service_test.dart test/printer_alerts_test.dart test/bambu_telemetry_facts_test.dart test/printer_fault_ui_test.dart test/mobile_printer_faults_test.dart
    if ($LASTEXITCODE -ne 0) { throw '故障 Flutter 专项未通过' }
    Push-Location -LiteralPath (Join-Path $taskApp 'community_server')
    try {
        & node --test test/printer_faults.test.js
        if ($LASTEXITCODE -ne 0) { throw '故障服务端专项未通过' }
    } finally { Pop-Location }
} finally { Pop-Location }
