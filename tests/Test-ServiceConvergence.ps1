#Requires -Version 5.1
# Reproduces recorded Windows 10 startup resets. All Windows mutations and time are mocked.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'UpdateControl.ps1')
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Audit([string]$Message) { }
function Write-Step([string]$Message) { }

& {
    $script:Scenario='stop-resets'
    function Reset-Fixture {
        $script:Clock=0
        $script:ServiceTargets=@{}
        $script:RestartServices=@()
        $script:RebootNeeded=$false
        $script:Saved=@{wuauserv=3;UsoSvc=2;BITS=2;DoSvc=2}
        $script:Live=@{wuauserv='Manual';UsoSvc='Automatic';BITS='Automatic';DoSvc='Automatic'}
        $script:States=@{wuauserv='Running';UsoSvc='Running';BITS='Running';DoSvc='Running'}
        $script:StopCalls=0
        $script:ConfigCalls=0
        $script:PolicyCalls=0
        $script:QuietChecks=0
        $script:Readbacks=0
    }
    function Get-ServiceWaitMilliseconds { $script:Clock }
    function Start-Sleep {
        param($Milliseconds)
        $script:Clock += $Milliseconds
        if ($Milliseconds -eq 2000) {
            $script:QuietChecks++
            if ($script:Scenario -eq 'late-reset' -and $script:QuietChecks -eq 1 -or $script:Scenario -eq 'persistent-reset') {
                $script:Saved.wuauserv=3; $script:Live.wuauserv='Manual'; $script:States.wuauserv='Running'
            }
            if ($script:Scenario -eq 'policy-reset') { $script:PolicyCalls=0 }
        }
    }
    function Set-ManualPolicy { $script:PolicyCalls++ }
    function Read-RegValue($Path,$Name) {
        if ($Name -eq 'NoAutoUpdate') { return [pscustomobject]@{Exists=$true;Value=[int]($script:PolicyCalls -gt 0);Kind='DWord'} }
        [pscustomobject]@{Exists=$true;Value=$script:Saved[(Split-Path $Path -Leaf)];Kind='DWord'}
    }
    function Get-Service($Name) { [pscustomobject]@{StartType=$script:Live[$Name];Status=$script:States[$Name]} }
    function Set-ItemProperty { throw 'Unexpected registry fallback.' }
    function Invoke-Native($File,$Arguments) {
        Assert ($File -eq 'sc.exe' -and $Arguments[0] -eq 'config') 'Unexpected native operation.'
        $script:ConfigCalls++
        if ($script:Scenario -eq 'denied') { throw 'fixture configuration denied' }
        $name=$Arguments[1]
        $script:Saved[$name]=4
        if ($script:Scenario -ne 'restart-needed') { $script:Live[$name]='Disabled' }
        [pscustomobject]@{Code=0;Text='fixture configured'}
    }
    function Stop-ControlledService {
        param($Name,$TimeoutSeconds)
        Assert ($TimeoutSeconds -ge 1 -and $TimeoutSeconds -le 120) 'Invalid bounded stop deadline.'
        Assert (@($script:Saved.Values | Where-Object { $_ -ne 4 }).Count -eq 0 -or $script:StopCalls -gt 0) 'Stopping began before the group was disabled.'
        $script:StopCalls++
        $script:States[$Name]='Stopped'
        if ($script:Scenario -eq 'stop-resets') {
            # Exact observed failure: stopping UsoSvc resets the earlier wuauserv;
            # later BITS changes its own startup mode during its stop.
            if ($Name -eq 'UsoSvc') { $script:Saved.wuauserv=3; $script:Live.wuauserv='Manual' }
            if ($Name -eq 'BITS') { $script:Saved.BITS=2; $script:Live.BITS='Automatic' }
        }
        if ($script:Scenario -eq 'budget') { $script:Clock += 120000 }
    }
    Reset-Fixture
    Set-HardBlock
    Assert ($script:QuietChecks -eq 1 -and $script:Saved.wuauserv -eq 4 -and $script:Saved.BITS -eq 4) 'Stop-time resets aborted the group or escaped correction.'
    Assert (-not $script:RebootNeeded) 'A transient startup reset produced a false restart request.'
    Write-Host 'PASS: earlier-service and BITS stop-time resets converge before whole-group verification.'

    $script:Scenario='late-reset'; Reset-Fixture
    Set-HardBlock
    Assert ($script:QuietChecks -eq 2 -and $script:Saved.wuauserv -eq 4 -and $script:States.wuauserv -eq 'Stopped') 'A late restart was not retried and verified.'
    $script:Scenario='persistent-reset'; Reset-Fixture
    $caught=$false;try { Set-HardBlock } catch { $caught=$_.Exception.Message -match 'after three passes.*incomplete' }
    Assert ($caught -and $script:QuietChecks -eq 3 -and $script:StopCalls -eq 12) 'Persistent interference was accepted or retried without a bound.'
    Write-Host 'PASS: late reset recovers, persistent interference fails explicitly after three passes.'

    $script:Scenario='denied'; Reset-Fixture
    $caught=$false;try { Set-HardBlock } catch { $caught=$_.Exception.Message -match 'configuration denied' }
    Assert ($caught -and $script:ConfigCalls -eq 1 -and $script:QuietChecks -eq 0) 'Configuration denial was hidden or retried as transient drift.'
    $script:Scenario='restart-needed'; Reset-Fixture
    Set-HardBlock
    Assert ($script:RebootNeeded -and $script:RestartServices.Count -eq 4 -and $script:QuietChecks -eq 1) 'Saved/live differences lost their restart-required result.'
    Write-Host 'PASS: real denial remains an error; saved/live differences remain restart-required.'

    $script:Scenario='policy-reset'; Reset-Fixture
    $caught=$false;try { Set-HardBlock } catch { $caught=$_.Exception.Message -match 'after three passes' }
    Assert $caught 'Policy interference was reported as verified.'
    $script:Scenario='budget'; Reset-Fixture
    # Force a later pass while time-consuming stops exhaust the single operation budget.
    function Assert-HardBlock { throw 'fixture requires another pass' }
    $caught=$false;try { Set-HardBlock } catch { $caught=$_.Exception.Message -match 'within ten minutes' }
    Assert ($caught -and $script:StopCalls -le 5) 'Slow repeated stops exceeded the shared ten-minute budget.'
    Write-Host 'PASS: policy drift fails verification and retries share one total stop budget.'
}

