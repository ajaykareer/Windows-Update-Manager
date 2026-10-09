# Building Update Control

Use Windows PowerShell 5.1 on Windows 10/11 with .NET Framework 4.8 or later. Building does not require elevation, downloaded packages, or changes to update settings. The workflow uses a Windows Server 2022 runner for the Windows API tests; that does not establish client OS policy support.

From the repository directory:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\Build.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Package.ps1
```

The build creates these ignored outputs in `dist`:

- `Update-Control.exe`: native C# launcher with embedded ZIP, SHA-256 integrity check, administrator manifest, and application icon.
- `Update-Control-Desktop-v4.2.1.zip`: the same application components for manual extraction.
- `SHA256SUMS.txt`: checksums for both downloads.
- `Update-Control.ico` and `Update-Control.png`: reusable application icon assets (also covered by the checksums).

The ICO contains 16, 24, 32, 48, 64, 128 and 256 pixel frames and is embedded in the executable and used by the WPF window. To regenerate it and the 1024 pixel PNG from the editable vector drawing, run `powershell.exe -NoProfile -STA -File .\scripts\Build-Icon.ps1`.

The launcher validates the embedded archive and caches files under `%ProgramFiles%\Kareer Update Control\<version>-<payload hash>`. Only Administrators and SYSTEM can write the application components; Users can read and execute. Paths through reparse points are refused. Changed cached files cause a startup error. The launcher starts built-in Windows PowerShell in STA mode to host WPF. The app remains script based internally; “single EXE” means a single download with automatic extraction, not a separately compiled WPF application.

No signing certificate is included. An unsigned build has no verified publisher identity.

See [publisher signing](SIGNING.md) for the optional SHA-256/RFC 3161 signing helper, provider requirements and the limits of signing. The public preview is still unsigned.

## Local checks

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-UpdateControl.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Repair.ps1
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\UpdateControl.GUI.ps1 -SmokeTest
```

These checks use mocked mutations, temporary files, real task-definition builders, and a real read-only status worker. They do not disable live services or register tasks.

`tests/Test-WindowsIntegration.ps1` is restricted to disposable GitHub-hosted runners. It compiles temporary services and creates a private controller fixture whose service names, policy keys, state paths, and guardian name point only to test resources. The actual service-control, ACL, task registration, SYSTEM enforcement, state writing, baseline and restoration functions run against those resources. The edition check is bypassed only in that fixture; the production controller retains it. The fixture refuses legacy repair, which must never be invoked against the runner's production update configuration.

## Regenerate screenshots

```powershell
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\UpdateControl.GUI.ps1 -PreviewPath .\docs\screenshots\overview.png -PreviewMode Store
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\UpdateControl.GUI.ps1 -PreviewPath .\docs\screenshots\system-details.png -PreviewMode Hard -PreviewPage Details
powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\UpdateControl.GUI.ps1 -PreviewPath .\docs\screenshots\activity.png -PreviewMode RecoveryRequired -PreviewPage Activity
```

Preview renders the actual WPF layout offscreen with labeled sample data. It does not change Windows settings.
