@echo off
rem ---------------------------------------------------------------------------
rem  Camera Internet - launcher
rem
rem  Starts the GUI without leaving a PowerShell console window behind it.
rem  The script itself asks for administrator rights (UAC) when needed.
rem ---------------------------------------------------------------------------
setlocal

set "PS1=%~dp0CameraInternet.ps1"

if not exist "%PS1%" (
    echo CameraInternet.ps1 was not found next to this launcher.
    echo Expected location: "%PS1%"
    pause
    exit /b 1
)

start "" powershell.exe -STA -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%PS1%"

endlocal
exit /b 0
