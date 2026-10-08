@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Update Control 4.0
if not exist "%~dp0UpdateControl.ps1" (
    echo Extract ALL files from the Update Control ZIP into one folder first.
    pause
    exit /b 1
)
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%PS%" -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpdateControl.ps1" -Action Menu
set "RESULT=%errorlevel%"
if not "%RESULT%"=="0" pause
exit /b %RESULT%
