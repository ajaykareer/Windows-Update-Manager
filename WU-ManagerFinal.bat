@echo off
setlocal EnableExtensions EnableDelayedExpansion

:: ================================================================================
::  WU-Manager — Windows Update hard lock for POS
::  Created with love by KAREER
::  - ASCII UI (works on any console/font)
::  - Watchdog: BOOT + every 1 minute (SYSTEM)
::  - Status: PowerShell table + guaranteed pause
::  - Menu input: CHOICE (no stray buffered keys)
:: ================================================================================

title WU-Manager (POS hard lock) - Created with love by KAREER
color 0A
mode con: cols=108 lines=34

:: ---- Admin check (no auto-elevate; keep window open) ----
fltmc >nul 2>&1 || (
  color 0C
  echo.
  echo ====================================================================================================
  echo  [!] Please run this as Administrator. Right-click this file and choose "Run as administrator".
  echo ====================================================================================================
  echo.
  pause
  exit
)

:: ---- Config ----
set "SERVICES=wuauserv UsoSvc BITS DoSvc WaaSMedicSvc"
set "KILLPROCS=MoUsoCoreWorker.exe usoclient.exe WaaSMedicAgent.exe"
set "GUARD_DIR=%ProgramData%\WU_Guardian"
set "GUARD_CMD=%GUARD_DIR%\guardian.cmd"
set "GUARD_RUN=%GUARD_DIR%\run.cmd"
set "TASK_MAIN=WU-Guardian"
set "TASK_BOOT=WU-Guardian_Startup"

:: ---- OS info (display only) ----
for /f "tokens=3" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul ^| find "CurrentBuildNumber"') do set "Build=%%A"
for /f "tokens=3*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul ^| find "DisplayVersion"') do set "DispVer=%%A"
if not defined DispVer set "DispVer=22H2"
set "Product=Windows 10"
if defined Build if %Build% GEQ 22000 set "Product=Windows 11"

:: ---- Jump to menu (avoid falling into labels) ----
goto :menu

:: =============================== HELPERS =========================================

:header
cls
color 0A
echo.
echo =====================================================================================================
echo  WU-Manager  -  Windows Update Control (POS hard lock)                  Created with love by KAREER
echo -----------------------------------------------------------------------------------------------------
echo  Detected: %Product%   Version: %DispVer%   Build: %Build%
echo =====================================================================================================
echo.
exit /b

:get_state_word
:: in:  %1 service  out: %RET_STATE% = RUNNING/STOPPED/OTHER
set "RET_STATE=OTHER"
for /f "tokens=*" %%L in ('sc query %~1 ^| findstr /I "RUNNING STOPPED"') do (
  echo %%L | find /I "RUNNING" >nul && set "RET_STATE=RUNNING"
  echo %%L | find /I "STOPPED" >nul && set "RET_STATE=STOPPED"
)
exit /b

:get_start_hex
:: in: %1 service  out: %RET_START_HEX% = 0xN
set "RET_START_HEX="
for /f "tokens=3" %%A in ('reg query "HKLM\SYSTEM\CurrentControlSet\Services\%~1" /v Start 2^>nul ^| find /I "Start"') do set "RET_START_HEX=%%A"
if not defined RET_START_HEX set "RET_START_HEX=0x?"
exit /b

:map_start_hex
:: in: %1  (0x4/0x3/0x2)  out: %RET_START_TXT%
set "RET_START_TXT=UNKNOWN"
echo %~1 | find /I "0x4" >nul && set "RET_START_TXT=DISABLED"
echo %~1 | find /I "0x3" >nul && set "RET_START_TXT=MANUAL"
echo %~1 | find /I "0x2" >nul && set "RET_START_TXT=AUTOMATIC"
exit /b

:status_detect
set "NAU=" & set "UWS=" & set "WUS="
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate >nul 2>&1 && (
  reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate | findstr /I "0x1" >nul && set "NAU=1"
)
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer >nul 2>&1 && (
  reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer | findstr /I "0x1" >nul && set "UWS=1"
)
reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer >nul 2>&1 && (
  reg query "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer | findstr /I "127.0.0.1" >nul && set "WUS=1"
)

call :get_state_word wuauserv
set "SVC_STATE=%RET_STATE%"
call :get_start_hex wuauserv
set "SVC_START_HEX=%RET_START_HEX%"
call :map_start_hex %SVC_START_HEX%
set "SVC_START_TXT=%RET_START_TXT%"

set "STATUS=ENABLED"
if /I "%SVC_START_TXT%"=="DISABLED" if /I "%SVC_STATE%"=="STOPPED" (
  set "STATUS=BLOCKED (HARD)"
) else (
  if "%NAU%"=="1" if "%UWS%"=="1" set "STATUS=BLOCKED (POLICY)"
)
exit /b

