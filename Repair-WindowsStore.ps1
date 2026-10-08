#Requires -Version 5.1
<#
Repair the changes made by WindowsUpdateManager.bat v3.0.
Run elevated to repair, or use -DiagnoseOnly without elevation.
No automatic restart, update scan, app installation, or cache deletion.
#>
[CmdletBinding()]
param([switch]$DiagnoseOnly, [switch]$KeepAutomaticUpdatesDisabled)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Issues = New-Object 'System.Collections.Generic.List[string]'
$script:NeedsRestart = $false
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$report = Join-Path $env:TEMP "WU-Store-Repair-$stamp-$PID.txt"
$guardDir = Join-Path $env:ProgramData 'POS_WU_Guardian'
$guardNames = @('POS-WU-Guardian', 'POS-WU-Guardian_Startup', 'POS-WU-Guardian_Hourly','WU-Guardian','WU-Guardian_Startup','WU-Guardian_Hourly')
$olderGuardDir = Join-Path $env:ProgramData 'WU_Guardian'
$wu = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$au = "$wu\AU"
$serviceRoot = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services'
$medicKey = "$serviceRoot\WaaSMedicSvc"
$serviceModes = [ordered]@{
    wuauserv = 3; BITS = 3; UsoSvc = 2; DoSvc = 2; WaaSMedicSvc = 3
    InstallService = 3; AppXSvc = 3; ClipSVC = 3; wUpdate = 3
}
$taskPaths = @(
    '\Microsoft\Windows\WindowsUpdate\Scheduled Start'
    '\Microsoft\Windows\WindowsUpdate\Automatic App Update'
    '\Microsoft\Windows\WindowsUpdate\AUScheduledInstall'
    '\Microsoft\Windows\WindowsUpdate\AUFeaturedAppsInstall'
    '\Microsoft\Windows\WindowsUpdate\Maintenance Install'
    '\Microsoft\Windows\WindowsUpdate\Scheduled Start With Network'
    '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan'
    '\Microsoft\Windows\UpdateOrchestrator\Schedule Scan Static Task'
    '\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_Display'
    '\Microsoft\Windows\UpdateOrchestrator\USO_UxBroker_ReadyToReboot'
    '\Microsoft\Windows\UpdateOrchestrator\Reboot'
    '\Microsoft\Windows\UpdateOrchestrator\Reboot_AC'
    '\Microsoft\Windows\UpdateOrchestrator\Reboot_Battery'
    '\Microsoft\Windows\UpdateOrchestrator\Maintenance Install'
    '\Microsoft\Windows\UpdateOrchestrator\Universal Orchestrator Start'
    '\Microsoft\Windows\UpdateOrchestrator\Universal Orchestrator Idle'
    '\Microsoft\Windows\WaaSMedic\PerformRemediation'
    '\Microsoft\Windows\WaaSMedic\WaaSMedic Scheduled'
    '\Microsoft\XblGameSave\XblGameSaveTask'
)
# Only these named values, and only values matching v3.0, are removed.
# Existing values overwritten by v3.0 cannot be reconstructed without an old backup.
$policyGroups = @(
    @{ Path = $wu; Values = @{
        WUServer = 'http://127.0.0.1:8530'; WUStatusServer = 'http://127.0.0.1:8530'
        SetDisableUXWUAccess = 1; DisableWindowsUpdateAccess = 1
        ExcludeWUDriversInQualityUpdate = 1; DisableOSUpgrade = 1
        DoNotConnectToWindowsUpdateInternetLocations = 1; DisableDualScan = 1
    }}
    @{ Path = $au; Values = @{
        NoAutoUpdate = 1; UseWUServer = 1; AUOptions = 1
        AutoInstallMinorUpdates = 0; DetectionFrequencyEnabled = 0
        ScheduledInstallDay = 0; ScheduledInstallTime = 3
    }}
    @{ Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\DeliveryOptimization'; Values = @{
        DODownloadMode = 0; DisableDeliveryOptimizationWin10 = 1
    }}
    @{ Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\WindowsStore'; Values = @{
        AutoDownload = 2; DisableOSUpgrade = 1
    }}
    @{ Path = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'; Values = @{ HideMCTLink = 1 }}
    @{ Path = 'Registry::HKEY_CURRENT_USER\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate'; Values = @{ DisableWindowsUpdateAccess = 1 }}
)

