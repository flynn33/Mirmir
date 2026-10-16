# Main-window lifecycle — 1.7.1 (19)

App Review rejected 1.7.0 (18) on October 15, 2026 because closing the main
window left no menu item for reopening it.

Choose **Window > Show Main Window** or press **Command-0** to reopen the
workspace after closing it. The same action brings the workspace forward when
it is already open. Closing the window leaves the application running.

`MirmirWindowCommands` in [`MirmirApp.swift`](../Mirmir/App/MirmirApp.swift)
uses `openWindow(id: "main", value: "main")`. The value-identified
`WindowGroup` uses the same default value so the command targets one workspace.
The app owns the shared view model for the process lifetime.

The workspace's automatic task calls `initializeWorkflowIfNeeded()`. After a
successful queue launch, recreating the view skips launch recovery and cleanup;
an initial launch failure remains retryable. The explicit `initializeWorkflow()`
path remains available for deliberate initialization.

## Verification — October 16, 2026

- `MirmirTests.testWindowMenuReopensClosedMainWindowWithoutCreatingDuplicates`
  passed in the native Release app host. It closes the actual window using
  `performClose`, invokes the real Window menu action, verifies the Command-0
  binding, repeats the action without creating duplicates, and restores the
  same minimized window. A separate foreground Debug-host run passed key-window
  focus checks. Background-host focus unavailability is recorded as a test
  activity.
- Version alignment passed `python3 script/update_version.py --check`; all nine
  version-tool tests passed. The development-signed universal Release app contains
  arm64 and x86_64, its bundle identifies as 1.7.1 (19), and it passed strict
  code-signature verification.
  Debug and universal Release app builds emitted zero compiler warnings/errors.
  This build does not establish a distribution archive, export, or notarization.
- Full native Debug passed **661 tests, zero failed, 13 skipped** (674 total).
  Full native Release passed **656 tests, zero failed, 13 skipped** (669 total).
  Both xcresults have empty runtime-warning lists, and both build/test logs
  contain zero compiler warnings/errors. Release testing used a separate
  test-enabled build; the universal production Release app remains non-testable.
- `MirmirTests.testAutomaticWorkflowInitializationDoesNotRelaunchWhenWindowReopens`
  and `MirmirTests.testAutomaticWorkflowInitializationRetriesAfterInitialFailure`
  passed in both suites, covering successful initialization reuse and retry
  after a failed initial queue launch.

Physical close-button, Command-W, and Command-0 input, an active export while
the window is closed, and the oldest supported macOS were not independently
exercised. The native test invokes the actual menu action programmatically.
These checks do not establish App Review acceptance. Upload and resubmission
remain owner actions.

## Reproduce the build and test checks

Use separate derived-data directories for test-enabled Release and the universal
app build:

```bash
xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/mirmir-window-debug test

xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Release \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -derivedDataPath /tmp/mirmir-window-release-tests ENABLE_TESTABILITY=YES test

xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Release \
  -destination 'generic/platform=macOS' ARCHS='arm64 x86_64' \
  ONLY_ACTIVE_ARCH=NO -derivedDataPath /tmp/mirmir-window-release-app build
```

The October 16 local evidence is retained under
`output/window-reopen-2026-10-16/`, including `debug-final.xcresult`,
`release-full.xcresult`, and their build/test logs. These are local run artifacts.

## Manual verification procedure

1. Launch the version-aligned application and confirm About reports 1.7.1 (19).
2. Close the main window with its close button; confirm the app remains active
   and its menu bar is available.
3. Choose **Window > Show Main Window**; confirm the workspace appears.
4. Repeat closing with Command-W and reopening with Command-0.
5. Invoke the action with the main window already visible; confirm it focuses
   the existing workspace without creating another main window.
6. Repeat the cycle and confirm existing inactive queue records remain
   available. If an active job is exercised, record that separately and verify
   progress while the window is closed.

Build, automated test, and native UI results must identify the tested artifact.
The existing deterministic-engine qualification gaps remain documented in
[current qualification status](v4/CURRENT_QUALIFICATION_STATUS.md).