:restart_prompt
echo.
color 0E
echo ==================================================================================
echo  Restart is recommended to fully lock the change.
echo  [1] Restart now    [0] Return to menu
echo ==================================================================================
color 0A
choice /C 10 /N /M "Choose: "
if errorlevel 2 goto :menu
if errorlevel 1 shutdown /r /t 0
goto :menu

:: =============================== CORE ACTIONS =====================================

:disable_core
echo.
echo [1/4] Writing policy keys...
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersion /t REG_DWORD /d 1 /f >nul
for /f "tokens=3*" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v DisplayVersion 2^>nul') do set "DV=%%A"
if not defined DV set "DV=22H2"
for /f "tokens=3" %%A in ('reg query "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion" /v CurrentBuildNumber 2^>nul') do set "BLD=%%A"
if "%BLD%" GEQ "22000" (set "PV=Windows 11") else (set "PV=Windows 10")
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v TargetReleaseVersionInfo /t REG_SZ /d "%DV%" /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ProductVersion /t REG_SZ /d "%PV%" /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v SetDisableUXWUAccess /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v ExcludeWUDriversInQualityUpdate /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableOSUpgrade /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DoNotConnectToWindowsUpdateInternetLocations /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /t REG_SZ /d "http://127.0.0.1:8530" /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /t REG_SZ /d "http://127.0.0.1:8530" /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /t REG_DWORD /d 1 /f >nul
reg add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f >nul

echo [2/4] Killing update-related processes...
for %%P in (%KILLPROCS%) do taskkill /F /IM %%P >nul 2>&1

echo [3/4] Disabling services (WU, Uso, BITS, DoSvc, Medic)...
for %%S in (%SERVICES%) do (
  sc stop %%S >nul 2>&1
  sc config %%S start= disabled >nul 2>&1
  reg add "HKLM\SYSTEM\CurrentControlSet\Services\%%S" /v Start /t REG_DWORD /d 4 /f >nul 2>&1
)

echo [4/4] Disabling scheduled tasks...
for %%T in (
  "\Microsoft\Windows\WindowsUpdate\Scheduled Start"
  "\Microsoft\Windows\WindowsUpdate\Automatic App Update"
  "\Microsoft\Windows\WindowsUpdate\AUScheduledInstall"
  "\Microsoft\Windows\WindowsUpdate\Maintenance Install"
  "\Microsoft\Windows\WindowsUpdate\Scheduled Start With Network"
  "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan"
  "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_Display"
  "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_ReadyToReboot"
  "\Microsoft\Windows\UpdateOrchestrator\Reboot"
  "\Microsoft\Windows\UpdateOrchestrator\Maintenance Install"
  "\Microsoft\Windows\WaaSMedic\PerformRemediation"
  "\Microsoft\Windows\WaaSMedic\WaaSMedic Scheduled"
) do schtasks /Change /TN %%T /Disable >nul 2>&1

gpupdate /force >nul 2>&1

:: ---- Watchdog (BOOT + every 1 minute, SYSTEM) and run once now ----
if not exist "%GUARD_DIR%" mkdir "%GUARD_DIR%" >nul 2>&1
> "%GUARD_CMD%" echo @echo off
>>"%GUARD_CMD%" echo rem Guardian - keep Windows Update stack disabled (KAREER)
>>"%GUARD_CMD%" echo for %%%%P in (%KILLPROCS%) do taskkill /F /IM %%%%P ^>nul 2^>^&1
>>"%GUARD_CMD%" echo for %%%%S in (%SERVICES%) do ^(
>>"%GUARD_CMD%" echo   sc stop %%%%S ^>nul 2^>^&1
>>"%GUARD_CMD%" echo   sc config %%%%S start^= disabled ^>nul 2^>^&1
>>"%GUARD_CMD%" echo   reg add "HKLM\System\CurrentControlSet\Services\%%%%S" /v Start /t REG_DWORD /d 4 /f ^>nul 2^>^&1
>>"%GUARD_CMD%" echo ^)
> "%GUARD_RUN%" echo @echo off
>>"%GUARD_RUN%" echo "%GUARD_CMD%"

schtasks /Delete /TN "%TASK_MAIN%" /F >nul 2>&1
schtasks /Delete /TN "%TASK_BOOT%" /F >nul 2>&1
schtasks /Create /TN "%TASK_MAIN%" /SC MINUTE /MO 1 /TR "\"%GUARD_RUN%\"" /RU SYSTEM /RL HIGHEST /F >nul 2>&1
schtasks /Create /TN "%TASK_BOOT%" /SC ONSTART /TR "\"%GUARD_RUN%\"" /RU SYSTEM /RL HIGHEST /F >nul 2>&1
call "%GUARD_RUN%" >nul 2>&1

