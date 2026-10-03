# Development diagnostics

Mirmir's development diagnostic system is the existing module at
`Mirmir/Modules/Diagnostics`. It owns one persistent journal,
`diagnostics-v1.jsonl`, and one operator export component that calls the
store's `exportJSON()`, `exportMarkdown()`, and `exportApplicationLogs()`
methods.

This document describes development instrumentation. It does not define the
eventual shipping telemetry or privacy policy, and it does not establish
release, notarization, upload, installation, or distribution status.

## Failure contract

Processing, checkpoint, and publication failures retain the context needed to
locate the failing operation without reconstructing it from unrelated logs:

- job, workflow, queue-item, session, sequence, wall-clock, and uptime identity;
- requested backend, backend actually selected, and whether fallback occurred;
- source, requested, and effective geometry;
- source/effective pixel formats, codec, color metadata, dynamic range, and HDR;
- nominal frame duration, sample index, observed and expected presentation
  timestamps and durations, including their exact values and timescales;
- exact rational boundary, admitted track boundary, and declared boundary clock
  when an incommensurate value is rejected at site 057;
- stable `dv4_timing_*` identifiers and the error-16 timing values;
- next input sample, segment ordinal/count, completion, checkpoint schema,
  publication attempt, and atomic-publication failure;
- errno, free bytes, mount path, and volume UUID for destination and checkpoint
  volumes;
- opened audio-track count, codecs, alternate-group flags, and drain mode;
- distinct cancellation, ENOSPC, geometry-rejection, timing, atomic-publication,
  and general-processing failure codes;
- raw development source/output/checkpoint paths;
- file, function, and line of the record site; and
- nested `NSError` type/domain/code frames, privacy-permitted localized
  descriptions and forensic `userInfo`, plus the count omitted by privacy and
  size bounds.

Credential-shaped values, authorization fields, tokens, passwords, secrets,
and security bookmarks are rejected. Local development paths and ordinary
forensic error strings are retained intentionally.
When `NSError.userInfo` has no localized description, the recorder supplies
`error.localizedDescription` before applying the same privacy validation. This
keeps associated Swift failure reasons such as output-finalization detail.

## Production emission sites

The existing store is reached through `MirmirDiagnosticScope.recorder`. Its
default value is the application recorder backed by
`MirmirDiagnosticStore.application`; tests may bind the same production path to
an isolated existing store.

Current production emission boundaries are:

- `VideoProcessingSession.process` for conventional/top-level processing;
- `DeterministicV4MediaProcessingSession.processSegment` for segment failure;
- `validateNominalDecodedCadence` for the exact off-lattice error-16 site;
- `AtomicOutputFile.publish` for atomic output failures;
- `WorkflowSegmentCheckpointStoreV4.publishBoundary`;
- `WorkflowDurableCoordinatorV4.commitCheckpoint`; and
- `WorkflowApplicationCoordinatorV4.runNext`, `continueProcessing`, and
  `finalize`;
- `MirmirViewModel` operational boundaries for source probing, durable-workflow
  launch and queue actions, cache management, model download, and direct or
  durable processing failures that otherwise only reach the UI.

The workspace view model binds its recorder to the injected diagnostic store
while it calls the processing and durable-workflow layers. Its boundary events
therefore reach the same journal shown by the Diagnostics page. User-requested
cancellation is excluded from failure records.

Checkpoint commits and final publication record both success and failure.
Failure records take priority. The production workspace records bounded
process CPU, resident and physical memory, cumulative disk I/O, and Metal
device identity for the first two successful samples and every 30 successful
one-second samples after that. The second sample includes the first CPU delta.
A sampling failure and its recovery are recorded once per outage. This does
not measure system-wide CPU usage or thermal state.

## Persistence and export

The development retention ceiling is 90 days, 50,000 records, 128 MiB total,
and 128 KiB per record. The export ceiling is 256 MiB. Corrupt-tail recovery,
rejections, pruning, retained bytes, and persistence failures remain visible in
the snapshot and operator UI. Each application-store session begins with a
v1-compatible `diagnostic_session_started` record containing the application
name/version/build, bundle identifier, OS version/build, architecture, process
name/ID, non-identifying Metal device name when available, and the diagnostic
session UUID. Retention keeps the identity record for every session that still
has retained records.

