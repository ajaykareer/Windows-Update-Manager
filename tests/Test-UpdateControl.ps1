#Requires -Version 5.1
# No elevation, task registration, HKLM writes, or real service changes in these tests.
$ErrorActionPreference='Stop'
$source=Join-Path (Split-Path $PSScriptRoot -Parent) 'UpdateControl.ps1'
$tokens=$null; $parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
. $source
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
$script:Root=Join-Path $PSScriptRoot ('runs\'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
$script:StateFile=Join-Path $script:Root 'state.json'
$script:BaselineFile=Join-Path $script:Root 'active-baseline.json'
$script:InstalledEngine=Join-Path $script:Root 'UpdateControl.ps1'
$script:LogFile=$null
New-Item -ItemType Directory -Path (Join-Path $script:Root 'backups') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $script:Root 'logs') | Out-Null
function Write-Audit([string]$Message) { }
function Write-Step([string]$Message) { }

# Real filesystem lock and state gate, with enforcement itself replaced by a fail-fast mock.
& {
    function Set-HardBlock { throw 'Unexpected enforcement!' }
    Save-State 'Store' 'test'
    Assert ((Invoke-Enforcement) -eq 0) 'Guardian must do nothing in Store mode.'
    Save-State 'Normal' 'test'
    Assert ((Invoke-Enforcement) -eq 0) 'Guardian must do nothing after restore.'
    [IO.File]::WriteAllText($script:StateFile,'broken json')
    Assert ((Invoke-Enforcement) -eq 0) 'Corrupt state must not arm the guardian.'
    Save-State 'Hard' 'test'
    $lock=Enter-OperationLock
    try { Assert ((Invoke-Enforcement) -eq 0) 'Busy mode-change lock must prevent enforcement.' }
    finally { $lock.Dispose() }
    $script:Applied=0
    function Set-HardBlock { $script:Applied++ }
    Assert ((Invoke-Enforcement) -eq 0 -and $script:Applied -eq 1) 'Hard state must enforce exactly once.'
}
Write-Host 'PASS: state gating, corrupt-state fail-safe, and real cross-process file lock.'

