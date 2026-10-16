#Requires -Version 5.1
# Read build paths from the launcher's version; never select a stale EXE by wildcard.
$repo=Split-Path $PSScriptRoot -Parent
$manifest=[xml][IO.File]::ReadAllText((Join-Path $repo 'launcher\app.manifest'))
$version=[version]$manifest.assembly.assemblyIdentity.version
$releaseVersion=if($version.Revision -eq 0){$version.ToString(3)}else{$version.ToString(4)}
$dist=Join-Path $repo 'dist'
[pscustomobject]@{
    Version=$releaseVersion
    FileVersion=$version.ToString(4)
    ExecutablePath=Join-Path $dist "Update-Control-$releaseVersion.exe"
    ArchivePath=Join-Path $dist "Update-Control-Desktop-v$releaseVersion.zip"
}
