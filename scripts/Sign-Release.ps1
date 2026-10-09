#Requires -Version 5.1
# Optional publisher signing. Does not create certificates or change machine trust.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidatePattern('^[a-fA-F0-9]{40}$')][string]$CertificateThumbprint,
    [ValidateSet('CurrentUser','LocalMachine')][string]$CertificateStore='CurrentUser',
    [uri]$TimestampServer='https://timestamp.digicert.com',
    [string]$SignToolPath
)
$ErrorActionPreference='Stop'
if($TimestampServer.Scheme -notin @('http','https')){throw 'An HTTP(S) RFC 3161 timestamp service is required.'}
$cert=Get-Item -LiteralPath ('Cert:\{0}\My\{1}' -f $CertificateStore,$CertificateThumbprint)
if(-not $cert.HasPrivateKey){throw 'The certificate has no accessible private key.'}
if($cert.NotBefore -gt (Get-Date) -or $cert.NotAfter -le (Get-Date)){throw 'The signing certificate is not currently valid.'}
if($cert.Subject -eq $cert.Issuer){throw 'Self-signed certificates are not supported for public releases.'}
if('1.3.6.1.5.5.7.3.3' -notin @($cert.EnhancedKeyUsageList | ForEach-Object {$_.ObjectId})){throw 'A code-signing certificate is required.'}
$chain=New-Object Security.Cryptography.X509Certificates.X509Chain
try{if(-not $chain.Build($cert)){throw ('Certificate chain is not trusted: '+(($chain.ChainStatus | ForEach-Object {$_.StatusInformation.Trim()}) -join '; '))}}finally{$chain.Dispose()}
if(-not $SignToolPath){
    $command=Get-Command signtool.exe -ErrorAction SilentlyContinue
    if($command){$SignToolPath=$command.Source}
    else{
        $sdk=Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\bin'
        $SignToolPath=Get-ChildItem -LiteralPath $sdk -Directory -ErrorAction SilentlyContinue |
            Where-Object {$_.Name -match '^\d+\.\d+\.\d+\.\d+$'} | Sort-Object {[version]$_.Name} -Descending |
            ForEach-Object {Join-Path $_.FullName 'x64\signtool.exe'} | Where-Object {Test-Path -LiteralPath $_} | Select-Object -First 1
    }
}
if(-not $SignToolPath -or -not(Test-Path -LiteralPath $SignToolPath)){throw 'Install SignTool from the Windows SDK or pass -SignToolPath.'}
$dist=Join-Path (Split-Path $PSScriptRoot -Parent) 'dist'
$exe=Join-Path $dist 'Update-Control.exe'
if(-not(Test-Path -LiteralPath $exe)){throw 'Build the release first.'}
$arguments=@('sign','/s','My','/sha1',$CertificateThumbprint,'/fd','SHA256','/tr',$TimestampServer.AbsoluteUri,'/td','SHA256','/d','Update Control Desktop','/du','https://github.com/ajaykareer/Windows-Update-Manager')
if($CertificateStore -eq 'LocalMachine'){$arguments+='/sm'}
& $SignToolPath @arguments $exe
if($LASTEXITCODE -ne 0){throw 'Signing or timestamping failed. Do not publish this output.'}
& $SignToolPath verify /pa /all /v $exe
if($LASTEXITCODE -ne 0){throw 'Authenticode verification failed. Do not publish this output.'}
$signature=Get-AuthenticodeSignature -LiteralPath $exe
if($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Thumbprint -ne $CertificateThumbprint -or -not $signature.TimeStamperCertificate){throw 'Expected valid publisher signature and timestamp were not found.'}
# Signing changes the EXE bytes. Refresh all existing release checksums afterward.
$checksumFile=Join-Path $dist 'SHA256SUMS.txt'
$lines=foreach($line in Get-Content -LiteralPath $checksumFile){
    if($line -notmatch '^[a-fA-F0-9]{64}  ([^\\/:]+)$'){throw 'Invalid release checksum entry.'}
    $name=$Matches[1]
    '{0}  {1}' -f (Get-FileHash -LiteralPath (Join-Path $dist $name) -Algorithm SHA256).Hash.ToLowerInvariant(),$name
}
[IO.File]::WriteAllLines($checksumFile,[string[]]$lines,[Text.UTF8Encoding]::new($false))
Write-Host 'Publisher signature and RFC 3161 timestamp verified; release checksums refreshed.'
