#Requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$dist=Join-Path $repo 'dist'
$build=Join-Path $dist 'build'
New-Item -ItemType Directory -Path $build -Force | Out-Null
$version='4.2.0'
$files=@('Update-Control.cmd','Update-Control-Console.cmd','WindowsUpdateManager.bat','WU-ManagerFinal.bat',
    'UpdateControl.GUI.ps1','UpdateControl.xaml','UpdateControl.Worker.ps1','UpdateControl.ps1',
    'Repair-WindowsStore.ps1','Repair-WindowsStore.cmd','Diagnose-WindowsStore.cmd','READ-ME-FIRST.txt','LICENSE')
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem,System.Drawing
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

# Draw the small application icon from the repository's shield design.
$bitmap=New-Object Drawing.Bitmap(64,64)
$graphics=[Drawing.Graphics]::FromImage($bitmap)
$graphics.SmoothingMode=[Drawing.Drawing2D.SmoothingMode]::AntiAlias
$graphics.Clear([Drawing.ColorTranslator]::FromHtml('#0B1322'))
$shield=New-Object Drawing.Drawing2D.GraphicsPath
$shield.AddPolygon([Drawing.PointF[]]@([Drawing.PointF]::new(32,7),[Drawing.PointF]::new(52,15),[Drawing.PointF]::new(49,39),[Drawing.PointF]::new(32,57),[Drawing.PointF]::new(15,39),[Drawing.PointF]::new(12,15)))
$brush=New-Object Drawing.SolidBrush([Drawing.ColorTranslator]::FromHtml('#45DDC1'))
$graphics.FillPath($brush,$shield)
$pen=New-Object Drawing.Pen([Drawing.ColorTranslator]::FromHtml('#0B1322'),5)
$graphics.DrawLines($pen,[Drawing.PointF[]]@([Drawing.PointF]::new(22,31),[Drawing.PointF]::new(29,38),[Drawing.PointF]::new(43,23)))
$png=New-Object IO.MemoryStream
$bitmap.Save($png,[Drawing.Imaging.ImageFormat]::Png)
$icon=Join-Path $build 'Update-Control.ico'
$writer=New-Object IO.BinaryWriter([IO.File]::Create($icon))
try {
    $writer.Write([uint16]0);$writer.Write([uint16]1);$writer.Write([uint16]1)
    $writer.Write([byte]64);$writer.Write([byte]64);$writer.Write([byte]0);$writer.Write([byte]0)
    $writer.Write([uint16]1);$writer.Write([uint16]32);$writer.Write([uint32]$png.Length);$writer.Write([uint32]22);$writer.Write($png.ToArray())
} finally {$writer.Dispose();$png.Dispose();$pen.Dispose();$brush.Dispose();$shield.Dispose();$graphics.Dispose();$bitmap.Dispose()}
$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if(-not(Test-Path $compiler)){$compiler=Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'}
$exe=Join-Path $dist 'Update-Control.exe'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ "/out:$exe" "/win32manifest:$repo\launcher\app.manifest" "/win32icon:$icon" "/resource:$zip,UpdateControl.Payload.zip" /reference:System.Windows.Forms.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll (Join-Path $repo 'launcher\Program.cs') $info
if($LASTEXITCODE -ne 0){throw "C# compilation failed: $LASTEXITCODE"}
$sums=foreach($path in @($exe,$zip)){ '{0}  {1}' -f (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant(),(Split-Path $path -Leaf) }
[IO.File]::WriteAllLines((Join-Path $dist 'SHA256SUMS.txt'),[string[]]$sums,[Text.UTF8Encoding]::new($false))
Write-Host "Built single EXE and portable ZIP in $dist"
