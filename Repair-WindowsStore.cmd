@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Repair Windows Update and Microsoft Store
if not exist "%~dp0Repair-WindowsStore.ps1" (
    echo Missing Repair-WindowsStore.ps1. Extract the entire ZIP first.
    pause
    exit /b 1
)
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
if exist "%~dp0UpdateControl.ps1" (
    "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpdateControl.ps1" -Action Restore
) else (
    "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-WindowsStore.ps1"
)
set "RESULT=%errorlevel%"
echo.
echo Repair exit code: %RESULT%
echo 0 = checks passed; 3010 = restart required; 2 = incomplete; 1 = failed.
echo If administrator access is required, right-click this file and Run as administrator.
pause
exit /b %RESULT%
