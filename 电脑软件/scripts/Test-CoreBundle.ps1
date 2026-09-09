[CmdletBinding()]
param([Parameter(Mandatory = $true)][string]$BundlePath)
$ErrorActionPreference = 'Stop'
$resolved = [IO.Path]::GetFullPath($BundlePath)
$archive = $null
try {
    if (Test-Path -LiteralPath $resolved -PathType Container) {
        $names = @(Get-ChildItem -LiteralPath $resolved -File -Recurse -Force | ForEach-Object { $_.FullName.Substring($resolved.Length + 1).Replace('\', '/') })
    } elseif ((Test-Path -LiteralPath $resolved -PathType Leaf) -and [IO.Path]::GetExtension($resolved) -in @('.zip', '.apk')) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($resolved)
        # ZipDirectoryEntry names are not guaranteed to carry a trailing slash
        # on every .NET/PowerShell version. Normalize first, then omit directory
        # entries so the same allow/deny checks work for clean preview archives.
        $names = @($archive.Entries | ForEach-Object {
            $normalized = $_.FullName.Replace('\', '/')
            if (-not $normalized.EndsWith('/')) { $normalized }
        })
    } else { throw 'Core bundle must be a directory, portable ZIP, or Android APK.' }
    foreach ($name in $names) {
        if ([string]::IsNullOrWhiteSpace($name) -or $name.Contains('\') -or
            $name.StartsWith('/') -or $name.Contains('//') -or
            $name -match '(^|/)\.\.?(/|$)' -or $name -match '^[A-Za-z]:') {
            throw "Unsafe path in core bundle: $name"
        }
        $leaf = ($name.Split('/'))[-1]
        if ($leaf -match '^(bambu_networking\.dll|slicer_base64\.cer|bind_tool\.exe|switch_user_tool\.exe|cloud_camera_bridge\.exe|ffmpeg(?:\.exe)?|libmpv.*|libEGL\.dll|libGLESv2\.dll|vulkan-1\.dll)$') {
            throw "Excluded optional native component in core bundle: $name"
        }
        if ($name -match '(^|/)assets/(bin|tools|bambu_presets|images/bambu_icons|knowledge|calibration)/' -and $leaf -ne '.gitkeep') {
            throw "Excluded reference asset in core bundle: $name"
        }
        if ($leaf -match '\.(pem|pfx|p12|key|keystore|jks|sqlite|sqlite3|db)$' -or
            $leaf -match '\.(db|sqlite|sqlite3)-(wal|shm|journal)$' -or
            $leaf -match '^\.env(?:\.|$)' -or
            $leaf -in @('local.properties', 'key.properties', 'release-clearance.json')) {
            throw "Private data must not be distributed: $name"
        }
    }
    if ($names.Count -eq 0) { throw 'Core bundle is empty.' }
    Write-Host "[core] Verified $($names.Count) bundle entries; excluded assets and private material absent."
} finally { if ($null -ne $archive) { $archive.Dispose() } }
