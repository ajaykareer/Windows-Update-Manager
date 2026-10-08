#Requires -Version 5.1
# Runs REAL Windows APIs against disposable test services, registry keys and tasks.
# Never run this against the production Windows Update configuration.
$ErrorActionPreference='Stop'
if($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted'){
    throw 'This integration test requires a disposable GitHub-hosted Windows runner.'
}
$identity=[Security.Principal.WindowsIdentity]::GetCurrent()
if(-not([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)){throw 'The disposable runner must be elevated.'}
$repo=Split-Path $PSScriptRoot -Parent
$id=[guid]::NewGuid().ToString('N').Substring(0,12)
$prefix="UC4Test$id"
$scratch=Join-Path $env:ProgramData $prefix
New-Item -ItemType Directory -Path $scratch | Out-Null
$serviceNames=@("${prefix}A","${prefix}B")
$taskName="${prefix}Guardian"
$registry="Registry::HKEY_LOCAL_MACHINE\SOFTWARE\$prefix"
$fixture=Join-Path $scratch 'Fixture.ps1'
$serviceCode=@'
using System.ServiceProcess;
public sealed class TestService : ServiceBase {
    public TestService(string name) { ServiceName = name; CanStop = true; }
    protected override void OnStart(string[] args) { }
    protected override void OnStop() { }
    public static void Main(string[] args) { ServiceBase.Run(new TestService(args[0])); }
}
'@
$serviceSource=Join-Path $scratch 'TestService.cs'
$serviceExe=Join-Path $scratch 'TestService.exe'
[IO.File]::WriteAllText($serviceSource,$serviceCode)
& "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:exe "/out:$serviceExe" /reference:System.ServiceProcess.dll $serviceSource
if($LASTEXITCODE -ne 0){throw 'Could not compile temporary service.'}
# Patch only a private fixture's configuration. Its scheduled copy retains these overrides.
# This prevents a SYSTEM task from ever falling back to the production names/paths.
$override=@'
$script:Root = '__SCRATCH__\data'
$script:StateFile = Join-Path $script:Root 'state.json'
$script:BaselineFile = Join-Path $script:Root 'active-baseline.json'
$script:InstalledEngine = Join-Path $script:Root 'UpdateControl.ps1'
$script:TaskName = '__TASK__'
$script:GuardianNames = @($script:TaskName)
$script:LegacyDir = '__SCRATCH__\legacy'
$script:OlderLegacyDir = '__SCRATCH__\older-legacy'
$script:WuKey = '__REG__'
$script:AuKey = '__REG__\AU'
$script:HardServices = @('__SERVICE_A__','__SERVICE_B__')
$script:StoreServices = $script:HardServices
$script:StoreStartServices = $script:HardServices
function Assert-StoreEdition { }
function Invoke-LegacyRepair { throw 'Legacy repair must never be reached in the isolated integration fixture.' }
'@
$override=$override.Replace('__SCRATCH__',$scratch).Replace('__TASK__',$taskName).Replace('__REG__',$registry).Replace('__SERVICE_A__',$serviceNames[0]).Replace('__SERVICE_B__',$serviceNames[1])
$source=Get-Content -LiteralPath (Join-Path $repo 'UpdateControl.ps1') -Raw
$marker="if (`$MyInvocation.InvocationName -eq '.') { return }"
if(-not $source.Contains($marker)){throw 'Fixture insertion marker missing; refusing to run.'}
[IO.File]::WriteAllText($fixture,$source.Replace($marker,$override+"`r`n"+$marker))
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
try {
    . $fixture
    foreach($name in $serviceNames){
        # New-Service passes the quoted executable path directly to the SCM API.
        New-Service -Name $name -BinaryPathName ('"{0}" {1}' -f $serviceExe,$name) -StartupType Manual | Out-Null
    }
    Set-Service -Name $serviceNames[0] -StartupType Automatic
    foreach($name in $serviceNames){Start-Service -Name $name}
    New-Item -Path $script:AuKey -Force | Out-Null
    New-ItemProperty -Path "$script:SvcRoot\$($serviceNames[0])" -Name DelayedAutoStart -PropertyType DWord -Value 1 -Force | Out-Null
    Assert ((Invoke-ModeChange 'Hard') -eq 0) 'Hard mode returned failure.'
    Assert ((Read-State).Mode -eq 'Hard') 'Hard state missing.'
    Assert (@(Get-OurTasks).Count -eq 1) 'Expected one real scheduled task.'
    foreach($name in $serviceNames){Assert ((Get-Service $name).Status -eq 'Stopped' -and (Read-RegValue "$script:SvcRoot\$name" 'Start').Value -eq 4) "Service not blocked: $name"}
    $baselineId=(Read-Baseline).Id
    # Deliberately drift one temporary service, then prove the SYSTEM guardian corrects it.
    Set-Service -Name $serviceNames[0] -StartupType Manual
    Start-Service -Name $serviceNames[0]
    Start-ScheduledTask -TaskName $taskName
    $deadline=(Get-Date).AddSeconds(45)
    do {
        Start-Sleep -Milliseconds 500
        $blocked=(Read-RegValue "$script:SvcRoot\$($serviceNames[0])" 'Start').Value -eq 4 -and (Get-Service $serviceNames[0]).Status -eq 'Stopped'
    }while(-not $blocked -and (Get-Date) -lt $deadline)
    Assert $blocked 'The real SYSTEM guardian did not reapply the block to the temporary service.'
    Write-Host 'PASS: real service block, protected engine installation, task registration and SYSTEM enforcement.'
    Assert ((Invoke-ModeChange 'Store') -eq 0) 'Store transition failed.'
    Assert (@(Get-OurTasks).Count -eq 0) 'Store mode left a task behind.'
    Assert ((Read-RegValue $script:AuKey 'NoAutoUpdate').Value -eq 1) 'Manual policy missing.'
    Assert ((Read-Baseline).Id -eq $baselineId) 'Mode switch replaced the baseline.'
    foreach($name in $serviceNames){Assert ((Get-Service $name).Status -eq 'Running') "Temporary dependency failed to start: $name"}
    Assert ((Invoke-ModeChange 'Restore') -eq 0) 'Restore failed.'
    Assert ((Read-RegValue "$script:SvcRoot\$($serviceNames[0])" 'Start').Value -eq 2) 'Automatic start was not restored.'
    Assert ((Read-RegValue "$script:SvcRoot\$($serviceNames[1])" 'Start').Value -eq 3) 'Manual start was not restored.'
    Assert ((Read-RegValue "$script:SvcRoot\$($serviceNames[0])" 'DelayedAutoStart').Value -eq 1) 'Delayed-start setting was not restored.'
    Assert (-not (Read-RegValue $script:AuKey 'NoAutoUpdate').Exists) 'Originally absent policy remains.'
    Assert (@(Get-OurTasks).Count -eq 0) 'Restore left a task behind.'
    Assert ((Invoke-ModeChange 'Restore') -eq 0) 'Repeated restore failed.'
    Write-Host 'PASS: real Hard -> Store -> Restore -> Restore, baseline preservation, exact policy restoration and zero leftover watchdogs.'
} finally {
    $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
    if($task){Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue;Unregister-ScheduledTask -InputObject $task -Confirm:$false}
    foreach($name in $serviceNames){
        Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
        & sc.exe delete $name | Out-Null
    }
    # Exact generated key only; never a production policy key.
    if($registry -notmatch '^Registry::HKEY_LOCAL_MACHINE\\SOFTWARE\\UC4Test[a-f0-9]{12}$'){throw 'Unsafe test cleanup key.'}
    if(Test-Path -LiteralPath $registry){Remove-Item -LiteralPath $registry -Recurse -Force}
    $logs=Join-Path $repo 'dist\integration-logs'
    New-Item -ItemType Directory -Path $logs -Force | Out-Null
    if(Test-Path -LiteralPath "$scratch\data\logs"){Copy-Item -Path "$scratch\data\logs\*.log" -Destination $logs -ErrorAction SilentlyContinue}
    # Scratch files stay on the disposable runner; no recursive filesystem cleanup.
}
