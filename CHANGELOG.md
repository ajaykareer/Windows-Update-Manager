# Changelog

## 4.3.0 — Verified blocking and task removal (preview, 2026-10-16)

- Keeps Hard Block with one SYSTEM watchdog and startup/minute triggers. Verifies its exact command, enabled triggers, identity and installed script, then requires a current-session task check before accepting a completed block.
- Rolls back a new block if task execution cannot be verified. Distinguishes restart-required changes from verified results.
- Adds live verification for policy, services, task configuration, script integrity and recent task checks. A saved mode alone no longer looks like proof of effective blocking.
- Makes **Unblock updates → Unblock & remove tasks** explicit. Removes known tasks across all folders, the installed watchdog script and its health record, while retaining recovery backups. Store Friendly also removes watchdog components.
- Adds real Windows integration coverage for task execution, nested task cleanup and preservation of unrelated tasks, plus regressions for stale/corrupt health, timeouts, service drift and changed scripts.
- Adds a release preflight requiring a valid timestamped publisher signature and a recorded Microsoft determination for the exact signed EXE hash. The public prerelease has not passed this preflight; the 4.2.2 detection remains unresolved. The maintainer requested publication of the unchanged candidate artifacts on 2026-10-16.

## 4.2.2 — Clear mode selection and Apply

- Replaces static mode cards with full-card radio controls: heading, description and padding all select the option.
- Separates the pending selection from the current Windows mode. Selection and cancellation never execute a controller action.
- Adds one action bar that stays visible in small windows, with a clear selected-mode label and explicit reasons when Apply is unavailable.
- Keeps selection during automatic status refreshes and supports reviewing choices with read-only access.
- Isolates the Hard Block confirmation from the underlying page and ignores duplicate confirmation events after it closes.
- Adds hit-target and accessibility-provider interaction tests plus updated screenshots and usage instructions. The controller's update/restore behavior is unchanged.

## 4.2.1 — Icon and publisher-signing preparation

- Adds an original update/pause icon with seven Windows icon sizes and a reusable 1024 pixel PNG; applies it to the EXE, window/taskbar icon, title bar and sidebar.
- Keeps the icon in the embedded and portable packages and adds copyright metadata.
- Adds an optional trusted-certificate signing helper with SHA-256, RFC 3161 timestamping, signature verification and refreshed release checksums.
- Explains UAC, SmartScreen reputation, antivirus detection and the vendor false-positive process. The release remains unsigned; no warning-free or antivirus-approved claim is made.
- Update-control, service and watchdog behavior is unchanged.

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
