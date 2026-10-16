#Requires -Version 5.1
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
$scratch=Join-Path $PSScriptRoot ('runs\release-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
$sample=Join-Path $scratch 'sample.bin'
$recordPath=Join-Path $scratch 'review.json'
[IO.File]::WriteAllText($sample,'Nonexecutable test data')
$record=@{Schema=1;Vendor='Microsoft';Verdict='NotMalware';Sha256=(Get-FileHash $sample).Hash;ReviewedUtc=[datetime]::UtcNow.AddMinutes(-1).ToString('o');SubmissionId='TEST-ONLY';EvidenceUrl='https://www.microsoft.com/en-us/wdsi/filesubmission'}
$signatureFixture=@{Status='Valid'}
function Get-AuthenticodeSignature { [pscustomobject]@{Status=$signatureFixture.Status;SignerCertificate=[pscustomobject]@{};TimeStamperCertificate=[pscustomobject]@{}} }
function Run-Check([bool]$ShouldPass) {
    $record | ConvertTo-Json | Set-Content -LiteralPath $recordPath -Encoding UTF8
    $passed=$true
    $reason=''
    try { & (Join-Path $repo 'scripts\Test-ReleaseReadiness.ps1') -ExecutablePath $sample -ReviewRecordPath $recordPath | Out-Null } catch { $passed=$false;$reason=$_.Exception.Message }
    if($passed -ne $ShouldPass){throw ('Unexpected release preflight result. '+$reason)}
}
Run-Check $true
$signatureFixture.Status='NotSigned';Run-Check $false
$signatureFixture.Status='HashMismatch';Run-Check $false
$signatureFixture=@{Status='Valid'};$record.Verdict='Pending';Run-Check $false
$record.Verdict='NotMalware';$record.Sha256=('0'*64);Run-Check $false
$record.Sha256=(Get-FileHash $sample).Hash;$record.EvidenceUrl='https://example.com/claim';Run-Check $false
$record.EvidenceUrl='https://www.microsoft.com/en-us/wdsi/filesubmission';$record.ReviewedUtc=[datetime]::UtcNow.AddDays(1).ToString('o');Run-Check $false
Write-Host 'PASS: release preflight rejects unsigned/invalid signatures, pending review, wrong hash, unrelated evidence and future review.'
