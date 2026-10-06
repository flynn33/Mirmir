# Development diagnostics

Current source identity: **Mirmir 1.6.0 (16)**.

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

Routine collection keeps the information needed to identify a regression:

- One session identity record contains app/build, OS, architecture, and Metal
  device identity.
- Each durable job start or resume records job identity, source/output paths,
  requested and selected backend, geometry, codec, exact source cadence and
  duration, segment budget, and starting frame.
- Durable progress summaries record the first committed boundary, then at
  most once per minute, plus pause and terminal boundaries. They contain the
  committed frame/segment position, execution elapsed time, processing time,
  throughput, and accumulated source-authentication, segment-processing, and
  checkpoint-commit/working-cleanup durations. These timers bracket segment
  boundaries, not individual frames. Durations and completed frames cover the
  current execution after preparation; resume starts a new execution interval.
  Final assembly/publication is reported separately. The duplicate successful
  low-level checkpoint and commit
  events are omitted before field assembly or disk-space queries.
- While processing is active, process CPU, resident/physical memory, and
  cumulative disk I/O are recorded with the first CPU-bearing sample and then
  at most once per minute. The dashboard continues to refresh once per second;
  idle dashboard samples do not enter the journal. CPU counters are converted
  from Mach ticks to nanoseconds before calculating percentages. One fully
  occupied core corresponds to 100%. Each stored CPU percentage describes the
  latest sampling interval, not a minute average.
- Failures retain the detailed contract above; sparse success collection does
  not suppress checkpoint or publication errors. Final publication successes,
  lifecycle/control changes, and one sampling failure/recovery per outage
  remain available.

Successful progress records do not repeatedly collect disk-space or volume
identity. Failures still collect that context. This instrumentation does not
measure system-wide CPU usage, GPU utilization, or thermal state.

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

The store validates the complete journal when opening it and when its file
revision changes. Routine appends reuse the validated actor state and validate
only the new record. The existing exclusive journal lock serializes cooperating
processes. Descriptor-bound file revisions include identity, size, permissions,
and nanosecond modification/change times; a changed revision forces reload and
the existing corrupt-tail/privacy recovery. Failed or indeterminate writes and
retention rewrites invalidate cached authority. Adapters without revision
support always reload. External tools must take the journal lock before
modifying it; arbitrary concurrent writes that bypass the lock are unsupported.
The v1 journal schema, retention limits, privacy validation, durable writes,
and export UI remain in place.

## Verification

The 1.5.0 build-15 clean Debug scheme passed 594 tests with zero failures and
four existing opt-in skips. Clean Debug and universal Release logs contain no
errors or warnings; Xcode's Issue Navigator shows **No Issues**. The full-movie
throughput and packaged P06 provenance qualification remain separate checks.

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

The cache regressions verify unchanged-history reuse, interleaved stores,
same-size external credential edits, partial-tail recovery, stale read
revisions after replacement, and mutation between the revision check and
append open. Telemetry tests cover Mach time conversion, active-only minute
sampling, dashboard updates while idle, and sparse success records retaining
checkpoint failures.

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
