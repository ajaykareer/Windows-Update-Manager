# Troubleshooting

## Store says “Turn on Windows Update”

Open Update Control, select the **Restore** card, click **Restore Windows**, and follow any restart message. Reopen the controller, select **Store Friendly**, then click **Apply Store Friendly** on a supported edition. This keeps shared services available while setting automatic Windows updates to manual policy. Close and reopen Microsoft Store. If it retains an old error, run `wsreset.exe` from Win+R.

Do not keep Hard Block enabled while expecting Store downloads to work. Other causes, such as account, network, organization policy or Store damage, are outside this controller's repair scope.

## A watchdog remains after Restore

The new controller looks in every Task Scheduler folder for both `WU-Guardian*` and `POS-WU-Guardian*` families, but matches only the explicit names listed in the README. It disarms enforcement, then separately tries disable, stop and deletion. If deletion still fails, it reports **Needs attention** and includes a log path.

Use **Activity → Open logs** and create a diagnostic report. Confirm you opened the controller with administrator access. Rerun Restore after resolving the reported error. Do not delete the data folder while a guardian is still active. Tasks with custom names are not automatically deleted.

## Mode cards or Apply seem unresponsive

In 4.2.2, click anywhere on a card to select it. The outline and radio marker change, and the bottom action button names the selected action. Selecting alone does not change the **Current mode** panel; only applying and successfully completing a change does that.

Read the message beside Apply if it is disabled: no selection, read-only access, an operation in progress, unavailable status, or an unsupported Windows edition. During a status refresh you can still choose a card; applying waits for the refresh. During a settings change, the choices and action are disabled together. The button stays visible while the content scrolls.

The older 4.2.1 layout used static cards with separate small buttons. Close that version and open the current EXE if you still see those individual card buttons. If an enabled action still does nothing, report its exact label and the Activity text.

## Restart required

Some service configurations can be written to the registry while the Service Control Manager still has the previous configuration cached. The controller returns code `3010` and shows **Restart required**. Restart Windows yourself, reopen the app, and refresh status. If a dependency is still disabled, rerun Restore and inspect the log.

## Needs attention / failed transition

The controller disarms the saved Hard state, attempts watchdog removal and, for failed block/Store transitions with a baseline, attempts rollback. It preserves the baseline for recovery. A rollback failure is also logged; do not assume the machine is fully restored until Restore succeeds.

Logs and backups are under `%ProgramData%\POSUpdateControl`. Legacy repair saves separate backups under `%ProgramData%\POS_WU_Repair`. Diagnostic reports may include the machine name and paths; review them before posting publicly.

## EXE does not open

The EXE requires administrator access. Cancelling its UAC prompt prevents it from starting. For read-only use, extract the ZIP and launch `UpdateControl.GUI.ps1 -ReadOnly` using Windows PowerShell 5.1 with `-STA`.

The EXE is unsigned, so Windows or security software may require a trust decision. Corporate application-control rules can prevent scripts or unsigned applications from running. Do not disable your security tools to work around a policy; ask the administrator.

If the launcher reports a changed cached component, close the app and remove only the exact version folder named by that error under `%ProgramFiles%\Kareer Update Control`, then reopen a verified release EXE. Do not delete `%ProgramData%\POSUpdateControl`; that holds your restoration baseline. The EXE validates all embedded component bytes again on launch.

For a WPF startup failure, check `%TEMP%\Update-Control-GUI-error.txt` and try the ZIP's `Update-Control-Console.cmd`.

## Remove the application

1. Open it, select the **Restore** card and click **Restore Windows**. Wait for success and follow any restart message.
2. Verify that the watchdog count is zero.
3. Close the application. You can then delete the downloaded EXE/ZIP and the application component folder under `%ProgramFiles%\Kareer Update Control`.
4. Keep the ProgramData logs/backups until you have verified normal operation. Deleting the EXE alone does not disable an installed Hard Block watchdog.

## Report a problem

[Open an issue](https://github.com/ajaykareer/Windows-Update-Manager/issues) with Windows edition/build, selected mode, the exact error, and the relevant log after reviewing it for personal information. Avoid claiming that Restore succeeded if the app said it was incomplete.
