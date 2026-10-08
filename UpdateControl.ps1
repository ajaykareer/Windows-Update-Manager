#Requires -Version 5.1
<#
Update Control 4.2. CMD is the launcher; this file owns all changes.
Status, Report and Preview never change services, policy, or scheduled tasks.
#>
[CmdletBinding()]
param(
    [ValidateSet('Menu','Hard','Restore','Store','Status','Report','Enforce')]
    [string]$Action = 'Menu',
    [switch]$Preview,
    [switch]$AsJson
)
Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'
$script:Root = Join-Path $env:ProgramData 'POSUpdateControl'
$script:StateFile = Join-Path $script:Root 'state.json'
$script:BaselineFile = Join-Path $script:Root 'active-baseline.json'
$script:InstalledEngine = Join-Path $script:Root 'UpdateControl.ps1'
$script:TaskName = 'POS-WU-Guardian-v4'
$script:GuardianNames = @('POS-WU-Guardian','POS-WU-Guardian_Startup','POS-WU-Guardian_Hourly','WU-Guardian','WU-Guardian_Startup','WU-Guardian_Hourly',$script:TaskName)
$script:LegacyDir = Join-Path $env:ProgramData 'POS_WU_Guardian'
$script:OlderLegacyDir = Join-Path $env:ProgramData 'WU_Guardian'
$script:AuKey = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:WuKey = 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:SvcRoot = 'Registry::HKEY_LOCAL_MACHINE\SYSTEM\CurrentControlSet\Services'
$script:HardServices = @('wuauserv','UsoSvc','BITS','DoSvc')
$script:StoreServices = @('wuauserv','UsoSvc','BITS','DoSvc','InstallService','AppXSvc','ClipSVC')
$script:StoreStartServices = @('wuauserv','BITS','InstallService')
$script:RebootNeeded = $false
$script:LogFile = $null
$script:PSExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Write-Audit([string]$Message) {
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value ("{0} {1}" -f (Get-Date -Format o),$Message) -Encoding UTF8 }
}
function Write-Step([string]$Message) {
    Write-Host "  > $Message" -ForegroundColor Cyan
    Write-Audit $Message
}
function Invoke-Native([string]$File, [string[]]$Arguments) {
    $previous = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $File @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previous }
    return [pscustomobject]@{ Code=$code; Text=($output | Out-String).Trim() }
}
function Read-RegValue([string]$Path, [string]$Name) {
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Exists=$false; Value=$null; Kind=$null } }
    $key = Get-Item -LiteralPath $Path
    try {
        if ($Name -notin $key.GetValueNames()) { return [pscustomobject]@{ Exists=$false; Value=$null; Kind=$null } }
        return [pscustomobject]@{ Exists=$true; Value=$key.GetValue($Name); Kind=$key.GetValueKind($Name).ToString() }
    } finally { $key.Close() }
}
function Write-RegValue([string]$Path, [string]$Name, $Snapshot) {
    if ($Snapshot.Exists) {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Snapshot.Value -PropertyType $Snapshot.Kind -Force | Out-Null
    } elseif ((Read-RegValue $Path $Name).Exists) { Remove-ItemProperty -LiteralPath $Path -Name $Name }
}
function Set-ManualPolicy {
    Write-RegValue $script:AuKey 'NoAutoUpdate' ([pscustomobject]@{Exists=$true; Value=1; Kind='DWord'})
    if ((Read-RegValue $script:AuKey 'NoAutoUpdate').Value -ne 1) { throw 'Automatic-update policy did not stick.' }
}
function Write-AtomicJson([string]$Path, $Value) {
    $temp = "$Path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    [IO.File]::WriteAllText($temp, ($Value | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    try {
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[System.Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($temp,$Path) }
    } finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Read-State {
    if (-not (Test-Path -LiteralPath $script:StateFile)) { return [pscustomobject]@{Mode='Unmanaged'; Detail='No v4 configuration'; UpdatedUtc=$null} }
    try {
        $state = Get-Content -LiteralPath $script:StateFile -Raw | ConvertFrom-Json
        if ($state.Schema -ne 4 -or $state.Mode -notin @('Normal','Hard','Store','Transition','RecoveryRequired')) { throw 'Invalid state format' }
        return $state
    } catch { return [pscustomobject]@{Mode='RecoveryRequired'; Detail='State file unreadable. Use Restore.'; UpdatedUtc=$null} }
}
function Save-State([string]$Mode,[string]$Detail) {
    Write-AtomicJson $script:StateFile ([ordered]@{Schema=4; Mode=$Mode; Detail=$Detail; UpdatedUtc=[DateTime]::UtcNow.ToString('o')})
}
function Initialize-Storage {
    if (Test-Path -LiteralPath $script:Root) {
        if ((Get-Item -LiteralPath $script:Root).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'The data folder is a reparse point. Refusing to install a SYSTEM task there.' }
    } else { New-Item -ItemType Directory -Path $script:Root | Out-Null }
    # SYSTEM executes this copy. Standard users may read it but cannot replace it.
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true,$false)
    foreach ($entry in @(@('S-1-5-18','FullControl'),@('S-1-5-32-544','FullControl'),@('S-1-5-32-545','ReadAndExecute'))) {
        $sid = New-Object Security.Principal.SecurityIdentifier($entry[0])
        $rule = New-Object Security.AccessControl.FileSystemAccessRule($sid,$entry[1],'ContainerInherit,ObjectInherit','None','Allow')
        $acl.AddAccessRule($rule)
    }
    $acl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $script:Root -AclObject $acl
    foreach ($name in @('logs','backups')) {
        $path = Join-Path $script:Root $name
        if (Test-Path -LiteralPath $path) {
            if ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Unexpected reparse point: $path" }
        } else { New-Item -ItemType Directory -Path $path | Out-Null }
    }
    foreach ($path in @($script:StateFile,$script:BaselineFile,$script:InstalledEngine,(Join-Path $script:Root 'operation.lock'))) {
        if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw "Unexpected reparse point: $path" }
    }
    $script:LogFile = Join-Path $script:Root ("logs\{0}-{1}-{2}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss-fff'),$Action,$PID)
}
function Enter-OperationLock([int]$Seconds=30) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        try { return [IO.File]::Open((Join-Path $script:Root 'operation.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch [IO.IOException] { if ($Seconds -eq 0) { return $null }; Start-Sleep -Milliseconds 200 }
    } while ($timer.Elapsed.TotalSeconds -lt $Seconds)
    throw 'Another update-control operation is still running. Retry shortly.'
}
function Get-OurTasks {
    # Match every folder, including tasks moved out of the root by an older tool.
    Get-ScheduledTask | Where-Object { $_.TaskName -in $script:GuardianNames }
}
function Remove-Watchdogs {
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($task in @(Get-OurTasks)) {
        $fullName = $task.TaskPath + $task.TaskName
        Write-Audit "Remove watchdog: $fullName"
        # A failed disable must never prevent stop/delete attempts.
        try { Disable-ScheduledTask -InputObject $task | Out-Null } catch { Write-Audit "Disable: $($_.Exception.Message)" }
        try { Stop-ScheduledTask -InputObject $task } catch { Write-Audit "Stop: $($_.Exception.Message)" }
        try { Unregister-ScheduledTask -InputObject $task -Confirm:$false }
        catch {
            Write-Audit "Task API delete: $($_.Exception.Message)"
            $result = Invoke-Native 'schtasks.exe' @('/End','/TN',$fullName)
            Write-Audit $result.Text
            $result = Invoke-Native 'schtasks.exe' @('/Delete','/TN',$fullName,'/F')
            Write-Audit $result.Text
        }
    }
    # Retry enumeration/deletion to handle a task completing during the first pass.
    foreach ($task in @(Get-OurTasks)) {
        $result = Invoke-Native 'schtasks.exe' @('/Delete','/TN',($task.TaskPath+$task.TaskName),'/F')
        Write-Audit $result.Text
    }
    foreach ($task in @(Get-OurTasks)) { $failures.Add($task.TaskPath+$task.TaskName) }
    if ($failures.Count) { throw ('Watchdog removal failed: ' + ($failures -join ', ') + '. Restore is incomplete; no success has been recorded.') }
    # Old CMD guardians do not understand the v4 state file. Stop only their exact command paths.
    $paths = @((Join-Path $script:LegacyDir 'run.cmd'),(Join-Path $script:LegacyDir 'guardian.cmd'),(Join-Path $script:OlderLegacyDir 'run.cmd'),(Join-Path $script:OlderLegacyDir 'guardian.cmd'))
    foreach ($process in @(Get-CimInstance Win32_Process -Filter "Name='cmd.exe'")) {
        if (-not $process.CommandLine) { continue }
        $matched = $false
        foreach ($path in $paths) { if ($process.CommandLine.IndexOf($path,[StringComparison]::OrdinalIgnoreCase) -ge 0) { $matched=$true } }
        if ($matched) {
            $result=Invoke-Native 'taskkill.exe' @('/PID',"$($process.ProcessId)",'/T','/F')
            if ($result.Code -ne 0 -and (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) { throw "Could not stop legacy guardian process: $($result.Text)" }
        }
    }
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Rename-Item -LiteralPath $path -NewName ((Split-Path $path -Leaf)+'.disabled-'+[guid]::NewGuid().ToString('N'))
        }
    }
    Write-Audit 'Verified: all known watchdog names are absent from every task folder.'
}
function Test-LegacyBlock {
    if (@(Get-OurTasks | Where-Object { $_.TaskName -ne $script:TaskName }).Count) { return $true }
    foreach ($dir in @($script:LegacyDir,$script:OlderLegacyDir)) {
        foreach ($name in @('run.cmd','guardian.cmd')) { if (Test-Path -LiteralPath (Join-Path $dir $name)) { return $true } }
    }
    if ((Read-RegValue $script:WuKey 'WUServer').Value -eq 'http://127.0.0.1:8530') { return $true }
    if ((Read-RegValue $script:WuKey 'DisableWindowsUpdateAccess').Value -eq 1) { return $true }
    if ((Read-RegValue $script:AuKey 'NoAutoUpdate').Value -eq 1 -and (Read-RegValue $script:AuKey 'AUOptions').Value -eq 1) { return $true }
    return $false
}
function Test-DisabledDependencies {
    foreach ($name in $script:StoreServices) {
        $svc=Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and ($svc.StartType -eq 'Disabled' -or (Read-RegValue "$script:SvcRoot\$name" 'Start').Value -eq 4)) { return $true }
    }
    return $false
}
function Invoke-LegacyRepair([bool]$KeepManual) {
    $helper=Join-Path $PSScriptRoot 'Repair-WindowsStore.ps1'
    if (-not (Test-Path -LiteralPath $helper)) { throw 'The legacy repair helper is missing. Extract all files in the new ZIP.' }
    Write-Step 'Repairing the older blocker settings; details are saved in the log.'
    $arguments=@('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$helper)
    if ($KeepManual) { $arguments += '-KeepAutomaticUpdatesDisabled' }
    $result=Invoke-Native $script:PSExe $arguments
    Write-Audit $result.Text
    if ($result.Code -eq 3010) { $script:RebootNeeded=$true }
    elseif ($result.Code -ne 0) { throw "Legacy repair needs attention (exit $($result.Code)). Read the log, restart if requested, then select Restore again." }
}
function New-Baseline([bool]$Migrated) {
    $services=@()
    foreach ($name in $script:HardServices) {
        $svc=Get-Service -Name $name -ErrorAction Stop
        $start=Read-RegValue "$script:SvcRoot\$name" 'Start'
        if ($start.Value -eq 4 -or $svc.StartType -eq 'Disabled') { throw "$name is already disabled. Select Restore to repair the older block first." }
        $services += [pscustomobject]@{Name=$name; Start=$start; Delayed=Read-RegValue "$script:SvcRoot\$name" 'DelayedAutoStart'}
    }
    $policy=Read-RegValue $script:AuKey 'NoAutoUpdate'
    if ($Migrated) { $policy=[pscustomobject]@{Exists=$false; Value=$null; Kind=$null} }
    $baseline=[pscustomobject]@{Schema=4; Id=[guid]::NewGuid().ToString('N'); CreatedUtc=[DateTime]::UtcNow.ToString('o'); Policy=$policy; Services=$services}
    Write-AtomicJson (Join-Path $script:Root "backups\$($baseline.Id).json") $baseline
    Write-AtomicJson $script:BaselineFile $baseline
    Write-Audit "Saved original settings as baseline $($baseline.Id)."
    return $baseline
}
function Read-Baseline {
    if (-not (Test-Path -LiteralPath $script:BaselineFile)) { return $null }
    $baseline=Get-Content -LiteralPath $script:BaselineFile -Raw | ConvertFrom-Json
    if ($baseline.Schema -ne 4 -or @($baseline.Services).Count -ne $script:HardServices.Count) { throw 'Backup is damaged. Watchdogs have been disarmed; recover the archived baseline from backups.' }
    if (@($baseline.Services.Name | Select-Object -Unique).Count -ne $script:HardServices.Count) { throw 'Duplicate service entries in backup.' }
    foreach ($svc in $baseline.Services) {
        if ($svc.Name -notin $script:HardServices -or -not $svc.Start.Exists -or $svc.Start.Value -notin @(2,3)) { throw 'Unexpected service data in backup.' }
    }
    return $baseline
}
function Set-ServiceMode([string]$Name,[int]$Start) {
    $mode = @{2='auto';3='demand';4='disabled'}[$Start]
    if (-not $mode) { throw 'Invalid service start value.' }
    $svc=Get-Service -Name $Name
    $current=Read-RegValue "$script:SvcRoot\$Name" 'Start'
    $types=@{2='Automatic';3='Manual';4='Disabled'}
    if ($current.Value -eq $Start -and "$($svc.StartType)" -eq $types[$Start]) { return }
    $result=Invoke-Native 'sc.exe' @('config',$Name,'start=',$mode)
    Write-Audit "Configure $Name to ${mode}: $($result.Text)"
    if ($result.Code -ne 0) {
        Set-ItemProperty -LiteralPath "$script:SvcRoot\$Name" -Name Start -Value $Start
        $script:RebootNeeded=$true
        Write-Audit "$Name registry updated; SCM may need a restart to reload it."
    }
    if ((Read-RegValue "$script:SvcRoot\$Name" 'Start').Value -ne $Start) { throw "Startup verification failed: $Name" }
}
function Restore-Baseline($Baseline,[bool]$KeepManual) {
    # When moving to Store mode, set manual OS updates BEFORE enabling shared services.
    if ($KeepManual) { Set-ManualPolicy }
    foreach ($svc in $Baseline.Services) {
        Set-ServiceMode $svc.Name ([int]$svc.Start.Value)
        Write-RegValue "$script:SvcRoot\$($svc.Name)" 'DelayedAutoStart' $svc.Delayed
    }
    if (-not $KeepManual) { Write-RegValue $script:AuKey 'NoAutoUpdate' $Baseline.Policy }
}
function Set-HardBlock {
    Set-ManualPolicy
    foreach ($name in $script:HardServices) {
        Set-ServiceMode $name 4
        $svc=Get-Service -Name $name
        if ($svc.Status -ne 'Stopped') {
            $result=Invoke-Native 'sc.exe' @('stop',$name)
            if ($result.Code -notin @(0,1062)) { throw "Cannot stop ${name}: $($result.Text)" }
            $svc.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Stopped,[TimeSpan]::FromSeconds(15))
        }
    }
}
function Register-Watchdog {
    if ([IO.Path]::GetFullPath($PSCommandPath) -ne [IO.Path]::GetFullPath($script:InstalledEngine)) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $script:InstalledEngine -Force
    }
    # Remove explicit ACLs from a previous installed file; use the protected folder's inherited ACL.
    $fileAcl=New-Object Security.AccessControl.FileSecurity
    $fileAcl.SetAccessRuleProtection($false,$false)
    $fileAcl.SetOwner((New-Object Security.Principal.SecurityIdentifier('S-1-5-32-544')))
    Set-Acl -LiteralPath $script:InstalledEngine -AclObject $fileAcl
    $taskAction=New-ScheduledTaskAction -Execute $script:PSExe -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Action Enforce' -f $script:InstalledEngine)
    $triggers=@((New-ScheduledTaskTrigger -AtStartup),(New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)))
    $settings=New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 2)
    $principal=New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $script:TaskName -TaskPath '\' -Action $taskAction -Trigger $triggers -Settings $settings -Principal $principal -Description 'Update Control v4: enforce Hard mode only. Restore disarms state before removing this task.' -Force | Out-Null
    $tasks=@(Get-OurTasks)
    if ($tasks.Count -ne 1 -or $tasks[0].TaskName -ne $script:TaskName -or $tasks[0].State -eq 'Disabled' -or @($tasks[0].Triggers).Count -ne 2) { throw 'Watchdog registration could not be verified.' }
}
function Assert-StoreReady {
    foreach ($name in $script:StoreServices) {
        $svc=Get-Service -Name $name
        if ((Read-RegValue "$script:SvcRoot\$name" 'Start').Value -eq 4 -or $svc.StartType -eq 'Disabled') {
            if ($script:RebootNeeded) { continue }
            throw "$name remains disabled. Select Restore and check the repair log."
        }
    }
    foreach ($name in @('DoNotConnectToWindowsUpdateInternetLocations','DisableWindowsUpdateAccess','SetDisableUXWUAccess')) {
        if ((Read-RegValue $script:WuKey $name).Value -eq 1) { throw "Another policy still restricts Store/update access: $name" }
    }
    if ((Read-RegValue $script:AuKey 'UseWUServer').Value -eq 1) { throw 'An existing WSUS policy controls this PC. Resolve it before using Store Friendly mode.' }
}
function Start-StoreDependencies {
    foreach ($name in $script:StoreStartServices) {
        $svc=Get-Service -Name $name
        if ($script:RebootNeeded -and $svc.StartType -eq 'Disabled') { continue }
        if ($svc.Status -ne 'Running') {
            $result=Invoke-Native 'sc.exe' @('start',$name)
            Write-Audit "Start ${name}: $($result.Text)"
            if ($result.Code -notin @(0,1056)) { throw "Store dependency could not start: $name. $($result.Text)" }
            $svc.WaitForStatus([ServiceProcess.ServiceControllerStatus]::Running,[TimeSpan]::FromSeconds(15))
        }
    }
}
function Assert-StoreEdition {
    $edition=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
    if ($edition -notmatch '^(Professional|Enterprise|Education|IoTEnterprise)') { throw "Store Friendly policy mode is supported here only on Pro, Enterprise, Education and IoT Enterprise. Detected: $edition. Use Windows Settings > Pause updates on Home." }
    foreach ($name in @('SetComplianceDeadline','ConfigureDeadlineForQualityUpdates','ConfigureDeadlineForFeatureUpdates')) {
        if ((Read-RegValue $script:WuKey $name).Exists) { throw "An update deadline policy is configured ($name). It can override manual updates; resolve it with the PC administrator first." }
    }
}
function Assert-BaselineRestored($Baseline) {
    foreach ($svc in $Baseline.Services) {
        if ((Read-RegValue "$script:SvcRoot\$($svc.Name)" 'Start').Value -ne $svc.Start.Value) { throw "Restoration did not stick: $($svc.Name)" }
        $actual=Read-RegValue "$script:SvcRoot\$($svc.Name)" 'DelayedAutoStart'
        if ($actual.Exists -ne $svc.Delayed.Exists -or ($actual.Exists -and $actual.Value -ne $svc.Delayed.Value)) { throw "Delayed-start restore mismatch: $($svc.Name)" }
    }
    $actual=Read-RegValue $script:AuKey 'NoAutoUpdate'
    if ($actual.Exists -ne $Baseline.Policy.Exists -or ($actual.Exists -and ($actual.Value -ne $Baseline.Policy.Value -or $actual.Kind -ne $Baseline.Policy.Kind))) { throw 'Automatic-update policy did not restore to its original value.' }
    if (@(Get-OurTasks).Count) { throw 'A watchdog remains after restore.' }
}
function Invoke-ModeChange([string]$Mode) {
    if (-not (Test-Admin)) { throw 'Administrator access is required. Right-click the CMD and choose Run as administrator.' }
    if ($Mode -eq 'Store') { Assert-StoreEdition }
    Initialize-Storage
    $lock=Enter-OperationLock
    $script:RebootNeeded=$false
    $baseline=$null
    try {
        $previous=Read-State
        $legacy=Test-LegacyBlock
        Save-State 'Transition' 'Watchdog is disarmed while settings change.'
        Write-Step 'Disarming and removing watchdogs from every task folder...'
        Remove-Watchdogs
        $baseline=Read-Baseline
        if ($baseline) {
            Write-Step 'Restoring the saved service settings...'
            Restore-Baseline $baseline ($Mode -ne 'Restore')
        }
        $repairWithoutBaseline = $Mode -eq 'Restore' -and -not $baseline -and $previous.Mode -ne 'Normal' -and
            ($previous.Mode -ne 'Unmanaged' -or (Test-DisabledDependencies))
        if ($legacy -or $repairWithoutBaseline) {
            Invoke-LegacyRepair ($Mode -ne 'Restore')
        }
        if ($Mode -eq 'Restore') {
            if ($baseline) { Assert-BaselineRestored $baseline }
            if (@(Get-OurTasks).Count) { throw 'Watchdogs remain; restoration is incomplete.' }
            Save-State 'Normal' 'Tool changes removed; original settings restored where a v4 backup exists.'
            if (Test-Path -LiteralPath $script:BaselineFile) { Remove-Item -LiteralPath $script:BaselineFile }
            Write-Step 'Verified: zero watchdogs. This tool is no longer blocking updates.'
        } else {
            if (-not $baseline) { $baseline=New-Baseline $legacy }
            if ($Mode -eq 'Store') {
                Write-Step 'Setting manual Windows updates while keeping Store services available...'
                Set-ManualPolicy
                Assert-StoreReady
                Start-StoreDependencies
                Save-State 'Store' 'Automatic Windows updates disabled by policy; Store services remain available.'
                Write-Step 'Store Friendly configured. Zero watchdogs. Try the app download.'
            } else {
                Write-Step 'Disabling the shared update services...'
                Set-HardBlock
                Write-Step 'Installing one watchdog with startup and one-minute triggers...'
                Register-Watchdog
                Save-State 'Hard' 'Hard block selected. Store downloads require Store Friendly or Restore.'
                Write-Step 'Hard block configured; one watchdog verified.'
            }
        }
        if ($script:RebootNeeded) { Write-Host '  RESTART REQUIRED: some service changes need Windows to reload them.' -ForegroundColor Yellow; return 3010 }
        return 0
    } catch {
        $failure=$_.Exception.Message
        Write-Audit "FAILED: $failure"
        # Roll back a failed new block. Never leave an armed guardian after a failed transition.
        Save-State 'RecoveryRequired' $failure
        try { Remove-Watchdogs } catch { Write-Audit "Cleanup also failed: $($_.Exception.Message)" }
        if ($Mode -ne 'Restore' -and $baseline) {
            try { Restore-Baseline $baseline $false; Write-Audit 'Rolled back to baseline. Select Restore to finish verification.' }
            catch { Write-Audit "Rollback needs attention: $($_.Exception.Message)" }
        }
        throw "$failure`r`nLog: $script:LogFile"
    } finally { $lock.Dispose() }
}
function Invoke-Enforcement {
    # No state, corrupt state, non-Hard state, or a busy controller means no work.
    if (-not (Test-Path -LiteralPath $script:Root)) { return 0 }
    $lock=Enter-OperationLock 0
    if (-not $lock) { return 0 }
    try {
        if ((Read-State).Mode -ne 'Hard') { return 0 }
        $script:LogFile=Join-Path $script:Root 'logs\watchdog.log'
        if ((Test-Path -LiteralPath $script:LogFile) -and (Get-Item -LiteralPath $script:LogFile).Length -gt 2MB) {
            Move-Item -LiteralPath $script:LogFile -Destination (Join-Path $script:Root 'logs\watchdog.previous.log') -Force
        }
        Set-HardBlock
        return 0
    } catch { Write-Audit "Enforcement failed: $($_.Exception.Message)"; return 1 }
    finally { $lock.Dispose() }
}
function Get-ControlStatus {
    $state=Read-State
    $services=@()
    foreach ($name in $script:StoreServices) {
        $svc=Get-Service -Name $name -ErrorAction SilentlyContinue
        $services += [pscustomobject]@{Name=$name; State=if($svc){"$($svc.Status)"}else{'Missing'}; Startup=if($svc){"$($svc.StartType)"}else{'Missing'}; RegistryStart=(Read-RegValue "$script:SvcRoot\$name" 'Start').Value}
    }
    $tasks=@(Get-OurTasks | ForEach-Object { [pscustomobject]@{Name=$_.TaskPath+$_.TaskName; State="$($_.State)"} })
    $manual=(Read-RegValue $script:AuKey 'NoAutoUpdate').Value
    $warnings=New-Object 'System.Collections.Generic.List[string]'
    if ($state.Mode -eq 'Hard') {
        if ($tasks.Count -ne 1 -or $tasks[0].Name -ne "\$script:TaskName" -or $tasks[0].State -eq 'Disabled') { $warnings.Add('Expected one active v4 watchdog; task state differs.') }
        foreach ($svc in $services | Where-Object { $_.Name -in $script:HardServices }) {
            if ($svc.RegistryStart -ne 4 -or $svc.Startup -ne 'Disabled' -or $svc.State -ne 'Stopped') { $warnings.Add("Hard block not effective for $($svc.Name); restart or reapply.") }
        }
    } elseif ($state.Mode -eq 'Store') {
        if ($tasks.Count) { $warnings.Add('Watchdogs still exist.') }
        if ($manual -ne 1) { $warnings.Add('Automatic-update policy has changed.') }
        if (@($services | Where-Object { $_.Startup -in @('Disabled','Missing') -or $_.RegistryStart -eq 4 }).Count) { $warnings.Add('A Store dependency is disabled or missing.') }
    } elseif ($tasks.Count) { $warnings.Add('Watchdogs exist outside Hard mode; use Restore.') }
    if ($state.Mode -in @('RecoveryRequired','Transition')) { $warnings.Add('A previous operation is incomplete; select Restore.') }
    return [pscustomobject]@{Mode=$state.Mode; Detail=$state.Detail; NoAutoUpdate=$manual; Tasks=$tasks; Services=$services; Warnings=@($warnings.ToArray()); DataFolder=$script:Root}
}
function Show-Dashboard {
    $status=Get-ControlStatus
    if (-not $Preview) { Clear-Host }
    Write-Host ''
    Write-Host '  +--------------------------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host '  |  UPDATE CONTROL                                      WINDOWS / 4.2 |' -ForegroundColor Cyan
    Write-Host '  |  Choose when Windows updates. Keep control of app downloads.        |' -ForegroundColor Gray
    Write-Host '  +--------------------------------------------------------------------+' -ForegroundColor DarkCyan
    Write-Host ''
    $labels=@{Unmanaged='NOT CONFIGURED';Normal='RESTORED';Hard='HARD BLOCK';Store='STORE FRIENDLY';Transition='CHANGING MODE';RecoveryRequired='NEEDS ATTENTION'}
    $color=if($status.Warnings.Count){'Yellow'}elseif($status.Mode -eq 'Hard'){'Magenta'}else{'Green'}
    Write-Host ("  MODE  {0,-25} WATCHDOGS  {1}" -f $labels[$status.Mode],$status.Tasks.Count) -ForegroundColor $color
    if ($status.Warnings.Count) { foreach($warning in $status.Warnings){Write-Host "  ! $warning" -ForegroundColor Yellow} }
    Write-Host ''
    Write-Host '  [1]  HARD BLOCK' -ForegroundColor White
    Write-Host '       Stops shared update services. Store downloads will be blocked.' -ForegroundColor DarkGray
    Write-Host '  [2]  RESTORE / REMOVE BLOCKER' -ForegroundColor White
    Write-Host '       Removes watchdogs, restores settings, and verifies removal.' -ForegroundColor DarkGray
    Write-Host '  [3]  STORE FRIENDLY                                  RECOMMENDED' -ForegroundColor Cyan
    Write-Host '       Manual Windows updates. Install apps such as ChatGPT normally.' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  [4]  Save diagnostic report      [5]  Open logs and backups' -ForegroundColor Gray
    Write-Host '  [0]  Exit' -ForegroundColor Gray
    Write-Host ''
    Write-Host '  Store Friendly: Pro / Enterprise / Education / IoT Enterprise.' -ForegroundColor DarkGray
    Write-Host '  Manual or already-pending OS updates are not cancelled by that mode.' -ForegroundColor DarkGray
    Write-Host '  ----------------------------------------------------------------------' -ForegroundColor DarkCyan
}
function Save-Report {
    $path=Join-Path $env:TEMP ("Update-Control-report-{0}.txt" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    $status=Get-ControlStatus
    $os=Get-CimInstance Win32_OperatingSystem
    @("UPDATE CONTROL 4.2 DIAGNOSTIC", "OS: $($os.Caption) / $($os.BuildNumber)", ($status | ConvertTo-Json -Depth 6)) | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host "  Report: $path" -ForegroundColor Cyan
    return $path
}

if ($MyInvocation.InvocationName -eq '.') { return }
try {
    if ($Action -eq 'Enforce') { exit (Invoke-Enforcement) }
    if ($Action -eq 'Status') {
        $status=Get-ControlStatus
        if ($AsJson) { $status | ConvertTo-Json -Depth 6 } else { $status | Format-List }
        exit 0
    }
    if ($Action -eq 'Report') { Save-Report | Out-Null; exit 0 }
    if ($Action -eq 'Menu') {
        if ($Preview) { Show-Dashboard; exit 0 }
        if (-not (Test-Admin)) {
            # This is the interactive window the user launched, so elevation is visible.
            $arguments='-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Action Menu' -f $PSCommandPath
            Start-Process -FilePath $script:PSExe -ArgumentList $arguments -Verb RunAs | Out-Null
            exit 0
        }
        $Host.UI.RawUI.WindowTitle='Update Control 4.2'
        while ($true) {
            Show-Dashboard
            $choice=Read-Host '  Choose 1-5 or 0'
            if ($choice -eq '0') { break }
            try {
                if ($choice -in @('1','2','3')) {
                    $mode=@{'1'='Hard';'2'='Restore';'3'='Store'}[$choice]
                    if ($mode -eq 'Hard') {
                        Write-Host '  Hard Block also prevents Store downloads and automatic OS security updates.' -ForegroundColor Yellow
                        if ((Read-Host '  Type BLOCK to apply') -cne 'BLOCK') { continue }
                    }
                    $code=Invoke-ModeChange $mode
                    Write-Host "  Result code: $code    Log: $script:LogFile" -ForegroundColor Gray
                    if ($mode -eq 'Store') { Write-Host '  Reopen Store and install your app. If its old error remains, use Win+R > wsreset.exe.' -ForegroundColor Cyan }
                } elseif ($choice -eq '4') { Save-Report | Out-Null }
                elseif ($choice -eq '5') {
                    if (Test-Path -LiteralPath $script:Root) { Start-Process explorer.exe -ArgumentList ('"{0}"' -f $script:Root) | Out-Null }
                    else { Write-Host '  No logs yet. Choose a mode first.' }
                } else { continue }
            } catch { Write-Host "  INCOMPLETE: $($_.Exception.Message)" -ForegroundColor Red }
            Read-Host '  Press Enter to return' | Out-Null
        }
        exit 0
    }
    exit (Invoke-ModeChange $Action)
} catch { Write-Host "  FAILED: $($_.Exception.Message)" -ForegroundColor Red; exit 1 }
