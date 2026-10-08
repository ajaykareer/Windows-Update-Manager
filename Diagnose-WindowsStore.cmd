@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Diagnose Windows Update and Microsoft Store
if not exist "%~dp0Repair-WindowsStore.ps1" (
    echo Missing Repair-WindowsStore.ps1. Extract the entire ZIP first.
    pause
    exit /b 1
)
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Repair-WindowsStore.ps1" -DiagnoseOnly
set "RESULT=%errorlevel%"
if exist "%~dp0UpdateControl.ps1" (
    "%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpdateControl.ps1" -Action Report
    if errorlevel 1 set "RESULT=1"
)
echo.
echo Send the report shown above if the problem continues.
pause
exit /b %RESULT%
