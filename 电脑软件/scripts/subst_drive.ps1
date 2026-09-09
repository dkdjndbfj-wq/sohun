# Maps the project directory to an ASCII drive letter (W:) via `subst`, so
# that `flutter run -d windows` can be launched from an ASCII path. This
# preserves hot reload (the source tree stays in place) while bypassing the
# CMake install failure caused by Chinese characters in the project path.
#
# Usage:
#   .\scripts\subst_drive.ps1              # mount W: (auto-picks next free letter if W: is taken)
#   .\scripts\subst_drive.ps1 -Unmount     # unmount W:
#   .\scripts\subst_drive.ps1 -DriveLetter Z
#
# After mounting, open the project from W:\ in VSCode or IntelliJ, or run:
#   cd W:\; flutter run -d windows

[CmdletBinding()]
param(
    [switch]$Unmount,
    [ValidatePattern("^[A-Z]$")]
    [string]$DriveLetter = "W"
)

$projectRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$projectRoot = [System.IO.Path]::GetFullPath($projectRoot).TrimEnd('\')
$drive = "${DriveLetter}:"

if ($Unmount) {
    Write-Host "[subst] Removing $drive -> $projectRoot"
    & subst $drive /D 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        Write-Host "[subst] $drive unmounted." -ForegroundColor Green
    } else {
        Write-Host "[subst] $drive was not mounted (or already removed)." -ForegroundColor Yellow
    }
    return
}

# Check if drive letter is already in use by a real volume.
$existing = Get-PSDrive -Name $DriveLetter -ErrorAction SilentlyContinue
if ($existing -and $existing.Provider.Name -eq "FileSystem" -and $existing.DisplayRoot) {
    # Could be our own subst or a real volume. Check if it points to our project.
    $resolved = (Get-Item $drive -ErrorAction SilentlyContinue).Target
    if ($resolved -eq $projectRoot) {
        Write-Host "[subst] $drive already mounted to $projectRoot" -ForegroundColor Green
        return
    }
    # Drive letter taken by another volume; pick the next free letter A..Z.
    Write-Host "[subst] $drive is in use by $($existing.DisplayRoot); picking next free letter." -ForegroundColor Yellow
    $used = (Get-PSDrive -PSProvider FileSystem).Name
    for ($c = [int][char]'W'; $c -le [int][char]'Z'; $c++) {
        $candidate = [char]$c
        if ($used -notcontains $candidate) {
            $DriveLetter = $candidate
            $drive = "${candidate}:"
            break
        }
    }
    if ($used -contains $DriveLetter) {
        throw "No free drive letter in W..Z range. Unmount one of them and retry."
    }
}

Write-Host "[subst] Mounting $drive -> $projectRoot"
& subst $drive $projectRoot
if ($LASTEXITCODE -ne 0) {
    throw "subst failed (exit $LASTEXITCODE). Try running as Administrator."
}

# Verify mount.
if (-not (Test-Path "$drive\pubspec.yaml")) {
    & subst $drive /D 2>&1 | Out-Null
    throw "subst mount succeeded but $drive\pubspec.yaml not found. Rollback."
}

Write-Host "[subst] Mounted. Open this path in your IDE / flutter run:" -ForegroundColor Green
Write-Host "  $drive\"
Write-Host ""
Write-Host "To unmount later, run: .\scripts\subst_drive.ps1 -Unmount -DriveLetter $DriveLetter" -ForegroundColor Cyan
