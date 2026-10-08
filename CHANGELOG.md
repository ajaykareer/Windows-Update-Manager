# Changelog

## 4.2.0 — Desktop preview

- Replaces the batch menu with a native dark WPF interface: overview, system details, activity, progress, diagnostics, explicit error/restart results and Hard Block confirmation.
- Adds a single EXE download that embeds the scripts, validates their SHA-256, extracts to a protected folder, and launches the GUI. Keeps a portable ZIP and console fallback.
- Adds Store Friendly mode for supported editions: manual automatic-update policy with shared Store dependencies available and no watchdog.
- Uses one Hard Block guardian task with startup and minute triggers instead of several independent watchdogs.
- Disarms state before removal, searches every task folder, retries deletion and verifies zero remaining known tasks.
- Migrates both the original repository's `WU-Guardian` names and the later `POS-WU-Guardian` names and command folders.
- Preserves a baseline across mode changes, restores original policy/service startup values, prevents concurrent operations, and attempts rollback on failed transitions.
- Adds local regression tests, GUI previews, package verification, and hosted Windows integration using temporary services and a real SYSTEM task.
- Documents limits: no universal update-blocking guarantee, unsigned EXE, legacy original settings cannot be reconstructed exactly, and real client/Store validation remains outstanding.

The original batch script remains available through Git history. Existing `WU-ManagerFinal.bat` users can use the same filename to launch the new interface after extracting the full package.
