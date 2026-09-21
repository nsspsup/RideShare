<#
.SYNOPSIS
    Creates a "Camera Internet" shortcut on the desktop (and optionally in the
    Start menu) for the CameraInternet.ps1 utility.

.DESCRIPTION
    The shortcut starts powershell.exe directly with a hidden window, so no
    console flashes up, and it is marked "run as administrator" so Windows
    shows the UAC prompt immediately instead of the script restarting itself.

    The icon is generated locally by CameraInternet.ps1 -ExportIcon, so no
    external files or downloads are required.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-CameraInternet.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-CameraInternet.ps1 -StartMenu

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Install-CameraInternet.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [switch]$StartMenu,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$shortcutName = 'Camera Internet.lnk'
$desktopPath  = [System.Environment]::GetFolderPath('Desktop')
$startMenuDir = Join-Path ([System.Environment]::GetFolderPath('Programs')) 'Camera Internet'
$scriptPath   = Join-Path $PSScriptRoot 'CameraInternet.ps1'
$appDir       = Join-Path $env:LOCALAPPDATA 'CameraInternet'
$iconPath     = Join-Path $appDir 'CameraInternet.ico'

function Remove-Shortcuts {
    foreach ($path in @((Join-Path $desktopPath $shortcutName), (Join-Path $startMenuDir $shortcutName))) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Force
            Write-Host "Removed $path"
        }
    }
    if ((Test-Path -LiteralPath $startMenuDir) -and -not (Get-ChildItem -LiteralPath $startMenuDir -Force)) {
        Remove-Item -LiteralPath $startMenuDir -Force
    }
}

function New-AppIconFile {
    # Ask the application itself to draw and save its icon.
    try {
        if (-not (Test-Path -LiteralPath $appDir)) {
            New-Item -Path $appDir -ItemType Directory -Force | Out-Null
        }
        & powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File $scriptPath -ExportIcon $iconPath | Out-Null
        if (Test-Path -LiteralPath $iconPath) { return ($iconPath + ',0') }
    } catch {
        Write-Warning "The icon could not be generated: $($_.Exception.Message)"
    }
    # Fall back to a stock Windows network icon.
    return (Join-Path $env:SystemRoot 'System32\shell32.dll,17')
}

function Set-RunAsAdministratorFlag {
    <#
        Sets the "run as administrator" bit inside the .lnk file. Byte 0x15 of
        the shell link header holds the extra flags; 0x20 is the elevation bit.
    #>
    param([string]$Path)
    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        if ($bytes.Length -gt 0x15) {
            $bytes[0x15] = $bytes[0x15] -bor 0x20
            [System.IO.File]::WriteAllBytes($Path, $bytes)
        }
    } catch {
        Write-Warning "The shortcut could not be marked as 'run as administrator': $($_.Exception.Message)"
    }
}

function New-AppShortcut {
    param([string]$Path, [string]$Icon)
    $shell = New-Object -ComObject WScript.Shell
    try {
        $shortcut = $shell.CreateShortcut($Path)
        $shortcut.TargetPath       = Join-Path $PSHOME 'powershell.exe'
        $shortcut.Arguments        = '-STA -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $scriptPath
        $shortcut.WorkingDirectory = $PSScriptRoot
        $shortcut.Description      = 'Switch Internet sharing to the camera network on and off'
        $shortcut.WindowStyle      = 7          # start minimized: no console flash
        $shortcut.IconLocation     = $Icon
        $shortcut.Save()
    } finally {
        [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }
    Set-RunAsAdministratorFlag -Path $Path
    Write-Host "Created $Path"
}

if ($Uninstall) {
    Remove-Shortcuts
    Write-Host 'Camera Internet shortcuts removed. The script itself and the log file were kept.'
    return
}

if (-not (Test-Path -LiteralPath $scriptPath)) {
    throw "CameraInternet.ps1 was not found next to this installer (expected: $scriptPath)."
}

$icon = New-AppIconFile
New-AppShortcut -Path (Join-Path $desktopPath $shortcutName) -Icon $icon

if ($StartMenu) {
    if (-not (Test-Path -LiteralPath $startMenuDir)) {
        New-Item -Path $startMenuDir -ItemType Directory -Force | Out-Null
    }
    New-AppShortcut -Path (Join-Path $startMenuDir $shortcutName) -Icon $icon
}

Write-Host ''
Write-Host 'Done. Start the utility from the "Camera Internet" desktop shortcut.'
Write-Host 'Windows will ask for administrator confirmation (UAC) each time it starts.'