echo.
echo [OK] Hard block applied and watchdog installed.
exit /b

:enable_core
echo.
echo [1/4] Removing policy keys...
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /f >nul 2>&1

echo [2/4] Restoring services to Manual and starting them...
for %%S in (%SERVICES%) do (
  sc config %%S start= demand >nul 2>&1
  reg add "HKLM\SYSTEM\CurrentControlSet\Services\%%S" /v Start /t REG_DWORD /d 3 /f >nul 2>&1
  sc start %%S >nul 2>&1
)

echo [3/4] Enabling scheduled tasks...
for %%T in (
  "\Microsoft\Windows\WindowsUpdate\Scheduled Start"
  "\Microsoft\Windows\WindowsUpdate\Automatic App Update"
  "\Microsoft\Windows\WindowsUpdate\AUScheduledInstall"
  "\Microsoft\Windows\WindowsUpdate\Maintenance Install"
  "\Microsoft\Windows\WindowsUpdate\Scheduled Start With Network"
  "\Microsoft\Windows\UpdateOrchestrator\Schedule Scan"
  "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_Display"
  "\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_ReadyToReboot"
  "\Microsoft\Windows\UpdateOrchestrator\Reboot"
  "\Microsoft\Windows\UpdateOrchestrator\Maintenance Install"
  "\Microsoft\Windows\WaaSMedic\PerformRemediation"
  "\Microsoft\Windows\WaaSMedic\WaaSMedic Scheduled"
) do schtasks /Change /TN %%T /Enable >nul 2>&1

echo [4/4] Removing watchdog...
schtasks /Delete /TN "%TASK_MAIN%" /F >nul 2>&1
schtasks /Delete /TN "%TASK_BOOT%" /F >nul 2>&1
if exist "%GUARD_RUN%" del /f /q "%GUARD_RUN%" >nul 2>&1
if exist "%GUARD_CMD%" del /f /q "%GUARD_CMD%" >nul 2>&1
if exist "%GUARD_DIR%" rd "%GUARD_DIR%" >nul 2>&1

gpupdate /force >nul 2>&1
echo.
echo [OK] Windows Update restored to normal.
exit /b

:: =============================== MENU (CHOICE) ====================================

:menu
call :status_detect
call :header
echo  Current: %STATUS%
echo.
echo    [1]  STOP updates completely   (apply hard block + watchdog)
echo    [2]  START updates             (restore + remove watchdog)
echo    [3]  CHECK status (detailed)
echo    [0]  EXIT
echo.

:: CHOICE avoids stray buffered keys
choice /C 1230 /N /M "Select [1/2/3/0]: "
set "CH="
if !errorlevel!==1 set "CH=1"
if !errorlevel!==2 set "CH=2"
if !errorlevel!==3 set "CH=3"
if !errorlevel!==4 set "CH=0"

if "!CH!"=="1" goto :option_1
if "!CH!"=="2" goto :option_2
if "!CH!"=="3" goto :option_3
if "!CH!"=="0" goto :option_0
goto :menu

:option_1
call :disable_core
call :restart_prompt
goto :menu

:option_2
call :enable_core
call :restart_prompt
goto :menu

:option_3
call :header
echo  Current: %STATUS%
echo.
powershell -NoLogo -NoProfile -ExecutionPolicy Bypass -Command ^
  "$svcs='wuauserv','UsoSvc','BITS','DoSvc','WaaSMedicSvc';" ^
  "Get-Service $svcs | Select Name,Status,StartType | Format-Table -AutoSize;" ^
  "Write-Host '';" ^
  "$au='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU';" ^
  "$wu='HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate';" ^
  "try{$nau=(Get-ItemProperty -Path $au -Name NoAutoUpdate -ErrorAction Stop).NoAutoUpdate}catch{$nau='(not set)'};" ^
  "try{$uws=(Get-ItemProperty -Path $au -Name UseWUServer -ErrorAction Stop).UseWUServer}catch{$uws='(not set)'};" ^
  "try{$wus=(Get-ItemProperty -Path $wu -Name WUServer -ErrorAction Stop).WUServer}catch{$wus='(not set)'};" ^
  "Write-Host 'Policy signals:';" ^
  "Write-Host ('  NoAutoUpdate: {0}   UseWUServer: {1}   WUServer: {2}' -f $nau,$uws,$wus);" ^
  "Write-Host '';"
echo Press any key to return to the menu . . .
pause >nul
goto :menu

:option_0
echo.
echo ====================================================================================================
echo   Bye!  Created with love by KAREER
echo ====================================================================================================
echo.
pause
exit /b