# Reapplying Hard must never temporarily enable the saved service settings.
& {
    $script:Root=Join-Path $PSScriptRoot ('runs\convergence-'+[guid]::NewGuid().ToString('N'))
    $script:InstalledEngine=Join-Path $script:Root 'engine.ps1'
    New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    function Test-Admin { $true }
    function Initialize-Storage { }
    function Enter-OperationLock { [IO.MemoryStream]::new() }
    function Read-State { [pscustomobject]@{Mode='Hard'} }
    function Test-LegacyBlock { $false }
    function Save-State { }
    function Remove-Watchdogs { }
    function Remove-WatchdogFiles { }
    function Read-Baseline { [pscustomobject]@{Id='existing-baseline'} }
    function Restore-Baseline { throw 'Hard reapply temporarily restored enabled startup settings.' }
    function Set-HardBlock { }
    function Register-Watchdog { [IO.File]::WriteAllText($script:InstalledEngine,'fixture') }
    function Update-RestartRequirement { }
    function Assert-HardBlock { }
    function Verify-WatchdogExecution { }
    function Assert-WatchdogDefinition { }
    Assert ((Invoke-ModeChange 'Hard') -eq 0) 'Reapplying Hard did not complete.'
    Write-Host 'PASS: Hard reapply preserves the baseline without temporarily unblocking services.'
}
