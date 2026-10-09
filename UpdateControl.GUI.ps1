#Requires -Version 5.1
[CmdletBinding()]
param(
    [switch]$ReadOnly,
    [string]$PreviewPath,
    [ValidateSet('Unmanaged','Store','Hard','Normal','RecoveryRequired','Busy')][string]$PreviewMode='Store',
    [ValidateSet('Overview','Details','Activity')][string]$PreviewPage='Overview',
    [ValidateSet('None','Store','Hard','Restore')][string]$PreviewSelection='None',
    [int]$PreviewWidth=1160,
    [int]$PreviewHeight=810,
    [switch]$SmokeTest
)
Set-StrictMode -Version 2.0
$ErrorActionPreference='Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$script:GuiFile=$PSCommandPath
$script:GuiFolder=$PSScriptRoot
$script:GuiPS=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$script:IsAdmin=$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:ViewOnly=[bool]$ReadOnly
$script:StartupNotice=$null
if (-not $script:IsAdmin -and -not $ReadOnly -and -not $PreviewPath -and -not $SmokeTest) {
    try {
        $arguments='-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $PSCommandPath
        Start-Process -FilePath $script:GuiPS -ArgumentList $arguments -Verb RunAs -WindowStyle Hidden | Out-Null
        exit 0
    } catch {
        $script:ViewOnly=$true
        $script:StartupNotice='Opened read-only because administrator access was not granted. Close and reopen the app to enable changes.'
    }
}
if (-not $script:IsAdmin) { $script:ViewOnly=$true }
$script:ActiveJob=$null
$script:LastStatus=$null
$script:LastChecked=[DateTime]::MinValue
$script:Activity=New-Object 'System.Collections.Generic.List[string]'
$script:SessionFolder=$null
$script:LastProgress=''
$script:LastLog=$null
$script:LastWorkerResult=$null
$script:Page='Overview'
$script:StoreSupported=$true
$script:SelectedMode=$null
$script:Ui=@{}

