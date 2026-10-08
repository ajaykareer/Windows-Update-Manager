#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('Status','Hard','Restore','Store','Report')][string]$JobAction,
    [Parameter(Mandatory=$true)][string]$ResultPath,
    [Parameter(Mandatory=$true)][string]$ProgressPath
)
$ErrorActionPreference='Stop'
$result=[ordered]@{Action=$JobAction; ExitCode=1; Error=$null; LogPath=$null; ReportPath=$null; Status=$null; StatusError=$null; Computer=$null}
try {
    . (Join-Path $PSScriptRoot 'UpdateControl.ps1') -Action $JobAction
    # Reuse the controller; replace only its presentation callback for this worker.
    function Write-Step([string]$Message) {
        Add-Content -LiteralPath $ProgressPath -Value ((Get-Date -Format 'HH:mm:ss')+'  '+$Message) -Encoding UTF8
        Write-Audit $Message
    }
    if ($JobAction -in @('Hard','Restore','Store')) {
        $result.ExitCode=Invoke-ModeChange $JobAction
        $result.LogPath=$script:LogFile
    } elseif ($JobAction -eq 'Report') {
        $result.ReportPath=Save-Report
        $result.ExitCode=0
    } else { $result.ExitCode=0 }
    try { $result.Status=Get-ControlStatus } catch { $result.StatusError=$_.Exception.Message }
    try {
        $os=Get-CimInstance Win32_OperatingSystem
        $edition=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').EditionID
        $result.Computer=[ordered]@{OS=$os.Caption; Build=$os.BuildNumber; Edition=$edition; IsAdmin=(Test-Admin)}
    } catch { $result.StatusError=('Device information unavailable: '+$_.Exception.Message) }
} catch {
    $result.ExitCode=1
    $result.Error=$_.Exception.Message
    if (Get-Variable LogFile -Scope Script -ErrorAction SilentlyContinue) { $result.LogPath=$script:LogFile }
    try { $result.Status=Get-ControlStatus } catch { $result.StatusError=$_.Exception.Message }
} finally {
    # The UI never reads a half-written result. Each job has a unique output path.
    $tempPath=$ResultPath+'.tmp'
    [IO.File]::WriteAllText($tempPath,($result | ConvertTo-Json -Depth 10),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($tempPath,$ResultPath)
}
exit ([int]$result.ExitCode)
