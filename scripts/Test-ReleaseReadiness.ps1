#Requires -Version 5.1
# Release preflight only. Does not sign, scan, upload, change trust, or execute the application.
[CmdletBinding()]
param(
    [string]$ExecutablePath,
    [Parameter(Mandatory=$true)][string]$ReviewRecordPath
)
$ErrorActionPreference='Stop'
if(-not $ExecutablePath){$ExecutablePath=(& (Join-Path $PSScriptRoot 'Get-ReleaseInfo.ps1')).ExecutablePath}
$hash=(Get-FileHash -LiteralPath $ExecutablePath -Algorithm SHA256).Hash
$signature=Get-AuthenticodeSignature -LiteralPath $ExecutablePath
if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or -not $signature.TimeStamperCertificate){
    throw 'Publication blocked: a valid trusted publisher signature and timestamp are required. Keep the build in draft.'
}
$record=Get-Content -LiteralPath $ReviewRecordPath -Raw | ConvertFrom-Json
if($record.Schema -ne 1 -or $record.Vendor -cne 'Microsoft' -or $record.Verdict -cne 'NotMalware'){
    throw 'Publication blocked: no recorded Microsoft NotMalware determination.'
}
if($record.Sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $record.Sha256 -ne $hash){
    throw 'Publication blocked: the review does not cover these exact signed EXE bytes.'
}
$when=[datetime]::Parse($record.ReviewedUtc,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
if($when -gt [datetime]::UtcNow -or $when -lt [datetime]'2026-10-09'){throw 'Publication blocked: invalid review date.'}
$reference=[uri]$record.EvidenceUrl
if($reference.Scheme -ne 'https' -or $reference.Host -notin @('www.microsoft.com','security.microsoft.com') -or [string]::IsNullOrWhiteSpace($record.SubmissionId)){
    throw 'Publication blocked: record the Microsoft submission identifier and evidence URL.'
}
Write-Output ('Preflight passed for SHA-256 '+$hash+'.')
Write-Output 'The publisher must inspect the referenced vendor determination. This checks the supplied record, not a live Microsoft verdict or future antivirus acceptance.'
