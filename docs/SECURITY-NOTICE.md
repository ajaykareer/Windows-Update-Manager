# Reported Microsoft Defender detection

Status as of 2026-10-09: **unresolved; no vendor verdict obtained**.

A user supplied a Windows Security screenshot showing `Trojan:Win32/Sabsik.FL.A!ml` (Severe) for a downloaded file named `Update-Control 4.2.2.exe`. This establishes a detection associated with that filename. We have not obtained the affected file's SHA-256, the affected PC's Defender versions, or evidence identifying the detection trigger. The screenshot alone does not prove the affected file matches the published release, that the file is malicious, or that this is a false positive.

## What users should do

1. Stop using the reported build. Keep detections quarantined or removed; do not allow or restore them to continue using the tool. Do not disable security software, add an exclusion, or substitute the portable scripts or an older release as a workaround.
2. If you selected **Allow on device**, open **Windows Security → Virus & threat protection → Allowed threats**, select the relevant entry, and choose **Don't allow**. Then scan again and follow Defender's remediation instructions. If you restored the file without allowing it, quarantine any renewed detection.
3. If you previously applied **Hard Block**, open **Task Scheduler → Task Scheduler Library**, locate `POS-WU-Guardian-v4`, and choose **Disable**, then **End** if it is running. This is the task installed by version 4; check other folders if you moved it. Report failure or a missing task instead of assuming it was stopped. Do not run the flagged app to select Restore.
4. Keep `%ProgramData%\POSUpdateControl\active-baseline.json` and the `backups` folder. These contain saved service/policy settings for recovery. Quarantining the downloaded EXE or stopping the watchdog does **not** restore those settings or remove an installed script copy. Hard Block disabled `wuauserv`, `UsoSvc`, `BITS` and `DoSvc` and set an automatic-update policy; recovery must account for the saved baseline and any organization policies.
5. Record the detection name, affected filename, Defender security-intelligence/engine versions, and remediation result. Do not restore or execute a quarantined file to collect evidence. Do not post private machine paths or unreviewed logs publicly.

The Windows Security heading **Threat removed or restored** alone does not distinguish removal from restoring the file. The action actually taken matters. This notice is containment guidance, not confirmation that an affected PC is clean or its Windows Update configuration is restored.

## Published release evidence

| Item | Recorded evidence |
| --- | --- |
| Release | `v4.2.2` |
| Source commit | `24ee5ba0d18c387b8e73bd209464d6ed67f9412e` |
| Published EXE SHA-256 | `09b08143310c19c32800d28d3b4ae6df84b3f1e4a76aaf2c0e089cf03c0766a0` |
| EXE size | 135,680 bytes |
| Signature | Unsigned |
| Earlier local scan | 2026-10-09 15:27:50 UTC; engine `1.1.26080.3`; intelligence `1.459.634.0`; reported no threats |

The existing local release copy and GitHub's release asset digest match the recorded EXE hash. **The affected PC's copy has not been hash-matched.** The earlier custom file scan used non-remediating mode and did not test running the application with Hard Block on that PC. Neither that result nor successful functional CI tests override this report. The release binaries have not been rebuilt or changed in response to the detection; the release page carries this warning alongside the historical assets.

## Review and next steps

The launcher requests administrator access, checks and extracts embedded readable PowerShell components, and starts Windows PowerShell. Hard Block, when applied by the user, changes update policy, disables shared update services, and registers one SYSTEM task for enforcement. These are intended functions documented in the source; they are **not evidence identifying why Defender classified this file**.

A vendor-review draft has been prepared. No file has been submitted on the user's behalf and no Microsoft determination has been received. Review should compare the affected artifact when available, the published binary and source, and the affected PC's detection details. Do not label the report a false positive without supporting evidence. Publisher signing can establish identity but does not certify that a binary is harmless or resolve this detection.

References:

- [Microsoft: Allowed threats and Don't allow](https://support.microsoft.com/en-us/windows/security/threat-malware-protection/virus-and-threat-protection-in-the-windows-security-app)
- [Microsoft: Protection History](https://support.microsoft.com/en-us/windows/security/windows-security/protection-history-in-the-windows-security-app)
- [Microsoft Security Intelligence: submit a file for analysis](https://www.microsoft.com/en-us/wdsi/filesubmission)
