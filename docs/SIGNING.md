# Publisher identity, Windows warnings and false positives

The public 4.2.1 preview is **unsigned**. The author/company fields and custom icon are application metadata, not a verified publisher signature. No certificate is bundled and the build does not install a trust root, add an antivirus exclusion, or switch off security checks.

Three different prompts can appear:

| Prompt | Meaning | Appropriate next step |
| --- | --- | --- |
| UAC administrator prompt | The app requests permission to manage services, policies and scheduled tasks | Expected for this application; publisher signing can identify the author but does not remove the need for elevation |
| SmartScreen / unrecognized app / unknown publisher | File or publisher identity/reputation is not established | Use a publicly trusted signing identity and a consistent release channel; a new signed file may still warn |
| Antivirus threat detection | The security product identified a specific threat or unwanted behavior | Record the exact detection and file hash, review the source, and submit an incorrect detection to the vendor for analysis |

An icon, a hash, a clean scan, or a signature cannot guarantee that every security product will accept the file. Changing update services and creating a SYSTEM guardian are deliberate, documented administrator functions. The launcher transparently embeds a ZIP of readable source scripts and runs Windows PowerShell. It uses a process-scoped execution-policy argument for those scripts; it does not change the machine's execution policy or disable Defender/AMSI. Corporate application-control policy can still block it.

## Sign a release you publish

Obtain a trusted code-signing identity that you control. Microsoft documents Azure Artifact Signing, CA-issued certificates, and qualifying open-source signing programs. Identity validation is required; do not put private keys or certificate passwords in this repository.

For a valid CA-issued certificate already accessible in your Windows certificate store, install SignTool from the Windows SDK, then run:

```powershell
.\scripts\Build.ps1
.\scripts\Sign-Release.ps1 -CertificateThumbprint YOUR_CERTIFICATE_THUMBPRINT
.\tests\Test-Package.ps1
```

The optional script signs the EXE with SHA-256, requests an RFC 3161 timestamp, verifies Authenticode, confirms the expected certificate and timestamp, and refreshes release checksums. It rejects self-signed, expired, untrusted and non-code-signing certificates. It does not request or import a private key. Hardware-backed keys can require their provider's interactive authorization.

Use `-CertificateStore LocalMachine`, `-SignToolPath`, or `-TimestampServer` when your existing setup requires them. Cloud signing services have their own provider/workflow setup; this local-certificate helper does not configure an Azure account.

Sign **after** the build and publish those exact signed bytes. Rebuilding or editing the signed EXE invalidates that signature. The signature covers its embedded archive; the separately published source ZIP is not itself Authenticode signed. Re-run the package checks and a release scan after signing.

No actual publisher-signing run has been performed for this preview because no suitable certificate is available. Syntax and preflight handling are checked; the certificate-backed path needs the publisher's credentials and provider.

## Scan and report an incorrect detection

Use the installed security product to scan the exact release and record the result, signature version, date and SHA-256. A local scan is a point-in-time result, not certification or a SmartScreen reputation check. This project does not alter a binary in response to detection results to conceal its behavior.

Microsoft accepts developer submissions of incorrectly classified files at its Security Intelligence portal. Include the detected product/name, exact hash, repository link, and explanation of the user-selected update controls. A submission is not a promise of acceptance; review and classification remain with the vendor.

Official references:

- [Microsoft code-signing options and reputation limitations](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)
- [SignTool commands](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool)
- [Microsoft developer file-analysis submission](https://www.microsoft.com/en-us/wdsi/filesubmission)
- [Defender custom-scan commands and return values](https://learn.microsoft.com/en-us/defender-endpoint/command-line-arguments-microsoft-defender-antivirus)
