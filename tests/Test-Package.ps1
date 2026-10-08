#Requires -Version 5.1
param([switch]$Extract)
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$exe=Join-Path $repo 'dist\Update-Control.exe'
$zip=Join-Path $repo 'dist\Update-Control-Desktop-v4.2.0.zip'
$assembly=[Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
$resource=$assembly.GetManifestResourceStream('UpdateControl.Payload.zip')
$buffer=New-Object IO.MemoryStream
try{$resource.CopyTo($buffer);$bytes=$buffer.ToArray()}finally{$resource.Dispose();$buffer.Dispose()}
$sha=[Security.Cryptography.SHA256]::Create()
try{$actual=[BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose()}
$constant=$assembly.GetType('BuildInfo').GetField('PayloadSha256',[Reflection.BindingFlags]'Static,NonPublic').GetRawConstantValue()
if($constant -ne $actual -or (Get-FileHash $zip).Hash.ToLowerInvariant() -ne $actual){throw 'Embedded payload does not match the ZIP or hash constant.'}
Add-Type -AssemblyName System.IO.Compression
$archive=New-Object IO.Compression.ZipArchive([IO.MemoryStream]::new($bytes),[IO.Compression.ZipArchiveMode]::Read)
try {
    foreach($entry in $archive.Entries){
        if($entry.FullName -ne [IO.Path]::GetFileName($entry.FullName)){throw 'Unexpected nested entry'}
        $stream=$entry.Open();$copy=New-Object IO.MemoryStream
        try {$stream.CopyTo($copy);$expected=[IO.File]::ReadAllBytes((Join-Path $repo $entry.FullName));if([Convert]::ToBase64String($copy.ToArray()) -ne [Convert]::ToBase64String($expected)){throw "Stale packaged file: $($entry.FullName)"}}finally{$copy.Dispose();$stream.Dispose()}
    }
}finally{$archive.Dispose()}
Write-Host 'PASS: EXE resource integrity, hash constant, and every packaged file matches source.'
if($Extract){
    if($env:GITHUB_ACTIONS -ne 'true'){throw 'Elevated extraction test is restricted to disposable GitHub Actions runners.'}
    $report=Join-Path $repo 'dist\package-check.txt'
    $process=Start-Process -FilePath $exe -ArgumentList ('--verify-package "{0}"' -f $report) -PassThru -Wait -WindowStyle Hidden
    Get-Content -LiteralPath $report
    if($process.ExitCode -ne 0){throw "EXE verification failed: $($process.ExitCode)"}
    $process=Start-Process -FilePath $exe -ArgumentList ('--verify-package "{0}"' -f $report) -PassThru -Wait -WindowStyle Hidden
    if($process.ExitCode -ne 0){throw 'Second launch could not reuse the verified cache.'}
    Write-Host 'PASS: real elevated EXE extraction and cached second launch.'
}
