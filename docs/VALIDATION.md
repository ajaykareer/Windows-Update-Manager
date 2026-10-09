# Validation and limits

Version 4.2.2 is a preview. A successful build is not a guarantee that Windows servicing, every protected service, or Microsoft Store behaves identically on every machine.

See [Windows validation runs](https://github.com/ajaykareer/Windows-Update-Manager/actions/workflows/windows.yml) for the result on each commit. The release packages should come from a successful run for the release commit.

| Check | Coverage | What it does not prove |
| --- | --- | --- |
| Controller regression suite | Hard → Store → Restore, repeated restore, absent/original policy, immutable baseline, failure rollback, corrupt state, real file locks and atomic replacement | Actual Windows Update service permissions or OS policy enforcement |
| Watchdog removal regression | Both legacy naming families; all task folders; independent disable/stop/delete attempts; CLI fallback; remaining tasks fail explicitly | Every third-party task or renamed/custom blocker |
| Repair regression suite | Exact known policy/ACL cleanup, unrelated policy preservation, service fallback errors, backup and teardown ordering | Exact pre-script permissions that old releases never recorded |
| WPF smoke test | Actual status worker, card heading/body/padding hit targets, unobstructed Apply target at standard/minimum sizes, accessibility selection/invocation, no changes on selection/cancel, action routing, modal isolation, disabled-state reasons and selection persistence | Physical pointer/keyboard input or a real privileged button click on the affected PC |
| Interface previews | Real WPF rendering with sample status, including smaller window layouts | A screenshot of successful live blocking |
| Windows API integration | Actual temporary services, protected state/engine ACLs, scheduled SYSTEM task, drift correction, startup-setting restoration and task deletion | Client Windows Update, Medic behavior, reboot persistence, MDM or Store app installation |
| EXE/ZIP verification | Embedded SHA-256, exact source-to-package comparison, real elevated extraction and cached second launch in CI | Publisher signing, SmartScreen reputation or antivirus acceptance |

The development workstation's update configuration is not modified by local tests. The hosted integration test uses uniquely named disposable resources and never targets Windows Update services or policy keys.

## Still requires a representative Windows client

- A real legacy-blocker upgrade, including protected service/registry ACL repair and any requested restart.
- Hard Block across restart and Windows servicing activity.
- Hard → Store Friendly followed by an actual Microsoft Store app download.
- Store Friendly policy behavior on each supported client edition and any managed environment.
- Restore followed by normal Windows Update scanning and app installation.

The user previously reported that their Store download resumed after repairing the old blocker. That is useful evidence about the original issue, but it is not an end-to-end test of this new EXE or all its modes.

## Scope of restoration

Version 4 saves service startup/delayed-start settings and the original existence, type and value of `NoAutoUpdate` before starting a new blocking cycle. It preserves that baseline across mode switches and verifies it before retiring the active baseline. It does not promise to restore transient running/stopped states or reverse unrelated system changes.

Legacy scripts did not capture complete originals. Their recovery is therefore best effort, with backups and explicit error reporting. The app removes only recognized guardian names and matching command paths; custom names require manual review.
