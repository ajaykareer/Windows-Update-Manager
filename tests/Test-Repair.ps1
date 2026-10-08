#Requires -Version 5.1
# Uses function-only AST loading and mocks. Never runs the repair entry point.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$source = Join-Path (Split-Path $PSScriptRoot -Parent) 'Repair-WindowsStore.ps1'
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$definitions = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)
foreach ($definition in $definitions) { . ([scriptblock]::Create($definition.Extent.Text)) }
function Assert($Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Write-Log([string]$Message) { }
function Add-Issue([string]$Message) { $script:TestIssues.Add($Message) }
$script:TestIssues = New-Object 'System.Collections.Generic.List[string]'
$wu = 'WU'
$au = 'WU\AU'
$serviceRoot = 'Services'

& {
    $policyGroups = @(
        @{Path=$wu; Values=@{WUServer='http://127.0.0.1:8530'; DisableWindowsUpdateAccess=1}}
        @{Path=$au; Values=@{UseWUServer=1; NoAutoUpdate=1; ScheduledInstallTime=3}}
    )
    $db = @{'WU|WUServer'='http://127.0.0.1:8530'; 'WU|DisableWindowsUpdateAccess'=1; 'WU\AU|UseWUServer'=1; 'WU\AU|NoAutoUpdate'=1; 'WU\AU|ScheduledInstallTime'=9; 'WU|TargetReleaseVersion'=1; 'WU|Unrelated'=123}
    function Read-Value($Path,$Name) { $db["$Path|$Name"] }
    function Remove-ItemProperty($LiteralPath,$Name) { $db.Remove("$LiteralPath|$Name") }
    Remove-BlockPolicies
    Assert ($db.Count -eq 3) 'Matching block values were not removed, or unrelated values were removed.'
    Assert ($db['WU\AU|ScheduledInstallTime'] -eq 9 -and $db['WU|Unrelated'] -eq 123 -and $db['WU|TargetReleaseVersion'] -eq 1) 'Policy preservation failed.'
    Remove-BlockPolicies
    Assert ($db.Count -eq 3) 'Second repair was not idempotent.'
    $db['WU|WUServer']='https://real-wsus.example'
    $db['WU\AU|UseWUServer']=1
    Remove-BlockPolicies
    Assert ($db['WU|WUServer'] -eq 'https://real-wsus.example' -and $db['WU\AU|UseWUServer'] -eq 1) 'Real WSUS selection was changed.'
    Assert ($script:TestIssues.Count -eq 1) 'Real WSUS warning was not reported.'
}
Write-Host 'PASS: matching policies removed, unrelated/custom settings and real WSUS preserved, rerun safe.'

& {
    $script:StartValue = 4
    $script:ScCalls = 0
    function Get-Service { [pscustomobject]@{StartType='Disabled'} }
    function Read-Value { $script:StartValue }
    function sc.exe { $script:ScCalls++; $script:StartValue=3; $global:LASTEXITCODE=0 }
    Repair-Service 'wuauserv' 3
    Assert ($script:StartValue -eq 3 -and $script:ScCalls -eq 1) 'Disabled service was not enabled.'
    function Get-Service { [pscustomobject]@{StartType='Automatic'} }
    $script:StartValue=2
    Repair-Service 'wuauserv' 3
    Assert ($script:StartValue -eq 2 -and $script:ScCalls -eq 1) 'Existing enabled startup mode was changed.'
    function Get-Service { $null }
    Repair-Service 'wUpdate' 3
    Assert ($script:ScCalls -eq 1) 'A missing wUpdate service was configured.'
}
Write-Host 'PASS: disabled services enabled; enabled configurations and missing optional service left alone.'

& {
    $script:NeedsRestart=$false
    $script:StartValue=4
    function Get-Service { [pscustomobject]@{StartType='Disabled'} }
    function Read-Value { $script:StartValue }
    function sc.exe { $global:LASTEXITCODE=5; 'Access denied' }
    function Set-ItemProperty($LiteralPath,$Name,$Value) { $script:StartValue=$Value }
    Repair-Service 'WaaSMedicSvc' 3
    Assert ($script:NeedsRestart -and $script:StartValue -eq 3) 'Registry fallback did not require restart.'
    $script:StartValue=4
    function Set-ItemProperty { throw 'Access denied' }
    $caught=$false
    try { Repair-Service 'WaaSMedicSvc' 3 } catch { $caught=$true }
    Assert $caught 'Failed service repair was silently accepted.'
}
Write-Host 'PASS: protected service fallback requires restart; denied repair surfaces an error.'

& {
    $guardDir='C:\ProgramData\POS_WU_Guardian'
    $olderGuardDir='C:\ProgramData\WU_Guardian'
    $stamp='test'
    $script:TaskPresent=$true
    $script:Steps=New-Object 'System.Collections.Generic.List[string]'
    function Get-GuardianTasks { if ($script:TaskPresent) { [pscustomobject]@{TaskName='POS-WU-Guardian'} } }
    function Disable-ScheduledTask { $script:Steps.Add('disable') }
    function Stop-ScheduledTask { $script:Steps.Add('stop') }
    function Unregister-ScheduledTask { param($InputObject,$Confirm) $script:Steps.Add('unregister'); $script:TaskPresent=$false }
    function Get-GuardianProcesses { }
    function Test-Path { $true }
    function Rename-Item { $script:Steps.Add('rename') }
    Stop-Guardian
    Assert (($script:Steps -join ',') -eq 'disable,stop,unregister,rename,rename,rename,rename') 'Guardian teardown order is wrong.'
    $script:TaskPresent=$true
    $script:Steps.Clear()
    function Unregister-ScheduledTask { param($InputObject,$Confirm) throw 'Access denied' }
    $caught=$false
    try { Stop-Guardian } catch { $caught=$true }
    Assert ($caught -and -not ($script:Steps -contains 'rename')) 'Guardian failure did not stop repair.'
}
Write-Host 'PASS: guardian disabled and stopped before removal; teardown failure stops repair.'

& {
    $medicKey='FakeMedicKey'
    $script:Acl = New-Object Security.AccessControl.RegistrySecurity
    $systemSid=New-Object Security.Principal.SecurityIdentifier('S-1-5-18')
    $usersSid=New-Object Security.Principal.SecurityIdentifier('S-1-5-32-545')
    $original=New-Object Security.AccessControl.RegistryAccessRule($systemSid,'SetValue,CreateSubKey,Delete','ContainerInherit,ObjectInherit','None','Deny')
    $unrelated=New-Object Security.AccessControl.RegistryAccessRule($usersSid,'SetValue','None','None','Deny')
    $allow=New-Object Security.AccessControl.RegistryAccessRule($systemSid,'FullControl','ContainerInherit','None','Allow')
    $script:Acl.AddAccessRule($original)
    $script:Acl.AddAccessRule($unrelated)
    $script:Acl.AddAccessRule($allow)
    function Test-Path { $true }
    function Get-Acl { $script:Acl }
    function Set-Acl { param($LiteralPath,$AclObject) $script:Acl=$AclObject }
    Remove-MedicDeny
    Assert (@($script:Acl.Access).Count -eq 2) 'ACL repair removed unrelated rules or kept the original rule.'
    Assert (@($script:Acl.Access | Where-Object { $_.AccessControlType -eq 'Deny' }).Count -eq 1) 'Unrelated deny rule was removed.'
}
Write-Host 'PASS: only the exact original SYSTEM deny rule is removed.'

$body=$ast.Extent.Text -replace "`r`n", "`n"
Assert ($body.IndexOf("        Save-Backup`n") -lt $body.IndexOf("        Stop-Guardian`n")) 'Backup must precede changes.'
Assert ($body.IndexOf("        Stop-Guardian`n") -lt $body.IndexOf("        Remove-BlockPolicies`n")) 'Guardian must be removed before policy repair.'
Assert ($body -notmatch '(?m)^\s*Remove-Item\s') 'Unexpected recursive/key deletion appeared.'
Write-Host 'PASS: backup and guardian teardown precede configuration repair.'
Write-Host 'All isolated repair checks passed. No live system settings were changed.'
# Failure-path mocks intentionally set LASTEXITCODE. Do not leak that simulated
# native failure into GitHub Actions' outer PowerShell wrapper after assertions pass.
exit 0
