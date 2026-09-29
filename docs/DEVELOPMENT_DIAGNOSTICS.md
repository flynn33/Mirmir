# Development diagnostics

Mirmir's development diagnostic system is the existing module at
`Mirmir/Modules/Diagnostics`. It owns one persistent journal,
`diagnostics-v1.jsonl`, and one operator export component that calls the
store's `exportJSON()` and `exportMarkdown()` methods.

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
- nested `NSError` type/domain/code frames plus permitted forensic `userInfo`.

Credential-shaped values, authorization fields, tokens, passwords, secrets,
and security bookmarks are rejected. Local development paths and ordinary
forensic error strings are retained intentionally.

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
  `finalize`.

Checkpoint commits and final publication record both success and failure.
Failure records take priority; periodic CPU, memory, and thermal sampling is
not written to this journal.

## Persistence and export

The development retention ceiling is 90 days, 50,000 records, 128 MiB total,
and 128 KiB per record. The export ceiling is 256 MiB. Corrupt-tail recovery,
rejections, pruning, retained bytes, and persistence failures remain visible in
the snapshot and operator UI.

The Diagnostics screen is the sole operator export implementation. JSON and
Markdown are rendered from the same snapshot and pass the same privacy
validation boundary.

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
  -only-testing:MirmirTests/MirmirDiagnosticStoreTests
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

The current development tree completed the full macOS Debug scheme with 522
tests: 519 passed, zero failed, and three expected opt-in capture tests skipped.
The result bundle is test evidence for this tree; it is not release or
large-media qualification.