# Match legacy tasks in every folder, continue after disable/stop errors, use CLI fallback.
& {
    $script:FakeTasks=@(
        [pscustomobject]@{TaskName='POS-WU-Guardian';TaskPath='\Moved\'}
        [pscustomobject]@{TaskName='POS-WU-Guardian_Startup';TaskPath='\'}
        [pscustomobject]@{TaskName='POS-WU-Guardian_Hourly';TaskPath='\Old\'}
        [pscustomobject]@{TaskName='POS-WU-Guardian-v4';TaskPath='\'}
        [pscustomobject]@{TaskName='WU-Guardian';TaskPath='\OldRepo\'}
        [pscustomobject]@{TaskName='WU-Guardian_Startup';TaskPath='\'}
        [pscustomobject]@{TaskName='Unrelated';TaskPath='\'}
    )
    $script:Deleted=New-Object 'System.Collections.Generic.List[string]'
    $script:NativeCalls=New-Object 'System.Collections.Generic.List[string]'
    function Get-ScheduledTask { $script:FakeTasks }
    function Disable-ScheduledTask { throw 'Simulated disable denied' }
    function Stop-ScheduledTask { throw 'Simulated task already stopped' }
    function Unregister-ScheduledTask {
        param($InputObject,$Confirm)
        if ($InputObject.TaskName -eq 'POS-WU-Guardian_Hourly') { throw 'Use fallback' }
        $script:Deleted.Add($InputObject.TaskPath+$InputObject.TaskName)
        $script:FakeTasks=@($script:FakeTasks | Where-Object { $_ -ne $InputObject })
    }
    function Invoke-Native($File,$Arguments) {
        $script:NativeCalls.Add($Arguments -join ' ')
        if ($Arguments[0] -eq '/Delete') {
            $name=$Arguments[2]
            $script:FakeTasks=@($script:FakeTasks | Where-Object { ($_.TaskPath+$_.TaskName) -ne $name })
        }
        [pscustomobject]@{Code=0;Text='mock'}
    }
    function Get-CimInstance { @() }
    function Test-Path { $false }
    Remove-Watchdogs
    Assert ($script:FakeTasks.Count -eq 1 -and $script:FakeTasks[0].TaskName -eq 'Unrelated') 'Known tasks must be gone; unrelated tasks must remain.'
    Assert ($script:Deleted -contains '\Moved\POS-WU-Guardian') 'Nested task was missed.'
    Assert ($script:Deleted -contains '\OldRepo\WU-Guardian' -and $script:Deleted -contains '\WU-Guardian_Startup') 'Original repository watchdogs were missed.'
    Assert (@($script:NativeCalls | Where-Object { $_ -eq '/Delete /TN \Old\POS-WU-Guardian_Hourly /F' }).Count -eq 1) 'Full-path CLI fallback was not attempted.'
    $script:FakeTasks=@([pscustomobject]@{TaskName='POS-WU-Guardian';TaskPath='\'})
    function Unregister-ScheduledTask { param($InputObject,$Confirm) throw 'Denied' }
    function Invoke-Native { [pscustomobject]@{Code=5;Text='Denied'} }
    $caught=$false
    try { Remove-Watchdogs } catch { $caught=$true }
    Assert $caught 'Persistent task deletion failure must not report success.'
}
Write-Host 'PASS: nested legacy cleanup, disable/stop failure tolerance, delete fallback, residual task failure.'

# Real native task-definition builders; registration and file-security changes are mocked.
& {
    function Copy-Item { }
    function Set-Acl { }
    function Register-ScheduledTask {
        param($TaskName,$TaskPath,$Action,$Trigger,$Settings,$Principal,$Description,[switch]$Force)
        $script:CapturedTask=[pscustomobject]@{TaskName=$TaskName;TaskPath=$TaskPath;Actions=@($Action);Triggers=@($Trigger);Settings=$Settings;Principal=$Principal;State='Ready'}
    }
    function Get-OurTasks { $script:CapturedTask }
    Register-Watchdog
    Assert ($script:CapturedTask.Triggers.Count -eq 2) 'Expected two triggers on ONE task.'
    Assert ($script:CapturedTask.Actions[0].Arguments -match '-Action Enforce') 'Wrong watchdog action.'
    Assert ($script:CapturedTask.Actions[0].Arguments -match '-WindowStyle Hidden') 'Watchdog must not flash a window.'
    Assert ($script:CapturedTask.Principal.UserId -in @('SYSTEM','S-1-5-18','NT AUTHORITY\SYSTEM')) 'Watchdog principal is wrong.'
    Assert (@($script:CapturedTask.Triggers | Where-Object { $_.Repetition -and $_.Repetition.Interval -eq 'PT1M' }).Count -eq 1) 'Missing one-minute repetition.'
}
Write-Host 'PASS: actual task definition has one task, startup + minute triggers, hidden SYSTEM action.'

# Exercise actual mode orchestration, atomic snapshots, rollback, and restore against fake OS settings.
& {
    $script:FakePolicy=[pscustomobject]@{Exists=$true;Value=0;Kind='DWord'}
    $script:FakeStarts=@{wuauserv=3;UsoSvc=2;BITS=2;DoSvc=2}
    $script:FakeDelayed=@{
        wuauserv=[pscustomobject]@{Exists=$false;Value=$null;Kind=$null}
        UsoSvc=[pscustomobject]@{Exists=$false;Value=$null;Kind=$null}
        BITS=[pscustomobject]@{Exists=$true;Value=1;Kind='DWord'}
        DoSvc=[pscustomobject]@{Exists=$true;Value=0;Kind='DWord'}
    }
    $script:FakeCount=0
    $script:Order=New-Object 'System.Collections.Generic.List[string]'
    $script:LegacyCalls=0
    function Test-Admin { $true }
    function Initialize-Storage { }
    function Test-LegacyBlock { $false }
    function Assert-StoreEdition { }
    function Assert-StoreReady { }
    function Start-StoreDependencies { }
    function Test-DisabledDependencies { $false }
    function Invoke-LegacyRepair { $script:LegacyCalls++; throw 'Legacy repair should not be called in a clean v4 lifecycle.' }
    function Remove-Watchdogs { $script:Order.Add('remove:'+(Read-State).Mode); $script:FakeCount=0 }
    function Get-OurTasks { if ($script:FakeCount) { [pscustomobject]@{TaskName='POS-WU-Guardian-v4';State='Ready';TaskPath='\'} } }
    function Get-Service($Name) { [pscustomobject]@{StartType=if($script:FakeStarts[$Name] -eq 4){'Disabled'}else{'Manual'};Status='Stopped'} }
    function Read-RegValue($Path,$Name) {
        if ($Path -eq $script:AuKey) { return $script:FakePolicy }
        $svc=Split-Path $Path -Leaf
        if ($Name -eq 'DelayedAutoStart') { return $script:FakeDelayed[$svc] }
        [pscustomobject]@{Exists=$true;Value=$script:FakeStarts[$svc];Kind='DWord'}
    }
    function Write-RegValue($Path,$Name,$Snapshot) {
        if ($Path -eq $script:AuKey) { $script:FakePolicy=$Snapshot; $script:Order.Add('policy:'+"$($Snapshot.Value)") }
        else { $script:FakeDelayed[(Split-Path $Path -Leaf)]=$Snapshot }
    }
    function Set-ServiceMode($Name,$Start) { $script:FakeStarts[$Name]=$Start; $script:Order.Add("service:$Name=$Start") }
    function Register-Watchdog { $script:FakeCount=1 }
    Save-State 'Normal' 'test'
    $result=Invoke-ModeChange 'Hard'
    Assert ($result -eq 0 -and (Read-State).Mode -eq 'Hard' -and $script:FakeCount -eq 1) 'Hard transition failed.'
    Assert (@($script:FakeStarts.Values | Where-Object { $_ -ne 4 }).Count -eq 0) 'Hard did not disable all configured services.'
    $id=(Read-Baseline).Id
    $script:Order.Clear()
    $result=Invoke-ModeChange 'Store'
    Assert ($result -eq 0 -and (Read-State).Mode -eq 'Store' -and $script:FakeCount -eq 0) 'Hard-to-Store transition failed.'
    Assert ($script:FakePolicy.Value -eq 1 -and $script:FakeStarts.BITS -eq 2 -and $script:FakeDelayed.BITS.Value -eq 1) 'Store mode did not preserve manual updates and original service settings.'
    Assert ((Read-Baseline).Id -eq $id) 'Mode switch overwrote the original backup.'
    Assert ($script:Order[0] -eq 'remove:Transition' -and $script:Order[1] -eq 'policy:1') 'Guardian must be disarmed first; manual policy must precede service restoration.'
    $result=Invoke-ModeChange 'Restore'
    Assert ($result -eq 0 -and (Read-State).Mode -eq 'Normal' -and $script:FakeCount -eq 0 -and $script:FakePolicy.Value -eq 0) 'Restore did not return original policy.'
    Assert (-not (Test-Path -LiteralPath $script:BaselineFile)) 'Active baseline must retire after successful restore.'
    $result=Invoke-ModeChange 'Restore'
    Assert ($result -eq 0 -and $script:LegacyCalls -eq 0 -and $script:FakePolicy.Value -eq 0) 'Repeated restore must preserve original configuration.'
    # Existing manual policy must remain after two restores too.
    $script:FakePolicy=[pscustomobject]@{Exists=$true;Value=1;Kind='DWord'}
    Invoke-ModeChange 'Store' | Out-Null
    Invoke-ModeChange 'Restore' | Out-Null
    Invoke-ModeChange 'Restore' | Out-Null
    Assert ($script:FakePolicy.Value -eq 1) 'Pre-existing manual update policy was deleted on repeated restore.'
    # Failed task creation must disarm and roll back, retaining recovery data.
    $script:FakePolicy=[pscustomobject]@{Exists=$false;Value=$null;Kind=$null}
    function Register-Watchdog { throw 'Simulated registration failure' }
    $caught=$false
    try { Invoke-ModeChange 'Hard' | Out-Null } catch { $caught=$true }
    Assert ($caught -and (Read-State).Mode -eq 'RecoveryRequired' -and $script:FakeCount -eq 0) 'Failed block left an armed watchdog or false success.'
    Assert ($script:FakeStarts.wuauserv -eq 3 -and -not $script:FakePolicy.Exists) 'Failed block did not roll back settings.'
    Assert (Test-Path -LiteralPath $script:BaselineFile) 'Recovery backup was lost.'
    Invoke-ModeChange 'Restore' | Out-Null
    Assert ((Read-State).Mode -eq 'Normal') 'Recovery restore failed.'
}
Write-Host 'PASS: full Hard -> Store -> Restore lifecycle, immutable baseline, repeat restore, absent policy, rollback and recovery.'
Write-Host 'All v4 checks passed. Only isolated files under tests/runs were written.'
