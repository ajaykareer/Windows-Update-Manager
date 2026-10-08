@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Update Control Desktop
for %%F in (UpdateControl.GUI.ps1 UpdateControl.xaml UpdateControl.Worker.ps1 UpdateControl.ps1 Repair-WindowsStore.ps1) do (
    if not exist "%~dp0%%F" (
        echo Missing %%F. Extract ALL files from the ZIP into one folder first.
        pause
        exit /b 1
    )
)
set "UPDATE_CONTROL_GUI=%~dp0UpdateControl.GUI.ps1"
set "UPDATE_CONTROL_PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if exist "%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe" set "UPDATE_CONTROL_PS=%SystemRoot%\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
"%UPDATE_CONTROL_PS%" -NoLogo -NoProfile -Command "$q=[char]34; $a='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File '+$q+$env:UPDATE_CONTROL_GUI+$q; Start-Process -FilePath $env:UPDATE_CONTROL_PS -ArgumentList $a -WindowStyle Hidden"
set "RESULT=%errorlevel%"
if not "%RESULT%"=="0" (
    echo Could not start the interface. Try Update-Control-Console.cmd.
    pause
)
exit /b %RESULT%