The production workspace's **Diagnostics** sidebar page shows the existing
journal and offers three export controls. Each control opens a native save
panel and calls the existing in-place diagnostic component:

- **JSON…** (`Command-Shift-J`) writes the persistent journal as JSON;
- **Markdown…** (`Command-Shift-M`) writes the same journal snapshot as a
  human-readable report; and
- **App Logs…** (`Command-Shift-L`) writes the current process's available
  unified logs as JSON.

The keyboard shortcuts invoke the same actions as the visible controls. JSON
and Markdown are rendered from the same journal snapshot. App Logs uses
`OSLogStore` for the unified log entries still available to the running Mirmir
process. Its export states its scope, retained count, omitted private count,
app version/build, OS, architecture, process/thread/activity identity, log or
signpost metadata, and separate omission counts for privacy, message size,
unsupported entries, entry limit, and byte limit. The export is capped at
50,000 retained entries, 16 KiB per message, and 64 MiB encoded. All three
exports pass credential validation. Enumeration stops after 100,000 inspected
entries plus one truncation probe and reports that the omitted count is a lower
bound. Unified logs can be redacted or discarded by macOS; the journal is the
durable record of instrumented failures across process launches. App Logs and
the journal exports carry the same `diagnostic_session_id`, which provides an
explicit join key for the current process. Older journal sessions retain their
own start record and runtime identity.

## Verification

Run the diagnostic tests alone with:

```bash
xcodebuild \
  -project Mirmir.xcodeproj \
  -scheme Mirmir \
  -configuration Debug \
  -destination 'platform=macOS' \
  test \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:MirmirTests/MirmirDiagnosticStoreTests \
  -only-testing:MirmirTests/MirmirDashboardTelemetryTests \
  -only-testing:MirmirTests/MirmirTests
```

`testProductionCadenceValidatorSubmitsFailureToInjectedStore` calls the
production cadence validator, forces the production off-lattice branch, waits
for the normal submission queue through `snapshot()`, and verifies the record
and export. `testAtomicOutputPublishSubmitsMissingTemporaryFailureToInjectedStore`
calls `AtomicOutputFile.publish()` with its production temporary file absent
and verifies the publication failure reached the same store. The remaining
diagnostic tests cover v1 persistence, both export formats, exact timing
rationals, ENOSPC nested errors and durable state, source locations,
development paths, and credential rejection.

`testProductionCadenceValidatorSubmitsFailureWithoutProcessingContext` calls
the same production validator without a task-local processing context and
verifies that its timing site and operation still reach the store while absent
job/workflow/queue fields remain absent.
`testFinalizeFailureRecorderExportsDurableCheckpointPath` calls the production
finalize recorder and verifies that JSON export retains the durable job's
non-empty checkpoint-head path and the `finalize` operation.

`testLiveProcessTelemetryReachesTheExportedJournal` verifies that process
samples reach JSON export. `testCurrentProcessUnifiedLogsExportAsValidatedJSON`
exercises the live macOS log export when it is available to the test process.
Injected log/signpost tests require populated entries and cover metadata,
credential filtering, omission accounting, the scan and encoded byte ceilings,
and continued journal recording while a log export is blocked.
`testLocalizedErrorDescriptionSurvivesJSONAndMarkdownExport` verifies that a
Swift output-finalization reason survives both journal exports, while
`testCredentialBearingLocalizedErrorDescriptionIsOmitted` verifies fail-closed
privacy filtering and omission accounting.

For the shared clock-policy repair, the loaded short video was checked directly
with AVFoundation: 241 decoded frames, last PTS `122880/12288`, and video track
end `123396/12288`. The exact nominal decoded end is `123392/12288`. The named
asset regression verifies that this exactly representable value remains exact
even when the independently observed container boundary differs. Separate
diagnostic tests use an incommensurate rational and a nonadjacent admitted
boundary to verify site 057 and its exact/admitted/clock fields.

Terminal sample completeness is reported by the durable coordinator, rather
than by site 057. Its independent source inventory requires the terminal
decoded ordinal to account for every encoded primary-video sample before
finalization.