function Add-Activity([string]$Message) {
    $script:Activity.Add((Get-Date -Format 'HH:mm:ss')+'  '+$Message)
    if ($script:Activity.Count -gt 300) { $script:Activity.RemoveAt(0) }
    $script:Ui.ActivityText.Text=$script:Activity -join "`r`n"
    $script:Ui.ActivityText.ScrollToEnd()
}
function Show-Notice([string]$Message) {
    $script:Ui.NoticeText.Text=$Message
    $script:Ui.NoticePanel.Visibility=if($Message){'Visible'}else{'Collapsed'}
}
function Set-UiAvailability {
    $idle=$null -eq $script:ActiveJob
    $selectable=$idle -or $script:ActiveJob.Action -eq 'Status'
    foreach($name in @('StoreChoice','HardChoice','RestoreChoice')){$script:Ui[$name].IsEnabled=$selectable}
    $reason=if($script:ViewOnly){'Read-only access. Reopen as administrator to apply changes.'}
        elseif(-not $idle){'An operation is running. Your selection is kept; wait for it to finish.'}
        elseif($null -eq $script:LastStatus){'Waiting for PC status. Use Refresh status if this does not finish.'}
        elseif(-not $script:SelectedMode){'Select a card above to continue. Windows stays unchanged until you apply.'}
        elseif($script:SelectedMode -eq 'Store' -and -not $script:StoreSupported){'Store Friendly is unavailable on this Windows edition. Use Windows Settings > Pause updates.'}
        else{$null}
    $labels=@{Store='Store Friendly';Hard='Hard Block';Restore='Restore Windows'}
    $buttons=@{Store='Apply Store Friendly';Hard='Review Hard Block...';Restore='Restore Windows'}
    $hints=@{Store='Shared app services stay available. Automatic OS updates use manual policy.';Hard='Store downloads will be restricted. You will confirm before anything changes.';Restore='Remove known watchdogs and restore the saved settings from before this tool.'}
    $script:Ui.SelectionTitle.Text=if($script:SelectedMode){'2  Selected: '+$labels[$script:SelectedMode]}else{'2  Apply your selection'}
    $script:Ui.ApplyButton.Content=if($script:SelectedMode){$buttons[$script:SelectedMode]}else{'Select a mode'}
    $script:Ui.SelectionHint.Text=if($reason){$reason}else{$hints[$script:SelectedMode]}
    $script:Ui.ApplyButton.ToolTip=if($reason){$reason}else{'Apply the selected mode. Selecting its card alone makes no changes.'}
    $script:Ui.ApplyButton.IsEnabled=-not [bool]$reason
    $script:Ui.AppContent.IsEnabled=$script:Ui.ConfirmOverlay.Visibility -ne 'Visible'
    $script:Ui.RefreshButton.IsEnabled=$idle
    $script:Ui.ReportButton.IsEnabled=$idle
}
function Select-Mode([string]$Mode) {
    if($Mode -notin @('Store','Hard','Restore')){return}
    $script:SelectedMode=$Mode
    Set-UiAvailability
}
function Close-HardConfirmation {
    $script:Ui.ConfirmOverlay.Visibility='Collapsed'
    Set-UiAvailability
    $script:Ui.ApplyButton.Focus() | Out-Null
}
function Apply-SelectedMode {
    Set-UiAvailability
    if(-not $script:Ui.ApplyButton.IsEnabled){return}
    if($script:SelectedMode -eq 'Hard'){
        $script:Ui.ConfirmOverlay.Visibility='Visible'
        Set-UiAvailability
        $script:Ui.CancelHardButton.Focus() | Out-Null
    }else{Start-UiJob $script:SelectedMode}
}
function Show-Page([string]$Name) {
    $script:Page=$Name
    $script:Ui.SelectionPanel.Visibility=if($Name -eq 'Overview'){'Visible'}else{'Collapsed'}
    foreach($page in @('Overview','Details','Activity')) {
        $script:Ui[($page+'Page')].Visibility=if($page -eq $Name){'Visible'}else{'Collapsed'}
        $script:Ui[($page+'Nav')].Background=if($page -eq $Name){'#203149'}else{'Transparent'}
        $script:Ui[($page+'Nav')].Foreground=if($page -eq $Name){'#64E5CA'}else{'#A5B9D1'}
    }
    $titles=@{Overview='Your updates. Your call.';Details='A clear view of this PC.';Activity='Every step, accounted for.'}
    $subtitles=@{Overview='Select a mode, review it, then apply when you are ready.';Details='Live service settings and scheduled watchdogs.';Activity='Progress, results and reports in one place.'}
    $script:Ui.PageTitle.Text=$titles[$Name]
    $script:Ui.PageSubtitle.Text=$subtitles[$Name]
    $script:Ui.MainScroll.ScrollToTop()
}
function Update-StatusView($Status,$Computer) {
    if ($null -eq $Status) { return }
    $script:LastStatus=$Status
    $script:LastChecked=Get-Date
    $labels=@{Unmanaged='Not configured';Normal='Restored';Hard='Hard Block';Store='Store Friendly';Transition='Changing mode';RecoveryRequired='Needs attention'}
    $descriptions=@{
        Unmanaged='Choose a mode below. No v4 mode is configured on this PC.'
        Normal='The controller has restored your saved settings.'
        Hard='Shared update services are blocked. Store downloads are also restricted.'
        Store='Windows updates are manual. Store services remain available.'
        Transition='A settings change has not finished. Check activity before continuing.'
        RecoveryRequired='The last operation needs attention. Choose Restore and review the log.'
    }
    $script:Ui.ModeText.Text=$labels[$Status.Mode]
    $script:Ui.ModeDescription.Text=$descriptions[$Status.Mode]
    $color=if(@($Status.Warnings).Count){'#F0BF69'}elseif($Status.Mode -eq 'Hard'){'#E6A0B7'}elseif($Status.Mode -eq 'Unmanaged'){'#9CB1CD'}else{'#4CE1BE'}
    $script:Ui.StatusDot.Fill=$color
    $script:Ui.StatusCard.BorderBrush=$color
    $script:Ui.WatchdogCount.Text=[string]@($Status.Tasks).Count
    $script:Ui.CheckedText.Text='Checked '+(Get-Date -Format 'HH:mm:ss')
    $script:Ui.ServicesGrid.ItemsSource=@($Status.Services)
    if (@($Status.Tasks).Count) { $script:Ui.TasksText.Text=(@($Status.Tasks | ForEach-Object { $_.Name+'  ['+$_.State+']' }) -join "`r`n") }
    else { $script:Ui.TasksText.Text='No controller watchdog tasks found in any Task Scheduler folder.' }
    $script:Ui.PolicyText.Text=if($Status.NoAutoUpdate -eq 1){'Automatic OS updates: disabled by policy.'}else{'Automatic OS updates: no disable value reported for this policy.'}
    $messages=@($Status.Warnings)
    if ($script:StartupNotice) { $messages += $script:StartupNotice }
    if ($Computer) {
        $script:Ui.SystemText.Text=$Computer.OS+'  /  '+$Computer.Build
        $script:StoreSupported=$Computer.Edition -match '^(Professional|Enterprise|Education|IoTEnterprise)'
        if (-not $script:StoreSupported) { $messages += 'Store Friendly policy mode is unavailable on this Windows edition. Use Windows Settings > Pause updates instead.' }
    }
    Show-Notice ($messages -join "`r`n")
    Set-UiAvailability
}
function Show-JobResult($Result) {
    $script:LastWorkerResult=$Result
    $action=$Result.Action
    if ($Result.LogPath) { $script:LastLog=$Result.LogPath; $script:Ui.SavedPathText.Text='Last operation log: '+$Result.LogPath }
    if ($Result.Status) { Update-StatusView $Result.Status $Result.Computer }
    if ($action -eq 'Status') {
        if ($Result.ExitCode -ne 0 -or $Result.StatusError -or -not $Result.Status) {
            $reason=if($Result.Error){$Result.Error}elseif($Result.StatusError){$Result.StatusError}else{'No status was returned.'}
            Show-Notice ('Unable to refresh status: '+$reason)
            $script:Ui.OperationText.Text='Status unavailable. Use Refresh to retry.'
            Add-Activity ('Status check failed: '+$reason)
            $script:LastChecked=Get-Date
        } else { $script:Ui.OperationText.Text='Status checked. Ready when you are.' }
        return
    }
    $script:Ui.ResultPanel.Visibility='Visible'
    if ($Result.ExitCode -eq 3010) {
        $script:Ui.ResultTitle.Text='Restart required'
        $script:Ui.ResultTitle.Foreground='#F0BF69'
        $script:Ui.ResultMessage.Text='Settings were saved, but Windows needs a restart to reload some services. Save your work, restart this PC, then refresh status here.'
        $script:Ui.OperationText.Text='Changes saved. Restart required before verification.'
        Add-Activity 'Changes saved. Restart required; Windows was not restarted automatically.'
    } elseif ($Result.ExitCode -eq 0) {
        $script:Ui.ResultTitle.Foreground='#4CE1BE'
        $titles=@{Hard='Hard Block configured';Store='Ready for app downloads';Restore='Blocker removed';Report='Diagnostic report saved'}
        $messages=@{
            Hard='One watchdog enforces the selected mode. Switch to Store Friendly when you need Microsoft Store downloads.'
            Store='Reopen Microsoft Store and try ChatGPT. If its previous error remains, use Win + R, enter wsreset.exe, then retry.'
            Restore='Watchdog removal was verified. Your saved settings were restored where a v4 backup exists. Other software or organization policies may still apply.'
            Report=('Report saved to: '+$Result.ReportPath)
        }
        $script:Ui.ResultTitle.Text=$titles[$action]
        $script:Ui.ResultMessage.Text=$messages[$action]
        $script:Ui.OperationText.Text='Completed. Settings checked by the controller.'
        if ($Result.StatusError) { $script:Ui.ResultMessage.Text += "`r`nThe final status refresh failed: "+$Result.StatusError }
        if ($Result.Status -and @($Result.Status.Warnings).Count) {
            $script:Ui.ResultTitle.Text='Settings saved; attention needed'
            $script:Ui.ResultTitle.Foreground='#F0BF69'
            $script:Ui.ResultMessage.Text=@($Result.Status.Warnings) -join "`r`n"
        }
        Add-Activity $titles[$action]
        if($Result.ReportPath){$script:Ui.SavedPathText.Text=$Result.ReportPath;Add-Activity ('Report: '+$Result.ReportPath)}
    } else {
        $script:Ui.ResultTitle.Text='Needs attention'
        $script:Ui.ResultTitle.Foreground='#F4A0B1'
        $script:Ui.ResultMessage.Text=$Result.Error
        if (-not $Result.Error) { $script:Ui.ResultMessage.Text='The controller did not complete the operation. Review Activity & logs, then select Restore to recover.' }
        $script:Ui.OperationText.Text='Incomplete. Read the result and review the log.'
        Add-Activity ('INCOMPLETE: '+$script:Ui.ResultMessage.Text)
    }
}
function Start-UiJob([string]$JobAction) {
    if ($script:ActiveJob) { return }
    if ($JobAction -in @('Hard','Store','Restore') -and $script:ViewOnly) {
        Show-Notice 'Changes require administrator access. Reopen the app and accept the Windows administrator prompt.'
        return
    }
    try {
        if (-not $script:SessionFolder) {
            $script:SessionFolder=Join-Path $env:TEMP ('UpdateControl-UI-'+[guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $script:SessionFolder | Out-Null
        }
        $jobId=[guid]::NewGuid().ToString('N')
        $base=Join-Path $script:SessionFolder $jobId
        $resultPath=$base+'.result.json'
        $progressPath=$base+'.progress.txt'
        $worker=Join-Path $script:GuiFolder 'UpdateControl.Worker.ps1'
        $arguments='-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -JobAction {1} -ResultPath "{2}" -ProgressPath "{3}"' -f $worker,$JobAction,$resultPath,$progressPath
        $process=Start-Process -FilePath $script:GuiPS -ArgumentList $arguments -WindowStyle Hidden -RedirectStandardOutput ($base+'.stdout.txt') -RedirectStandardError ($base+'.stderr.txt') -PassThru
        # Keep the process handle open now so Windows PowerShell 5.1 retains its exit code.
        $null=$process.Handle
        $script:ActiveJob=[pscustomobject]@{Action=$JobAction;Process=$process;ResultPath=$resultPath;ProgressPath=$progressPath;ErrorPath=($base+'.stderr.txt');Started=(Get-Date)}
        $script:LastProgress=''
        $script:Ui.ProgressBar.Visibility='Visible'
        $script:Ui.ProgressBar.IsIndeterminate=$true
        $script:Ui.OperationText.Text=if($JobAction -eq 'Status'){'Reading services, policies and watchdogs...'}else{'Starting '+$JobAction.ToLower()+' operation...'}
        if($JobAction -ne 'Status'){
            $script:Ui.ResultPanel.Visibility='Collapsed'
            Add-Activity ('Started '+$JobAction+'. The controller will verify the result.')
        }
        Set-UiAvailability
    } catch {
        $script:ActiveJob=$null
        $script:Ui.ProgressBar.Visibility='Collapsed'
        Show-JobResult ([pscustomobject]@{Action=$JobAction;ExitCode=1;Error=('Could not start the controller: '+$_.Exception.Message);LogPath=$null;ReportPath=$null;Status=$null;StatusError=$_.Exception.Message;Computer=$null})
        Set-UiAvailability
    }
}
function Update-JobProgress {
    $job=$script:ActiveJob
    if (-not $job) { return }
    if (Test-Path -LiteralPath $job.ProgressPath) {
        try {
            $progress=Get-Content -LiteralPath $job.ProgressPath -Raw
            if ($progress -and $progress -ne $script:LastProgress) {
                $script:LastProgress=$progress
                $lines=@($progress.TrimEnd() -split '\r?\n')
                $script:Ui.OperationText.Text=$lines[-1]
                $script:Ui.ActivityText.Text=($script:Activity -join "`r`n")+"`r`n"+$progress
                $script:Ui.ActivityText.ScrollToEnd()
            }
        } catch { } # A writer may still hold the progress stream; retry next tick.
    }
    $job.Process.Refresh()
    if (-not $job.Process.HasExited) { return }
    try {
        $job.Process.WaitForExit()
        if (-not (Test-Path -LiteralPath $job.ResultPath)) {
            $details=if(Test-Path -LiteralPath $job.ErrorPath){Get-Content -LiteralPath $job.ErrorPath -Raw}else{'No result file was produced.'}
            throw ('Controller exited without a result. '+$details)
        }
        $result=Get-Content -LiteralPath $job.ResultPath -Raw | ConvertFrom-Json
        if($result.Action -ne $job.Action){throw 'The controller result does not match the requested action.'}
        if($result.ExitCode -in @(0,3010) -and $job.Process.ExitCode -ne $result.ExitCode){throw ('The controller process did not exit with the reported result. Process: '+$job.Process.ExitCode+'; report: '+$result.ExitCode)}
        if($script:LastProgress){foreach($line in @($script:LastProgress.TrimEnd() -split '\r?\n')){$script:Activity.Add($line)}}
        $script:ActiveJob=$null
        Show-JobResult $result
    } catch {
        $script:ActiveJob=$null
        $fallback=[pscustomobject]@{Action=$job.Action;ExitCode=1;Error=$_.Exception.Message;LogPath=$null;ReportPath=$null;Status=$null;StatusError=$_.Exception.Message;Computer=$null}
        Show-JobResult $fallback
    } finally {
        $job.Process.Dispose()
        $script:ActiveJob=$null
        $script:Ui.ProgressBar.Visibility='Collapsed'
        Set-UiAvailability
    }
}
function New-SampleStatus([string]$Mode) {
    $actual=if($Mode -eq 'Busy'){'Transition'}else{$Mode}
    $tasks=if($actual -eq 'Hard'){@([pscustomobject]@{Name='\POS-WU-Guardian-v4';State='Ready'})}else{@()}
    $services=@('wuauserv','UsoSvc','BITS','DoSvc','InstallService','AppXSvc','ClipSVC') | ForEach-Object {
        $blocked=$actual -eq 'Hard' -and $_ -in @('wuauserv','UsoSvc','BITS','DoSvc')
        [pscustomobject]@{Name=$_;State=if($blocked){'Stopped'}else{'Running'};Startup=if($blocked){'Disabled'}elseif($_ -in @('UsoSvc','DoSvc')){'Automatic'}else{'Manual'};RegistryStart=if($blocked){4}else{3}}
    }
    $warnings=if($actual -eq 'RecoveryRequired'){@('A previous task deletion failed. Select Restore and review the log.')}else{@()}
    return [pscustomobject]@{Mode=$actual;Detail='Sample state for interface preview';NoAutoUpdate=if($actual -in @('Hard','Store')){1}else{$null};Tasks=@($tasks);Services=@($services);Warnings=@($warnings);DataFolder='C:\ProgramData\POSUpdateControl'}
}
function Export-UiPreview([string]$Path) {
    $root=$script:Ui.RenderRoot
    $size=New-Object Windows.Size($PreviewWidth,$PreviewHeight)
    $root.Measure($size)
    $root.Arrange((New-Object Windows.Rect(0,0,$PreviewWidth,$PreviewHeight)))
    $root.UpdateLayout()
    $bitmap=New-Object Windows.Media.Imaging.RenderTargetBitmap($PreviewWidth,$PreviewHeight,96,96,[Windows.Media.PixelFormats]::Pbgra32)
    $bitmap.Render($root)
    $encoder=New-Object Windows.Media.Imaging.PngBitmapEncoder
    $encoder.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bitmap))
    $stream=[IO.File]::Create($Path)
    try{$encoder.Save($stream)}finally{$stream.Dispose()}
}

