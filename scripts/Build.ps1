#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$dist=Join-Path $repo 'dist'
$build=Join-Path $dist 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$version='4.2.2'
$files=@('Update-Control.cmd','Update-Control-Console.cmd','WindowsUpdateManager.bat','WU-ManagerFinal.bat',
    'UpdateControl.GUI.ps1','UpdateControl.xaml','UpdateControl.Worker.ps1','UpdateControl.ps1',
    'Repair-WindowsStore.ps1','Repair-WindowsStore.cmd','Diagnose-WindowsStore.cmd','READ-ME-FIRST.txt','LICENSE','Update-Control.ico')
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$zip=Join-Path $dist "Update-Control-Desktop-v$version.zip"
if(Test-Path -LiteralPath $zip){Remove-Item -LiteralPath $zip}
$archive=[IO.Compression.ZipFile]::Open($zip,[IO.Compression.ZipArchiveMode]::Create)
try {
    foreach($file in $files){
        $entry=$archive.CreateEntry($file,[IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime=[DateTimeOffset]::new(2026,1,1,0,0,0,[TimeSpan]::Zero)
        $output=$entry.Open()
        try {$bytes=[IO.File]::ReadAllBytes((Join-Path $repo $file));$output.Write($bytes,0,$bytes.Length)} finally {$output.Dispose()}
    }
} finally {$archive.Dispose()}
$hash=(Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
$info=Join-Path $build 'BuildInfo.cs'
[IO.File]::WriteAllText($info,('internal static class BuildInfo {{ internal const string Version = "{0}"; internal const string PayloadSha256 = "{1}"; }}' -f $version,$hash))

$icon=Join-Path $repo 'Update-Control.ico'
if(-not(Test-Path -LiteralPath $icon)){throw 'Application icon missing. Run scripts/Build-Icon.ps1 first.'}
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path $compiler)){$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
$exe=Join-Path $dist 'Update-Control.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ "/out:$exe" "/win32manifest:$repo\launcher\app.manifest" "/win32icon:$icon" "/resource:$zip,UpdateControl.Payload.zip" /reference:System.Windows.Forms.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll (Join-Path $repo 'launcher\Program.cs') $info
if($LASTEXITCODE -ne 0){throw "C# compilation failed: $LASTEXITCODE"}
Copy-Item -LiteralPath $icon -Destination (Join-Path $dist 'Update-Control.ico') -Force
Copy-Item -LiteralPath (Join-Path $repo 'assets\Update-Control.png') -Destination (Join-Path $dist 'Update-Control.png') -Force
$sums=foreach($path in @($exe,$zip,(Join-Path $dist 'Update-Control.ico'),(Join-Path $dist 'Update-Control.png'))){ '{0}  {1}' -f (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(),(Split-Path $path -Leaf) }
[IO.File]::WriteAllLines((Join-Path $dist 'SHA256SUMS.txt'),[string[]]$sums,[Text.UTF8Encoding]::new($false))
Write-Host "Built single EXE and portable ZIP in $dist"
Write-Host 'This build is unsigned. Publisher signing requires a trusted code-signing identity; see docs/SIGNING.md.'