function Write-Log([string]$Message) {
    Write-Host $Message
    Add-Content -LiteralPath $report -Value $Message -Encoding UTF8
}
function Add-Issue([string]$Message) {
    $script:Issues.Add($Message)
    Write-Log "[ATTENTION] $Message"
}
function Read-Value([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $key = Get-Item -LiteralPath $Path
    try { return $key.GetValue($Name, $null) } finally { $key.Close() }
}
function Get-GuardianTasks {
    # Enumerate rather than hiding access/enumeration errors as 'not found'.
    Get-ScheduledTask | Where-Object { $_.TaskName -in $guardNames }
}
function Get-GuardianProcesses {
    $runPath = Join-Path $guardDir 'run.cmd'
    $cmdPath = Join-Path $guardDir 'guardian.cmd'
    $olderRunPath = Join-Path $olderGuardDir 'run.cmd'
    $olderCmdPath = Join-Path $olderGuardDir 'guardian.cmd'
    Get-CimInstance Win32_Process -Filter "Name='cmd.exe'" | Where-Object {
        $_.CommandLine -and (
            $_.CommandLine.IndexOf($runPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.CommandLine.IndexOf($cmdPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.CommandLine.IndexOf($olderRunPath, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $_.CommandLine.IndexOf($olderCmdPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        )
    }
}
function Write-State([string]$Label) {
    Write-Log "`r`n--- $Label ---"
    $os = Get-CimInstance Win32_OperatingSystem
    Write-Log ("OS: {0}, version {1}, build {2}, architecture {3}" -f $os.Caption, $os.Version, $os.BuildNumber, $os.OSArchitecture)
    foreach ($svc in @(Get-CimInstance Win32_Service | Where-Object { $_.Name -in @($serviceModes.Keys) })) {
        Write-Log ("Service {0}: {1}, SCM start={2}, registry Start={3}" -f $svc.Name, $svc.State, $svc.StartMode, (Read-Value "$serviceRoot\$($svc.Name)" 'Start'))
    }
    foreach ($group in $policyGroups) {
        foreach ($name in $group.Values.Keys) {
            $value = Read-Value $group.Path $name
            if ($null -ne $value) { Write-Log ("Policy {0}\{1} = {2}" -f $group.Path, $name, $value) }
        }
    }
    foreach ($name in @('TargetReleaseVersion', 'TargetReleaseVersionInfo', 'ProductVersion')) {
        $value = Read-Value $wu $name
        if ($null -ne $value) { Write-Log "Version pin (preserved): $name = $value" }
    }
    $tasks = @(Get-GuardianTasks)
    if ($tasks.Count -eq 0) { Write-Log 'Guardian tasks: none' }
    foreach ($task in $tasks) { Write-Log "Guardian task: $($task.TaskName), $($task.State)" }
    foreach ($task in @(Get-ScheduledTask | Where-Object { ($_.TaskPath + $_.TaskName) -in $taskPaths -and $_.State -eq 'Disabled' })) {
        Write-Log "Disabled original task: $($task.TaskPath)$($task.TaskName)"
    }
    foreach ($name in @('Microsoft.WindowsStore', 'Microsoft.DesktopAppInstaller', '*ChatGPT*')) {
        foreach ($app in @(Get-AppxPackage -Name $name)) { Write-Log "App for this user: $($app.Name), $($app.Version), $($app.Status)" }
    }
}
function Save-Backup {
    $script:BackupDir = Join-Path $env:ProgramData "POS_WU_Repair\$stamp-$PID"
    New-Item -ItemType Directory -Path $script:BackupDir -Force | Out-Null
    $paths = @($policyGroups | ForEach-Object { $_.Path }) + @($serviceModes.Keys | ForEach-Object { "$serviceRoot\$_" })
    $index = 0
    foreach ($path in @($paths | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $index++
        $nativePath = $path -replace '^Registry::', ''
        $outputFile = Join-Path $script:BackupDir "registry-$index.reg"
        $result = & reg.exe export $nativePath $outputFile /y 2>&1
        if ($LASTEXITCODE -ne 0) { throw "Backup failed for ${nativePath}: $result" }
        Add-Content -LiteralPath (Join-Path $script:BackupDir 'registry-index.txt') -Value "$outputFile : $nativePath"
    }
    if (Test-Path -LiteralPath $medicKey) {
        (Get-Acl -LiteralPath $medicKey).Sddl | Set-Content -LiteralPath (Join-Path $script:BackupDir 'WaaSMedicSvc-before.sddl')
    }
    foreach ($task in @(Get-ScheduledTask | Where-Object { $_.TaskName -in $guardNames -or ($_.TaskPath + $_.TaskName) -in $taskPaths })) {
        $safeName = ($task.TaskPath + $task.TaskName) -replace '[\\/:*?"<>|]', '_'
        Export-ScheduledTask -TaskName $task.TaskName -TaskPath $task.TaskPath |
            Set-Content -LiteralPath (Join-Path $script:BackupDir "$safeName.xml") -Encoding Unicode
    }
    foreach ($dir in @($guardDir,$olderGuardDir)) {
        foreach ($name in @('guardian.cmd', 'run.cmd')) {
            $path = Join-Path $dir $name
            if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $script:BackupDir ((Split-Path $dir -Leaf)+'-'+$name)) }
        }
    }
    Write-Log "Backup of pre-repair settings: $script:BackupDir"
}
function Stop-Guardian {
    Write-Log "`r`nStopping the repeating block BEFORE restoring settings..."
    foreach ($task in @(Get-GuardianTasks)) {
        try { Disable-ScheduledTask -InputObject $task | Out-Null } catch { Write-Log "Disable task: $($_.Exception.Message)" }
        try { Stop-ScheduledTask -InputObject $task } catch { Write-Log "Stop task: $($_.Exception.Message)" }
        Unregister-ScheduledTask -InputObject $task -Confirm:$false
        Write-Log "Removed task: $($task.TaskName)"
    }
    if (@(Get-GuardianTasks).Count -gt 0) { throw 'A guardian task still exists. Repair stopped before restoring settings.' }
    # Stop only cmd.exe processes invoking the known guardian paths; never all cmd.exe processes.
    foreach ($process in @(Get-GuardianProcesses)) {
        $result = & taskkill.exe /PID $process.ProcessId /T /F 2>&1
        if ($LASTEXITCODE -ne 0) {
            if (@(Get-GuardianProcesses | Where-Object { $_.ProcessId -eq $process.ProcessId }).Count -gt 0) {
                throw "Could not stop guardian process $($process.ProcessId): $result"
            }
        }
    }
    if (@(Get-GuardianProcesses).Count -gt 0) { throw 'Guardian is still running. Repair stopped.' }
    foreach ($dir in @($guardDir,$olderGuardDir)) {
        foreach ($name in @('run.cmd', 'guardian.cmd')) {
            $path = Join-Path $dir $name
            if (Test-Path -LiteralPath $path) {
                Rename-Item -LiteralPath $path -NewName "$name.disabled-$stamp-$PID"
                Write-Log "Disabled guardian file: $path"
            }
        }
    }
}
function Remove-BlockPolicies {
    $server = Read-Value $wu 'WUServer'
    $hasRealWsus = $null -ne $server -and "$server" -ne '' -and "$server" -ne 'http://127.0.0.1:8530'
    if ($hasRealWsus) { Add-Issue "An existing WSUS server is configured ($server). Its server selection is preserved; ask its administrator if downloads remain blocked." }
    foreach ($group in $policyGroups) {
        foreach ($name in $group.Values.Keys) {
            if ($hasRealWsus -and $name -eq 'UseWUServer') { continue }
            $value = Read-Value $group.Path $name
            if ($null -ne $value -and "$value" -eq "$($group.Values[$name])") {
                Remove-ItemProperty -LiteralPath $group.Path -Name $name
                Write-Log "Removed script setting: $($group.Path)\$name"
            }
        }
    }
    Write-Log 'Version pins and unrelated policy values were preserved.'
}
function Remove-MedicDeny {
    if (-not (Test-Path -LiteralPath $medicKey)) { return }
    $acl = Get-Acl -LiteralPath $medicKey
    $rights = [Security.AccessControl.RegistryRights]'SetValue,CreateSubKey,Delete'
    $flags = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
    $changed = $false
    foreach ($rule in @($acl.Access)) {
        $sid = $rule.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value
        if ($sid -eq 'S-1-5-18' -and -not $rule.IsInherited -and
            $rule.AccessControlType -eq 'Deny' -and $rule.RegistryRights -eq $rights -and
            $rule.InheritanceFlags -eq $flags -and $rule.PropagationFlags -eq 'None') {
            $acl.RemoveAccessRuleSpecific($rule)
            $changed = $true
        }
    }
    if ($changed) {
        Set-Acl -LiteralPath $medicKey -AclObject $acl
        Write-Log 'Removed the specific SYSTEM deny rule created by v3.0.'
    }
    Write-Log 'Other permissions and the current owner were preserved; v3.0 did not back up the original owner.'
}
function Repair-Service([string]$Name, [int]$StartValue) {
    $service = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $service) {
        if ($Name -ne 'wUpdate') { Add-Issue "Service $Name is missing; it was not recreated." }
        return
    }
    $key = "$serviceRoot\$Name"
    if ((Read-Value $key 'Start') -ne 4 -and $service.StartType -ne 'Disabled') { return }
    $mode = 'demand'
    if ($StartValue -eq 2) { $mode = 'auto' }
    $result = & sc.exe config $Name start= $mode 2>&1
    if ($LASTEXITCODE -ne 0) {
        # Protected services may reject SCM changes even for administrators.
        # Do not take ownership or replace their security descriptors.
        Write-Log "SCM could not configure ${Name}: $result"
        Set-ItemProperty -LiteralPath $key -Name Start -Value $StartValue
        $script:NeedsRestart = $true
        Write-Log "Updated existing service registry entry for $Name; reboot needed for SCM to reload it."
    } else { Write-Log "Enabled service ${Name}: $mode" }
    if ((Read-Value $key 'Start') -ne $StartValue) { throw "Service $Name startup did not change as expected." }
}
function Enable-OriginalTasks {
    foreach ($task in @(Get-ScheduledTask | Where-Object { ($_.TaskPath + $_.TaskName) -in $taskPaths })) {
        if ($task.State -eq 'Disabled') {
            try {
                Enable-ScheduledTask -InputObject $task | Out-Null
                Write-Log "Enabled task: $($task.TaskPath)$($task.TaskName)"
            } catch { Add-Issue "Could not enable task $($task.TaskPath)$($task.TaskName): $($_.Exception.Message)" }
        }
    }
}
function Test-RepairState {
    if (@(Get-GuardianTasks).Count -gt 0 -or @(Get-GuardianProcesses).Count -gt 0) { Add-Issue 'The guardian is still present or running.' }
    foreach ($task in @(Get-ScheduledTask | Where-Object { ($_.TaskPath + $_.TaskName) -in $taskPaths -and $_.State -eq 'Disabled' })) {
        Add-Issue "Task is still disabled: $($task.TaskPath)$($task.TaskName)"
    }
    foreach ($name in $serviceModes.Keys) {
        if ((Read-Value "$serviceRoot\$name" 'Start') -eq 4) { Add-Issue "Service $name is still disabled in the registry." }
    }
    foreach ($entry in @(
        @($wu, 'DoNotConnectToWindowsUpdateInternetLocations'), @($wu, 'DisableWindowsUpdateAccess'),
        @($wu, 'SetDisableUXWUAccess'), @($au, 'NoAutoUpdate')
    )) {
        if ($KeepAutomaticUpdatesDisabled -and $entry[1] -eq 'NoAutoUpdate') { continue }
        if ((Read-Value $entry[0] $entry[1]) -eq 1) { Add-Issue "A blocking policy remains: $($entry[1]). Group Policy, management software, or another blocker may be enforcing it." }
    }
    if ((Read-Value $wu 'WUServer') -eq 'http://127.0.0.1:8530') { Add-Issue 'The loopback update server is still configured.' }
    foreach ($name in @('wuauserv', 'BITS', 'InstallService')) {
        try {
            $svc = Get-Service -Name $name
            if ($svc.StartType -eq 'Disabled') { throw 'SCM still reports Disabled; restart and rerun this repair.' }
            if ($svc.Status -ne 'Running') {
                $result = & sc.exe start $name 2>&1
                if ($LASTEXITCODE -notin @(0, 1056)) { throw "Start failed: $result" }
                $svc.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(20))
            }
            Write-Log "Verified that $name can run."
        } catch { Add-Issue "Service ${name}: $($_.Exception.Message)" }
    }
}

$exitCode = 0
try {
    Write-Log 'Windows Update / Microsoft Store repair for WU-Manager v3.0'
    Write-Log "Report: $report"
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $DiagnoseOnly -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Right-click Repair-WindowsStore.cmd and choose Run as administrator.'
    }
    # Include loaded user hives, so elevation using another account does not miss the user's block.
    if (-not $DiagnoseOnly) {
        foreach ($sid in @([Microsoft.Win32.Registry]::Users.GetSubKeyNames() | Where-Object { $_ -match '^S-1-5-21-\d+-\d+-\d+-\d+$' })) {
            $policyGroups += @{ Path = "Registry::HKEY_USERS\$sid\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate"; Values = @{ DisableWindowsUpdateAccess = 1 } }
        }
    }
    Write-State 'Before'
    if ($DiagnoseOnly) {
        Write-Log 'Diagnostic only: no services, tasks, policies, or permissions changed.'
    } else {
        Save-Backup
        Stop-Guardian
        Remove-BlockPolicies
        if ($KeepAutomaticUpdatesDisabled) {
            if (-not (Test-Path -LiteralPath $au)) { New-Item -Path $au -Force | Out-Null }
            New-ItemProperty -LiteralPath $au -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null
            Write-Log 'Keeping automatic OS updates disabled by policy before enabling services.'
        }
        try { Remove-MedicDeny } catch { Add-Issue "WaaSMedic permission repair: $($_.Exception.Message)" }
        foreach ($name in $serviceModes.Keys) {
            try { Repair-Service $name $serviceModes[$name] } catch { Add-Issue "Service ${name}: $($_.Exception.Message)" }
        }
        Enable-OriginalTasks
        Test-RepairState
        Write-State 'After'
        Write-Log "`r`nRestart the PC, then run wsreset.exe from Win+R in the affected user account and retry installing ChatGPT."
        if ($KeepAutomaticUpdatesDisabled) { Write-Log 'Update services are enabled; automatic OS updates remain disabled by policy.' }
        else { Write-Log 'Windows Update is enabled again and may resume normal updates. Use Pause updates in Settings if needed.' }
        if ($script:Issues.Count -gt 0) {
            $exitCode = 2
            Write-Log "Repair is INCOMPLETE: $($script:Issues.Count) item(s) need attention. See ATTENTION lines above."
        } elseif ($script:NeedsRestart) {
            $exitCode = 3010
            Write-Log 'Settings repaired; a restart is required before the result can be confirmed.'
        } else {
            Write-Log 'Checked settings repaired. Confirm the app download after restarting; installation was not tested by this script.'
        }
    }
} catch {
    $exitCode = 1
    Write-Log "[FAILED] $($_.Exception.Message)"
} finally {
    Write-Log "`r`nReport saved to: $report"
    if (-not $DiagnoseOnly -and (Get-Variable BackupDir -Scope Script -ErrorAction SilentlyContinue)) {
        Copy-Item -LiteralPath $report -Destination (Join-Path $script:BackupDir 'repair-report.txt') -ErrorAction Continue
    }
}
exit $exitCode
