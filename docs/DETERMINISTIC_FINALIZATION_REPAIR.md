# Deterministic finish-stage repair — 1.7.0 (17)

The October 7 repair fixes the verified assembly and migration failures that
prevented a complete deterministic Metal job from publishing its movie. The
original installed 1.6.0 (16) app had completed **148,176 video frames and 2,470
segments**, then failed with `Mirmir.AVFoundationSegmentV4Error` 13. The saved
complete GPU output is now finalized and independently verified. The signed
universal **1.7.0 build 17** repair is installed and launched on the host.

## Verified mechanisms and changes

| Boundary | Observed failure | Production correction |
| --- | --- | --- |
| Durable video assembly | AVAssetReader exposed a sample duration changing from 3,753/90,000 to 3,754/90,000 after remuxing, while stored `stts`, adjacent DTS, PTS, and encoded bytes were unchanged. | `AVFoundationSegmentAssemblerV4.sampleTimingsMatch` applies the existing exact DTS-based duration rule to durable assembly. Terminal duration, timestamps, encoded payload, sync, order, and whole-asset duration remain verified. |
| Chapter metadata | The first chapter item's exact zero changed representation from 0/1 to 0/500, changing the raw fingerprint. | `canonicalChapterMetadataTime` reduces numeric chapter item times to exact rationals and retains flags and epoch. Asset metadata fingerprinting remains unchanged. |
| Audio stream timing | Core Media omitted individual DTS when one timing entry described several packets. Source and output reader grouping differed. | `SampleStreamAccumulatorV4` reconstructs omitted audio DTS only from a declared exact uniform multi-packet timing entry with a matching individual PTS/duration grid. Numeric DTS remains bound; rounded, overflowing, or contradictory clocks fail. |
| AC3 format identity | ISO and MOV descriptions exposed different container wrappers despite identical ASBD, complete 11-byte `dac3` cookie, channel layout, and encoded audio. | `canonicalSampleStreamFormatDescriptor` normalizes only that complete AC3 wrapper configuration. Acceptance also requires complete encoded-stream equality and exact normalized descriptor inventories. Durable graph and plan identities retain their original representation. |
| Audio track names | AVAssetWriter dropped both raw ISO `uiso/name` items containing UTF-8 audio names; direct metadata copy and header rewrite did not retain them. | `migratedTrackMetadataItems` converts only a known raw ISO name with exact, round-tripping UTF-8 bytes to MOV's typed `udta/tnam` track name and declares unspecified metadata language as `und`. Reopened metadata must exactly match the converted source before restoring its frozen logical fingerprint. Missing, changed, additional, invalid UTF-8, or differently tagged data remains rejected. |

The changes use the existing assembler, migration adapter/executor, and
diagnostics recorder. No additional diagnostics system or permissive fallback
was added. The production files are:

- [AVFoundationSegmentAssemblerV4.swift](../Mirmir/MediaIO/AVFoundationSegmentAssemblerV4.swift)
- [AVFoundationTrackGraphAdapterV4.swift](../Mirmir/MediaIO/AVFoundationTrackGraphAdapterV4.swift)
- [AVFoundationTrackMigrationExecutorV4.swift](../Mirmir/MediaIO/AVFoundationTrackMigrationExecutorV4.swift)

## Verification

The original final-two-segment replay reproduced error 13; the repaired replay
passed. Complete assembly then verified all 148,176 concrete video frames and
the exact 556,215,660/90,000 endpoint against all 2,470 saved segments.

The opt-in `testSavedCompleteCheckpointFinalizesAllTracksWhenRequested` passed
normal production finalization and completion inspection in **266.697
seconds**, accepting the original plan and runtime binding unchanged. All
four source/output stream identities, asset metadata, chapter metadata, and
semantic verification passed. It published the complete 3840×1632 HEVC movie.

Independent verification read the published movie directly. It compared every
one of **148,176 video packets, 289,696 AAC packets, 193,130 AC3 packets, and
14 chapter samples**, including encoded bytes, stored clocks, edits, and the
two audio names. Complete decoded PCM equality passed for both audio tracks.
Native frame extraction succeeded at beginning, middle, and end; all 14
chapters were readable. QuickTime opened the output and displayed a decoded
scene after seeking.

The final repair's normal My Mac Debug suite passed **658 tests, zero failed,
12 explicit opt-in skips**, with no reported runtime warnings. The complete
migration suite separately passed **102 of 102**, with no skips or reported
runtime warnings. Fresh publication native Release passed **653 tests, zero
failed, 13 opt-in skips**, with no reported runtime warnings in an isolated
signed host using the final project's warnings-as-errors settings. These
passing tests retain the earlier decoded H.264 parity incident as a separate
unknown cause. Positive and negative cases cover duration/timestamp
mutations, chapter flags/epochs, audio grouping and timing changes, AC3
configuration/inventory changes, missing/changed metadata, and invalid UTF-8.
A real short raw ISO-name MP4-to-MOV regression verifies native name retention
through the production executor. Tests are in
[WorkflowSegmentCheckpointStoreV4Tests.swift](../MirmirTests/WorkflowSegmentCheckpointStoreV4Tests.swift)
and [AVFoundationTrackMigrationExecutorV4Tests.swift](../MirmirTests/AVFoundationTrackMigrationExecutorV4Tests.swift).

The universal Release build succeeded with warnings treated as errors and
zero compiler warnings/errors. It contains arm64 and x86_64, retains
`com.mirmir.app`, and passes strict signature verification under the owner's
Developer ID identity. The installed executable matches that signed repair
build. Native UI readback confirms **Version 1.7.0 · Build 17**, an idle queue,
and the Apple M4 Pro Metal route ready.

The [portable evidence receipt](v4/evidence/end-finalization-repair-2026-10-07/README.md)
contains exact source/build/output hashes and counts without private media,
host paths, or device identifiers. Raw diagnostic exports, result bundles,
movie files, and app/cache backups remain local.

## Scope and retained boundaries

Recovery reused the completed GPU cache; it did not repeat the entire GPU
processing stage. The original source, checkpoint, and request hashes are
unchanged. The historical queue record remains contained and its lifecycle was
not rewritten to claim a normal UI completion.

A fresh full GPU render, matched whole-movie throughput, continuous playback,
and audible speaker playback were not exercised. At this historical checkpoint,
the separate intermittent Release decoded H.264 parity cause and packaged runtime
source-closure gate
remained open. The later [October 24 final QA](FINAL_QA_2026-10-24.md) records
their reproduction, repair, and current acceptance gaps. This repair does not
change the sealed M7 simulator decision or claim a new whole-movie speedup.
