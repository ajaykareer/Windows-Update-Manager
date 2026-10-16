#Requires -Version 5.1
# All services, native calls, registry writes and time are mocked. No system changes.
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'UpdateControl.ps1')
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Audit([string]$Message) { }
function Write-Step([string]$Message) { }

& {
    $script:Clock=0
    $script:StopCalls=0
    $script:Scenario='slow'
    function Get-ServiceWaitMilliseconds { $script:Clock }
    function Start-Sleep { param($Milliseconds) $script:Clock += $Milliseconds }
    function Get-Service {
        $status=switch ($script:Scenario) {
            'slow' { if($script:Clock -ge 20000){'Stopped'}else{'StopPending'} }
            'starting' { if($script:Clock -lt 2000){'StartPending'}elseif($script:StopCalls -eq 0){'Running'}else{'Stopped'} }
            'race' { if($script:StopCalls -ge 2){'Stopped'}else{'Running'} }
            'already-stopped' { if($script:StopCalls){'Stopped'}else{'Running'} }
            'timeout' { 'StopPending' }
            'denied' { 'Running' }
        }
        [pscustomobject]@{Status=$status}
    }
    function Invoke-Native($File,$Arguments) {
        Assert ($File -eq 'sc.exe' -and $Arguments[0] -eq 'stop' -and $Arguments[1] -eq 'fixture') 'Unexpected native mutation.'
        $script:StopCalls++
        $code=switch($script:Scenario){'race'{if($script:StopCalls -eq 1){1061}else{0}} 'already-stopped'{1062} 'denied'{5} default{0}}
        [pscustomobject]@{Code=$code;Text="mock result $code"}
    }
    Stop-ControlledService 'fixture'
    Assert ($script:Clock -eq 20000 -and $script:StopCalls -eq 0) 'A slow pending stop was interrupted or failed at the old 15-second limit.'
    $script:Clock=0; $script:StopCalls=0; $script:Scenario='starting'
    Stop-ControlledService 'fixture'
    Assert ($script:Clock -ge 2000 -and $script:StopCalls -eq 1) 'StartPending was not allowed to finish before stopping.'
    $script:Clock=0; $script:StopCalls=0; $script:Scenario='race'
    Stop-ControlledService 'fixture'
    Assert ($script:Clock -ge 5000 -and $script:StopCalls -eq 2) '1061 race did not retry with backoff.'
    $script:Clock=0; $script:StopCalls=0; $script:Scenario='already-stopped'
    Stop-ControlledService 'fixture'
    Assert ($script:StopCalls -eq 1) '1062 was not confirmed by a fresh state read.'
    $script:Clock=0; $script:StopCalls=0; $script:Scenario='timeout'
    $caught=$false; try { Stop-ControlledService 'fixture' -TimeoutSeconds 120 } catch { $caught=$_.Exception.Message -match '120 seconds.*StopPending' }
    Assert ($caught -and $script:Clock -eq 120000 -and $script:StopCalls -eq 0) 'Stuck pending service did not fail within the deadline.'
    $script:Clock=0; $script:StopCalls=0; $script:Scenario='denied'
    $caught=$false; try { Stop-ControlledService 'fixture' } catch { $caught=$_.Exception.Message -match 'error 5' }
    Assert ($caught -and $script:StopCalls -eq 1 -and $script:Clock -eq 0) 'Access denial was retried or relabeled as a restart.'
}
Write-Host 'PASS: slow stops, pending start/stop, 1061 race/backoff, 1062 race, bounded timeout and real denial.'

& {
    $script:ServiceTargets=@{}
    $script:RestartServices=@()
    $script:Saved=@{fixture=3;other=3}
    $script:Live=@{fixture='Manual';other='Manual'}
    $script:Writes=0
    $script:NativeMode='partial-success'
    function Get-Service($Name) { [pscustomobject]@{StartType=$script:Live[$Name]} }
    function Read-RegValue($Path,$Name) { [pscustomobject]@{Exists=$true;Value=$script:Saved[(Split-Path $Path -Leaf)];Kind='DWord'} }
    function Set-ItemProperty($LiteralPath,$Name,$Value) {
        $script:Writes++
        if($script:NativeMode -eq 'write-denied'){throw 'fixture registry write denied'}
        if($script:NativeMode -ne 'write-lost'){$script:Saved[(Split-Path $LiteralPath -Leaf)]=$Value}
    }
    function Invoke-Native($File,$Arguments) {
        $name=$Arguments[1]
        if($script:NativeMode -eq 'partial-success'){$script:Saved[$name]=4;$script:Live[$name]='Disabled'}
        if($script:NativeMode -eq 'success-mismatch'){$script:Saved[$name]=4;return [pscustomobject]@{Code=0;Text='mock success'}}
        [pscustomobject]@{Code=5;Text='ChangeServiceConfig2 (delayed autostart flag) FAILED 5'}
    }
    Set-ServiceMode 'fixture' 4
    Assert (-not $script:RebootNeeded -and $script:Writes -eq 0) 'Optional flag failure caused a registry rewrite or false restart despite matching live settings.'
    $script:NativeMode='fallback'; $script:Saved.fixture=3; $script:Live.fixture='Manual'
    Set-ServiceMode 'fixture' 4
    Assert ($script:RebootNeeded -and $script:RestartServices -contains 'fixture' -and $script:Saved.fixture -eq 4) 'Actual saved/live mismatch did not request restart.'
    $script:Live.fixture='Disabled'
    Update-RestartRequirement
    Assert (-not $script:RebootNeeded) 'A resolved startup mismatch retained a stale restart flag.'
    # Restore can need a restart transiently, then Hard requests the already-live Disabled mode.
    Set-ServiceMode 'fixture' 3
    Assert $script:RebootNeeded 'Temporary restore mismatch not detected.'
    Set-ServiceMode 'fixture' 4
    Assert (-not $script:RebootNeeded) 'Restore -> Hard kept an obsolete restart request.'
    Set-ServiceMode 'other' 4
    Set-ServiceMode 'fixture' 4
    Assert ($script:RebootNeeded -and $script:RestartServices.Count -eq 1 -and $script:RestartServices[0] -eq 'other') 'One matching service incorrectly cleared another service mismatch.'
    $script:Live.other='Disabled'; Update-RestartRequirement
    $script:NativeMode='success-mismatch'; $script:Saved.fixture=3; $script:Live.fixture='Manual'
    Set-ServiceMode 'fixture' 4
    Assert $script:RebootNeeded 'Native success was accepted without checking live startup.'
    foreach($failure in @('write-denied','write-lost')) {
        $script:NativeMode=$failure; $script:Saved.fixture=3
        $caught=$false; try{Set-ServiceMode 'fixture' 4}catch{$caught=$true}
        Assert $caught 'A failed saved-setting change was accepted as restart-only.'
    }
    $script:ServiceTargets=@{}; $script:RestartServices=@(); $script:RebootNeeded=$false
}
Write-Host 'PASS: partial config warnings, actual live mismatches, cleared restart flags, multi-service tracking and failed writes.'