try {
    foreach($file in @('UpdateControl.xaml','UpdateControl.Worker.ps1','UpdateControl.ps1','Repair-WindowsStore.ps1','Update-Control.ico')) {
        if(-not(Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))){throw "Missing $file. Extract every file in the ZIP into one folder."}
    }
    [xml]$xaml=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'UpdateControl.xaml') -Raw
    $reader=New-Object Xml.XmlNodeReader($xaml)
    $script:Window=[Windows.Markup.XamlReader]::Load($reader)
    $iconDecoder=[Windows.Media.Imaging.IconBitmapDecoder]::new([uri](Join-Path $PSScriptRoot 'Update-Control.ico'),[Windows.Media.Imaging.BitmapCreateOptions]::PreservePixelFormat,[Windows.Media.Imaging.BitmapCacheOption]::OnLoad)
    $icon=$iconDecoder.Frames | Sort-Object PixelWidth -Descending | Select-Object -First 1
    $script:Window.Icon=$icon
    foreach($node in $xaml.SelectNodes('//*[@*[name()="x:Name"]]')) {
        $name=$node.GetAttribute('Name','http://schemas.microsoft.com/winfx/2006/xaml')
        $script:Ui[$name]=$script:Window.FindName($name)
    }
    $script:Ui.TitleIcon.Source=$icon
    $script:Ui.BrandIcon.Source=$icon
    $area=[Windows.SystemParameters]::WorkArea
    $script:Window.Width=[Math]::Min(1160,[Math]::Max(940,$area.Width-30))
    $script:Window.Height=[Math]::Min(810,[Math]::Max(620,$area.Height-30))
    $script:Ui.AccessText.Text=if($script:ViewOnly){'Read-only access'}else{'Administrator access'}
    $script:Ui.MinimizeButton.Add_Click({$script:Window.WindowState='Minimized'})
    $script:Ui.MaximizeButton.Add_Click({$script:Window.WindowState=if($script:Window.WindowState -eq 'Maximized'){'Normal'}else{'Maximized'}})
    $script:Ui.CloseButton.Add_Click({$script:Window.Close()})
    $script:Ui.OverviewNav.Add_Click({Show-Page 'Overview'})
    $script:Ui.DetailsNav.Add_Click({Show-Page 'Details'})
    $script:Ui.ActivityNav.Add_Click({Show-Page 'Activity'})
    $script:Ui.RefreshButton.Add_Click({Start-UiJob 'Status'})
    foreach($name in @('StoreChoice','HardChoice','RestoreChoice')){
        $script:Ui[$name].Add_Checked({param($sender,$eventArgs) Select-Mode ([string]$sender.Tag)})
    }
    $script:Ui.ApplyButton.Add_Click({Apply-SelectedMode})
    $script:Ui.CancelHardButton.Add_Click({Close-HardConfirmation})
    $script:Ui.ConfirmHardButton.Add_Click({
        if($script:Ui.ConfirmOverlay.Visibility -ne 'Visible'){return}
        Close-HardConfirmation
        if(-not $script:ViewOnly -and -not $script:ActiveJob -and $script:LastStatus -and $script:SelectedMode -eq 'Hard'){Start-UiJob 'Hard'}
    })
    $script:Ui.ReportButton.Add_Click({Start-UiJob 'Report'})
    $script:Ui.CopyButton.Add_Click({try{[Windows.Clipboard]::SetText($script:Ui.ActivityText.Text);$script:Ui.SavedPathText.Text='Activity copied to clipboard.'}catch{Show-Notice $_.Exception.Message}})
    $script:Ui.LogsButton.Add_Click({
        $path=Join-Path $env:ProgramData 'POSUpdateControl'
        if(Test-Path -LiteralPath $path){Start-Process explorer.exe -ArgumentList ('"{0}"' -f $path)|Out-Null}
        else{Show-Notice 'No saved operation logs yet. Logs and backups appear after a mode change.'}
    })
    $script:Window.Add_PreviewKeyDown({param($sender,$eventArgs) if($eventArgs.Key -eq 'Escape' -and $script:Ui.ConfirmOverlay.Visibility -eq 'Visible'){Close-HardConfirmation;$eventArgs.Handled=$true}})
    $script:Timer=New-Object Windows.Threading.DispatcherTimer
    $script:Timer.Interval=[TimeSpan]::FromMilliseconds(250)
    $script:Timer.Add_Tick({
        try {
            Update-JobProgress
            if(-not $script:ActiveJob -and $script:LastStatus -and ((Get-Date)-$script:LastChecked).TotalSeconds -gt 30 -and $script:Ui.ConfirmOverlay.Visibility -ne 'Visible'){Start-UiJob 'Status'}
        } catch {Show-Notice ('Interface refresh failed: '+$_.Exception.Message)}
    })
    $script:Window.Add_Closing({param($sender,$eventArgs)
        if($script:ActiveJob -and $script:ActiveJob.Action -in @('Hard','Store','Restore')){
            $eventArgs.Cancel=$true
            Show-Notice 'An operation is still running. Please wait for verification before closing.'
        }else{
            $script:Timer.Stop()
            if($script:ActiveJob){try{if(-not $script:ActiveJob.Process.HasExited){$script:ActiveJob.Process.Kill()};$script:ActiveJob.Process.Dispose()}catch{}}
        }
    })
    Show-Page 'Overview'
    Set-UiAvailability
    Add-Activity 'Update Control desktop interface opened.'
    if($PreviewPath -or $SmokeTest){
        $script:ViewOnly=$false
        $computer=[pscustomobject]@{OS='Windows 10 Pro';Build='19045';Edition='Professional';IsAdmin=$true}
        Update-StatusView (New-SampleStatus $PreviewMode) $computer
        if($PreviewSelection -ne 'None'){$script:Ui[($PreviewSelection+'Choice')].IsChecked=$true}
        $script:Ui.AccessText.Text='Preview / no changes'
        $script:Ui.CheckedText.Text='Sample status'
        $script:Ui.OperationText.Text='Interface preview. No system settings changed.'
        $script:Ui.ProgressBar.Visibility='Collapsed'
        Add-Activity 'Sample status loaded for interface validation.'
        Show-Page $PreviewPage
        if($PreviewMode -eq 'Busy'){
            $script:Ui.OperationText.Text='Disarming and removing watchdogs from every task folder...'
            $script:Ui.ProgressBar.Visibility='Visible'
            $script:Ui.ProgressBar.IsIndeterminate=$false
            $script:Ui.ProgressBar.Value=45
        }
        if($SmokeTest){
            if(-not $script:Window.Icon -or -not $script:Ui.TitleIcon.Source -or -not $script:Ui.BrandIcon.Source){throw 'Application icon did not load in the window and branding.'}
            # Test the real hidden worker and polling path with read-only status only.
            $script:ViewOnly=$true
            Start-UiJob 'Status'
            $watch=[Diagnostics.Stopwatch]::StartNew()
            while($script:ActiveJob -and $watch.Elapsed.TotalSeconds -lt 30){Update-JobProgress;Start-Sleep -Milliseconds 100}
            if($script:ActiveJob){$script:ActiveJob.Process.Kill();throw 'Read-only GUI worker timed out.'}
            if(-not $script:LastWorkerResult -or $script:LastWorkerResult.Action -ne 'Status' -or $script:LastWorkerResult.ExitCode -ne 0 -or -not $script:LastWorkerResult.Status){throw ('Read-only GUI worker result failed: '+($script:LastWorkerResult|ConvertTo-Json -Depth 4 -Compress)+'; '+$script:Ui.NoticeText.Text)}
            'PASS: actual hidden status worker, process completion, JSON result, and live status binding.'
            $script:ViewOnly=$false
            Update-StatusView (New-SampleStatus 'Store') $computer
            Add-Type -AssemblyName UIAutomationProvider,UIAutomationTypes
            $script:TestActions=New-Object 'System.Collections.Generic.List[string]'
            function Start-UiJob([string]$JobAction){$script:TestActions.Add($JobAction)}
            function Invoke-TestButton([string]$Name){
                $peer=[Windows.Automation.Peers.ButtonAutomationPeer]::new($script:Ui[$Name])
                $provider=[Windows.Automation.Provider.IInvokeProvider]$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::Invoke)
                $provider.Invoke()
                $script:Window.Dispatcher.Invoke([Action]{},[Windows.Threading.DispatcherPriority]::Background)
            }
            function Select-TestMode([string]$Mode){
                $peer=[Windows.Automation.Peers.RadioButtonAutomationPeer]::new($script:Ui[($Mode+'Choice')])
                $provider=[Windows.Automation.Provider.ISelectionItemProvider]$peer.GetPattern([Windows.Automation.Peers.PatternInterface]::SelectionItem)
                $provider.Select()
            }
            function Assert-CardHitTarget([string]$Mode){
                $root=$script:Ui.RenderRoot
                $root.Measure([Windows.Size]::new(1160,810));$root.Arrange([Windows.Rect]::new(0,0,1160,810));$root.UpdateLayout()
                $card=$script:Ui[($Mode+'Choice')]
                foreach($point in @([Windows.Point]::new(10,10),[Windows.Point]::new($card.ActualWidth/2,56),[Windows.Point]::new($card.ActualWidth/2,$card.ActualHeight*0.65))){
                    $position=$card.TranslatePoint($point,$root)
                    $hit=[Windows.Media.VisualTreeHelper]::HitTest($root,$position)
                    if(-not $hit){throw ('No hit target in '+$Mode+' card.')}
                    $node=$hit.VisualHit
                    while($node -and $node -isnot [Windows.Controls.RadioButton]){$node=[Windows.Media.VisualTreeHelper]::GetParent($node)}
                    if($node -ne $card){throw ('Card heading/body/padding is not part of the selectable '+$Mode+' control.')}
                }
            }
            function Assert-ApplyHitTarget([int]$Width,[int]$Height){
                $root=$script:Ui.RenderRoot
                $root.Measure([Windows.Size]::new($Width,$Height));$root.Arrange([Windows.Rect]::new(0,0,$Width,$Height));$root.UpdateLayout()
                $button=$script:Ui.ApplyButton
                $point=$button.TranslatePoint([Windows.Point]::new($button.ActualWidth/2,$button.ActualHeight/2),$root)
                if($point.Y -ge $Height -or $point.X -ge $Width){throw 'Apply moved outside the visible window.'}
                $hit=[Windows.Media.VisualTreeHelper]::HitTest($root,$point)
                if(-not $hit){throw 'Apply has no visible pointer target.'}
                $node=$hit.VisualHit
                while($node -and $node -isnot [Windows.Controls.Button]){$node=[Windows.Media.VisualTreeHelper]::GetParent($node)}
                if($node -ne $button){throw 'Another element covers the Apply button.'}
            }
            if($script:SelectedMode -or $script:Ui.ApplyButton.IsEnabled){throw 'No selection must keep Apply disabled.'}
            foreach($mode in @('Store','Hard','Restore')){Assert-CardHitTarget $mode;Select-TestMode $mode}
            if($script:TestActions.Count -ne 0 -or $script:LastStatus.Mode -ne 'Store'){throw 'Selecting a card changed Windows or the current-mode display.'}
            Select-TestMode 'Hard'
            Assert-ApplyHitTarget 1160 810
            Assert-ApplyHitTarget 940 620
            if(-not $script:Ui.HardChoice.IsChecked -or $script:Ui.RestoreChoice.IsChecked -or $script:Ui.StoreChoice.IsChecked){throw 'Mode choices are not mutually exclusive.'}
            Invoke-TestButton 'ApplyButton'
            if($script:Ui.ConfirmOverlay.Visibility -ne 'Visible' -or $script:Ui.AppContent.IsEnabled -or $script:TestActions.Count){throw 'Hard confirmation did not isolate the modal or gate the action.'}
            Invoke-TestButton 'CancelHardButton'
            if($script:Ui.ConfirmOverlay.Visibility -ne 'Collapsed' -or -not $script:Ui.AppContent.IsEnabled -or $script:TestActions.Count){throw 'Hard cancellation failed.'}
            Select-TestMode 'Restore';Invoke-TestButton 'ApplyButton'
            Select-TestMode 'Store';Invoke-TestButton 'ApplyButton'
            Select-TestMode 'Hard';Invoke-TestButton 'ApplyButton';Invoke-TestButton 'ConfirmHardButton'
            $script:Ui.ConfirmHardButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if(($script:TestActions -join ',') -ne 'Restore,Store,Hard'){throw 'Explicit Apply routing or duplicate-confirm prevention failed.'}
            $script:ViewOnly=$true;Set-UiAvailability
            Select-TestMode 'Restore'
            $script:Ui.ApplyButton.RaiseEvent([Windows.RoutedEventArgs]::new([Windows.Controls.Button]::ClickEvent))
            if($script:Ui.ApplyButton.IsEnabled -or $script:Ui.SelectionHint.Text -notmatch 'Read-only' -or $script:TestActions.Count -ne 3){throw 'Read-only mode did not explain and prevent changes.'}
            $script:ViewOnly=$false;$script:ActiveJob=[pscustomobject]@{Action='Hard'};Set-UiAvailability
            if($script:Ui.ApplyButton.IsEnabled -or $script:Ui.HardChoice.IsEnabled -or $script:Ui.SelectionHint.Text -notmatch 'running'){throw 'Busy operation controls are not disabled and explained.'}
            $script:ActiveJob=[pscustomobject]@{Action='Status'};Set-UiAvailability
            Select-TestMode 'Hard'
            if($script:Ui.ApplyButton.IsEnabled -or -not $script:Ui.HardChoice.IsEnabled){throw 'Status refresh should allow selection but not applying.'}
            $script:ActiveJob=$null;Set-UiAvailability
            if($script:SelectedMode -ne 'Hard' -or -not $script:Ui.ApplyButton.IsEnabled){throw 'Status refresh lost the choice or left Apply disabled.'}
            $script:StoreSupported=$false;Select-TestMode 'Store'
            if($script:Ui.ApplyButton.IsEnabled -or $script:Ui.SelectionHint.Text -notmatch 'edition'){throw 'Unsupported Store mode needs an inline explanation.'}
            Select-TestMode 'Restore'
            if(-not $script:Ui.ApplyButton.IsEnabled){throw 'Unsupported Store mode incorrectly disabled Restore.'}
            $script:StoreSupported=$true
            Invoke-TestButton 'DetailsNav'
            if($script:Ui.DetailsPage.Visibility -ne 'Visible' -or $script:Ui.OverviewPage.Visibility -ne 'Collapsed'){throw 'Details navigation failed.'}
            $failure=[pscustomobject]@{Action='Restore';ExitCode=1;Error='Test deletion denied';LogPath=$null;Status=$null;Computer=$null}
            Show-JobResult $failure
            if($script:Ui.ResultTitle.Text -ne 'Needs attention'){throw 'Failure was not displayed distinctly.'}
            $failure.ExitCode=3010
            Show-JobResult $failure
            if($script:Ui.ResultTitle.Text -ne 'Restart required'){throw 'Restart requirement was not displayed.'}
            'PASS: full-card and visible Apply hit targets, accessible selection and Apply, zero changes on selection/cancel, modal isolation, action routing, disabled reasons and selection preservation.'

        }
        if($PreviewPath){Export-UiPreview $PreviewPath;Write-Output $PreviewPath}
        exit 0
    }
    $script:Window.Add_ContentRendered({Start-UiJob 'Status';$script:Timer.Start()})
    $script:Window.ShowDialog() | Out-Null
}catch{
    $message=$_.Exception.Message
    if($PreviewPath -or $SmokeTest){Write-Error $message;exit 1}
    $errorLog=Join-Path $env:TEMP 'Update-Control-GUI-error.txt'
    $_ | Out-String | Set-Content -LiteralPath $errorLog
    [Windows.MessageBox]::Show("The interface could not start.`r`n`r`n$message`r`n`r`nDetails: $errorLog`r`nYou can also use Update-Control-Console.cmd.",'Update Control','OK','Error')|Out-Null
    exit 1
}
