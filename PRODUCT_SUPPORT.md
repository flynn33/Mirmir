# Mirmir product support

Current source identity: **Mirmir 1.7.2 (20)**. Release clearance remains on hold;
see [the current continuation](docs/QA_FOLLOWUP_2026-10-25.md). The completed
runtime8 native baseline passes all selected non-UI suites: Release 745, Debug
750, Rosetta 745 and macOS 15.4 745, each with zero failures and 13 opt-in skips.
All 404 Python checks and the local universal archive audit pass. The runtime7
fresh 90-minute production export passes full independent frame, exact-clock
and byte-exact audio verification. Additional targeted oracles found chroma
calibration and physical alignment defects; their fixes, broad-format
integration and richer audio/metadata handling remain unfinished. These suite
passes do not qualify those features or authorize release.
New local download-lifecycle repairs pass actual fresh-VM clear/retry and
network-failure/retry controls. File selection permits content validation when
a common container has no registered movie UTI. New vImage/MPS chroma and
odd-input preview findings remain release blockers; these are functional media
checks performed from terminal without opening a panel or viewing the screen.
The historical October 7, 2026 readback verifies the signed universal
**1.7.0 (17)** repair installed and launched, with its exact executable,
strict signature, native About
version/build, and idle Metal route confirmed. Earlier installed-version
checks are historical. Source publication and binary distribution remain
separate actions.

The retained 1.7.0 beta evidence has exact serial/parallel spatial-stage parity
and an isolated 8.91× spatial speedup at 3840×1632. Its version-aligned Debug and
Release suites passed, while an earlier strict decoded H.264 parity incident
remains unexplained. The October 24 source-identity repair is recorded separately.
See [known issues](KNOWN_ISSUES.md) and
[current qualification](docs/v4/CURRENT_QUALIFICATION_STATUS.md).

The finish-stage repair fully finalized a complete saved deterministic Metal
job and independently verified all **148,176 video frames, two audio tracks,
both audio names, and 14 chapters** at 3840×1632. The normal repair Debug suite
passed 658 tests with zero failures and 12 explicit opt-in skips; the complete
migration suite passed 102 of 102. Fresh publication Release passed 653 tests
with zero failures, 13 opt-in skips, and no reported runtime warnings.
Recovery reused completed GPU frames rather
than repeating the full GPU processing stage. See
[repair details](docs/DETERMINISTIC_FINALIZATION_REPAIR.md).

Mirmir is a sandboxed macOS 15.4-or-later application. It reads local media
through security-scoped bookmarks, builds an explicit whole-asset plan, and
publishes a semantically verified QuickTime movie atomically. An explicit
backend selection is never replaced by a different scaler after failure.

## Input admission

The current implementation uses native decoding plus a verified AVI sample-entry
projection for the supported FMP4/H264 cases. This still leaves common input
failures; broad input support is a required release repair. A filename extension
alone is not authoritative. Verified RIFF/AVI content supplies the public MIME
override when needed, including AVI bytes stored under a `.mov` name.

Omitted color tags are resolved from an actual decoded frame; explicit tags are
preserved. H.264/HEVC use their defined video-range default when the range flag
is absent. ProRes 422 uses the declared 10-bit P010 decode conversion; this
converts 4:2:2 chroma to the engine's 4:2:0 working surface. Unknown or
contradictory declarations still fail with an explanation.

Supported MPEG-4 Part 2 and JFIF Motion JPEG 4:2:0 sampling comes from bitstream
headers. MPEG-4 MOV/MP4, Motion JPEG MOV/AVI and the supported FMP4/H264 AVI
fixtures complete production exports. The new AVI projection retains original
packet payloads, PCM and exact track ends, with H264 presentation order derived
from its bitstream. Its initial verified contract admits progressive H264 POC0
and MPEG4 I/P pictures with one video and optional PCM audio; other POC/field
modes, MPEG4 ASP B/S decoding and richer AVI metadata remain open compatibility
work. MKV, WebM, ASF, MJPEG 4:2:2/4:4:4 and MPEG2 transport streams also require
production repairs and completed output verification. See
[the QA report](docs/FINAL_QA_2026-10-24.md).

## Implemented backends

| Backend | Current contract |
| --- | --- |
| Mirmir Deterministic — CPU Reference | Explicit ASH P06 selection. Shared fixed-point spatial and temporal reconstruction, arbitrary integral upscale geometry, supported opaque and alpha formats, verified runtime assets, and no Apple fallback. CPU loading authenticates Metal artifact bytes without requiring a Metal device or executable library. |
| Mirmir Deterministic — Metal Accelerated | Explicit ASH P06 selection. Executes the same canonical plan, coefficient tables, rounding, clamps, and temporal policy as CPU; preparation fails closed if the bundled runtime or Metal library does not verify. It never substitutes CPU execution. |
| VideoToolbox Super Resolution — Quality | macOS 26 or later, dimensions/factors reported by the current API, and an explicit system-model download when VideoToolbox reports it is required. |
| VideoToolbox Super Resolution — Low Latency | macOS 26 or later and only dimensions/factors/pixel formats accepted by the current API. |
| VideoToolbox Smooth Motion + Spatial Upscale | macOS 26 or later, 2× spatial scale, the API-supported midpoint phase, and source geometry admitted by `VTLowLatencyFrameInterpolationConfiguration` for that Mac. The reported source-frame limits are independent of display resolution. The route produces 2× cadence without changing normal playback duration; the first reference uses a disclosed VideoToolbox pixel-transfer boundary scale. |
| MetalFX Spatial | MetalFX-capable GPU, video-range 8-bit NV12, and explicit BT.709 primaries/transfer/matrix. Uses an audited NV12 ↔ linear RGBA16Float bridge. |
| MPS Lanczos / Bilinear | Metal Performance Shaders with progressive SDR 8-bit NV12 and explicit range. |
| Core Image Lanczos / Bicubic | Progressive SDR 8-bit NV12 with explicit range. This is a filter conversion/resampling path, not code-value preservation. |
| Accelerate/vImage High Quality / Standard | Progressive SDR 8-bit NV12 with explicit video/full range. |
| VideoToolbox Pixel Transfer | Progressive SDR 8-bit NV12 with explicit range. |

Automatic uses one fixed documented order and considers spatial-only Apple
backends. It excludes both Deterministic routes and Smooth Motion.
Consequently, Automatic does not select deterministic v4 for opaque H.264
input.

Opaque HEVC, H.264 and ProRes 422 output requires even encoded width and height.
The view model and writer contract enforce this before publication. ProRes 4444
alpha permits odd dimensions: resumed QA completed a 160×96 to 321×193 production
workflow and independently decoded all 72 frames with alpha-capable output.

## Timing correction and large-media boundary

Mirmir reconstructs nominal presentation timestamps from exact frame ordinal
and cadence. The shared conversion policy returns an exactly representable
value before considering an independently observed boundary. When the exact
rational is incommensurate with the required clock, only its independently
admitted immediate floor or ceiling tick is allowed; every nonadjacent boundary
still fails under forensic site 057.

Source completeness is a separate durable-workflow invariant. The coordinator
inventories encoded samples from the primary video track and requires the
terminal decoded ordinal to account for the full inventory before a terminal
checkpoint or interrupted-publication recovery can finalize output. A missing
source sample therefore fails independently of clock-boundary admission.

The historical original 1:43 Ferris job is not completion evidence. Checkpoint
ordinal 2,468 contains 2,469 committed 60-frame segments and records the video
`nextInputSampleIndex` as 148,140. The source contains 148,176 frames, leaving a
36-frame terminal remainder where the installed build failed at site 054. The
approximately 91 GB job directory was removed in the owner-authorized October 1
cache cleanup. That older cache is separate from the later complete job used
for the October 7 finish-stage repair.

The later job completed all 148,176 GPU frames and 2,470 segments, then failed
at final assembly/migration. The repaired production path finalized that saved
job, accepted its original plan/runtime binding unchanged, and published a
complete movie with every video/audio/chapter packet and stored clock/edit
verified. Complete decoded audio PCM also matches the original. Original
source, checkpoint, request, cache, and app backups remain preserved; the
historical queue entry remains contained. A fresh full GPU render and matched
whole-movie throughput remain separate DV4-002 qualification work.

On October 3, the reported short source at
`/Users/jimdaley/Mirmir/Mirmir-In/raven-forge-app-splash-2.mp4` completed the
production durable workflow. Independent postvalidation passed 66 of 66 checks
and found 241 video frames and 470 audio packets in both the source and output.
The output is
`/Users/jimdaley/Desktop/Mirmir-1.4.3-Build12-Evidence/83-final-real-source-production-1024-green/durable-workflow-run/durable-workflow-output.mov`.
This historical 1.4.3 short-source result does not complete DV4-002 or qualify
the current 1.7.2 source or a later installed application.

VideoToolbox methods fail closed when the exact source, target, or scale
geometry is unsupported. Automatic pre-scale and post-scale geometry
adaptation is a post-first-release enhancement, not part of the version 1.4.0
contract. Deterministic resource allocation is likewise outside the
first-release target. These accepted boundaries and follow-up work are tracked
in [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md).

## Upscale and Compare surfaces

- **Window > Show Main Window** (**Command-0**) reopens the workspace after
  closing it or brings it forward when already open. Closing the window leaves
  the application running. See [window lifecycle](docs/WINDOW_LIFECYCLE.md) for
  verification status.
- Upscale is the job workspace. It owns source selection, processing method,
  output settings, queue controls, and a live sampled processing preview. It
  does not mount the completed split player or require a completed movie.
- Compare is an independent primary destination. Original and Upscaled pickers
  accept any two readable movies, while Use Last Completed Job fills both URLs
  from the current completed job when available.
- Compare provides synchronized play, pause, replay, shared scrubbing, and a
  draggable split. It plays one audio stream, defaulting to the Upscaled file,
  and distinguishes empty, loading, ready, ended, and failure states.

## Deterministic ASH P06 contract

- The bundled P06 manifest authenticates the measurement contract, ASH branch
  program/operator controls, fixed-point kernel and Metal library, algebra
  certificate, quality and benchmark corpus identities, builder provenance,
  and production-source revision. Missing, stale, or modified assets cannot
  prepare an engine.
- Target width and height may use independent rational scale factors. Both axes
  must be at least the source raster, and the canonical executor limit is
  32,768 samples per axis.
- Opaque input supports video-range and full-range 8-bit bi-planar NV12 and
  10-bit bi-planar P010. HDR remains 10-bit end to end; there is no implicit
  SDR conversion or tone map. Legal decoded video-range footroom and headroom
  reach the spatial kernel; bounded ASH measurement inputs clamp to nominal
  signal limits, output clamps once under the shared kernel contract, and
  malformed P010 low bits remain rejected.
- Progressive input and explicitly identified top-field-first or
  bottom-field-first interlaced input are supported. Interlaced frames produce
  two deterministic progressive output samples, with cadence/dominance changes
  resetting incompatible temporal evidence.
- Straight and premultiplied packed-alpha input is resolved in a typed straight
  domain and reassociated after scaling. BGRA8 and big-endian ARGB16 working
  layouts are supported. Exact decoded alpha verification uses ProRes 4444 or
  ProRes 4444 XQ; HEVC-with-alpha remains a codec-dependent, non-byte-exact
  alpha option.
- Sample aspect ratio, clean aperture, preferred transform, and encoded raster
  scale are composed with rational arithmetic. Representations that cannot be
  emitted exactly are rejected rather than rounded silently.
- State-conditioned spatial reconstruction precedes block-matched temporal
  reconstruction from one retained output frame. Measurement hysteresis keeps
  only its canonical 32×32 Q16 window and one prior source-luma frame; no unused
  full-frame history is retained. Scene cuts, seeks, discontinuities, format or
  color changes, field-cadence changes, and dynamic HDR frame metadata trigger
  the declared spatial fallback/reset behavior.
- Spatial conditioning uses bounded, disjoint CPU row stripes on both routes
  for planes with at least 262,144 samples, capped by height and active
  processor count. Immutable boundary rows preserve the serial stencil;
  smaller planes use the serial path. Frame history and durable commits remain
  ordered. This does not move conditioning or motion search onto the GPU. See
  [spatial parallelism](docs/DETERMINISTIC_SPATIAL_PARALLELISM.md).
- CPU and Metal consume one fixed-point semantic contract. Release evidence
  requires byte equality for visible output planes across NV12, P010, arbitrary
  geometry, temporal, interlaced, and alpha conformance cases.

## Long-running deterministic jobs and diagnostics

Version 1.5.0 reuses validated diagnostic history while the journal's file
revision is unchanged. A changed journal or uncertain write requires a fresh
validated load. New records still undergo privacy validation and durable
append under the cross-process lock; existing history and export formats remain
compatible.

Successful progress is recorded at the first committed boundary, at minute
intervals, and when processing pauses or completes. Duplicate successful
checkpoint notices are omitted. Job start/resume records carry source and
request details; progress records carry elapsed time, frame rate, and cumulative
source-authentication, segment-processing, and checkpoint-commit time. Errors
retain detailed diagnostics. The live dashboard still refreshes each second,
while persistent process samples are collected at minute intervals during
active work. CPU percentages now convert Mach counters to time before computing
the rate.

The deterministic scaler skips redundant representability checks for 8-bit
NV12 and uses a visible-row alignment scan for P010. Invalid P010 input still
reports the first malformed component before any destination bytes change.
CPU and Metal retain the same pixel contract.

Each deterministic segment still authenticates the entire private source
snapshot with SHA-256. Version 1.5.0 removes an intermediate copy from each hash
buffer; it does not eliminate the full-source read. The isolated append and
scaler measurements are recorded in
[`docs/v4/CURRENT_QUALIFICATION_STATUS.md`](docs/v4/CURRENT_QUALIFICATION_STATUS.md).
A completed full-length job is still required to establish end-to-end speed.

## Media and track preservation

- Output is a `.mov` file. Opaque video supports HEVC, H.264, and Apple ProRes
  422. Alpha delivery uses an alpha-capable codec contract, including Apple
  ProRes 4444/4444 XQ.
- Every enabled video track receives an ordered, explicit process, transcode,
  pass-through, or consent-bound drop action. There is no implicit
  “first-video-track only” rule.
- When audio preservation is enabled, every source audio track receives a
  non-drop plan action in both conventional and Deterministic v4 jobs.
  Compatible audio passes through; incompatible audio is decoded and encoded
  as AAC under the declared transcode action. Alternate audio, subtitles,
  captions, chapters, timecode, timed metadata, and auxiliary tracks remain
  represented in the migration plan; unsupported loss cannot be hidden as a
  successful migration.
- Attached-picture preservation is currently provided by the deterministic v4
  whole-asset migration path. Conventional backends do not preserve attached
  pictures.
- AAC semantic comparison binds the stream description, codec magic cookie,
  channel layout, and remaining extensions while normalizing only the
  independently redundant MP4-versus-MOV sample-entry wrapper. Unknown or
  incomplete compressed formats retain their wrapper and fail closed.
- Track ordering, enabled state, language, role/association, edit lists, sample
  timing, format transitions, asset metadata, creation date, and compatible
  selection groups are migrated and checked by the semantic verifier. Scaled
  edit rates are rebuilt into the output media-time table.
- Conventional audio tracks are drained serially from their shared asset
  reader. Output validation compares audio count and identity-bearing topology,
  including language, enabled/default state, and alternate-group membership.
- HDR mastering-display, content-light, ambient-viewing, static color, and
  frame-bound dynamic metadata are carried under typed contracts and verified
  after reopening the output.
- Existing destinations require explicit replacement. Work is written to
  registered sibling artifacts, validated, and linked into place atomically.

## Durable workflow and recovery

- The deterministic batch queue is append-only, snapshot-backed, ordered, and
  durable across application restarts. Records bind the canonical request,
  verified plan/runtime identities, priority, attempts, bookmarks, terminal
  history, and registered artifacts.
- A user-selected regular source may have multiple hard links. Admission still
  uses a no-follow descriptor, verifies the descriptor against the selected
  path before and after copying, and hashes the copied bytes. The resulting
  queue-owned private snapshot must remain a single-link regular file.
- Pause closes a deterministic segment boundary and persists media progress,
  ASH measurement/hysteresis state, temporal history, alpha state, and track
  checkpoints. Resume revalidates input identity and plan/runtime compatibility
  before continuing; cancellation remains a distinct terminal action.
- A failed job may re-enter recovery only when its last checkpoint is
  authenticated, nonterminal, compatible with the bound request, and contains
  one incomplete video progress record. The queue discards only an
  uncommitted next-boundary artifact and continues after the last committed
  segment.
- Launch recovery scans durable records and registered/legacy partial files.
  Compatible jobs become resumable, confirmed orphans are removed, and corrupt
  or foreign artifacts are quarantined or reported rather than adopted.
- Canonical migrations cover older queue, journal, coordinator, dispatcher,
  recovery-decision, artifact-registry, bookmark, and checkpoint documents.
  Interrupted writes, disk-full failures, and faults at durable boundaries are
  required to produce either an identical resumed result or an explicit
  contained failure with no unowned artifact.
- New queue snapshots preserve and authenticate the exact source basename used
  during planning. A verified legacy snapshot that recorded only the old
  generic `source[.<ext>]` name is failed before dispatch with re-enqueue
  guidance; its checkpoints are never reused implicitly.
- Queue drain checks for eligible work before acquiring a global dispatcher
  slot. A controller that has just received a durable paused outcome can be
  recreated and resume immediately without contending with an idle drain pass.

## Cache location and deletion

- Settings shows the current durable workflow-cache path and the number of
  finished and unfinished jobs stored there.
- **Choose Location…** stores a security-scoped bookmark for a selected local
  folder, mounted drive, or mounted network share. Mirmir uses exactly one
  active workflow root at a time under the selected folder's
  `Mirmir/WorkflowV4` directory.
- Cache locations cannot be changed while the current cache contains jobs.
  Settings states that the jobs must be deleted first; Mirmir never silently
  migrates or abandons them.
- If a custom root is unavailable or its bookmark cannot be reopened, Settings
  continues to expose **Choose Location…** and **Use Internal Storage**. Returning
  to internal Application Support does not delete or migrate the unavailable
  root.
- Queue-row deletion and the bulk **Delete Finished Jobs…**, **Delete Unfinished
  Jobs…**, and **Clear Cache…** actions require confirmation. Queued, paused,
  contained, completed, failed, safe-halt, and cancelled jobs may be removed.
  Probing, planned, running, pausing, verifying, committing, and recovering jobs
  are rejected until they become paused or cancelled.
- Version 1.4.2 presents these confirmations from one workspace owner. The
  confirmed action awaits durable cleanup, reads back the queue, and enables
  **Choose Location…** after the last job is gone. A reinstall retains the
  sandbox cache until it is explicitly cleared.
- Deletion is confined to the validated queue-owned `jobs/<job-id>` directory
  and recognized `.mirmir-job-*` working artifacts. Output destinations are
  external to those namespaces and are never deletion targets.

## Boundaries

- Deterministic v4 is an upscaler; downscaling either axis is outside its
  product contract.
- Unknown range, transfer, field dominance, alpha association, pixel layout,
  or contradictory media declarations fail availability checks explicitly.
- Packed-alpha interlaced normalization is not admitted because its association
  and field-temporal policy would be ambiguous.
- Apple-native backends retain the narrower contracts in the table above; they
  do not inherit P010/HDR, alpha, deinterlacing, or fixed-point parity merely
  because the Deterministic engine supports them.
- Deterministic resource allocation is not a version 1.4.0 first-release
  target.
- Deterministic clock conversion returns exact values directly. An
  incommensurate value can use only an independently admitted adjacent clock
  tick. Error 16 (`invalidSampleTiming`) diagnostics carry stable site
  identifiers 053–057 for numeric, exact-representation,
  rational-denominator, admitted-boundary, and nonadjacent failures. Terminal
  source-sample completeness is checked separately before finalization.
- The installed `/Applications/Mirmir.app` reports 1.4.5 build 14 as checked on
  October 4. This source update has not replaced it or rechecked its cache
  confirmation behavior. The historical Ferris job was not resumed;
  its cached checkpoint, segments, and recovery lock were removed during the
  owner-authorized October 1 cache clear.

## Qualification boundary

Version 1.5.0 build-15 qualification results are recorded in
[`docs/v4/CURRENT_QUALIFICATION_STATUS.md`](docs/v4/CURRENT_QUALIFICATION_STATUS.md).
The earlier results below retain their original version and evidence scope.

The historical 1.4.3 build-12 named site-057 regression passed 1 of 1. Its full
Debug scheme completed 590 tests: 586 passed, zero failed, and four explicit
opt-in tests skipped. Repository Python contracts passed 388 of 388 tests
across 27 of 27 commands. Release analysis with `ARCHS=arm64 x86_64` and
`ONLY_ACTIVE_ARCH=NO` succeeded and emitted both architectures.

The built 1.4.3 (12) application used the visible Diagnostics controls and
native save panels to create validated journal JSON, journal Markdown, and
unified-log JSON files under
`/Users/jimdaley/Desktop/Mirmir-1.4.3-Build12-Evidence/`. Application archiving
and distribution are outside this source qualification.

Version 1.4.1 qualification includes the named timing-policy, deterministic
segment, conventional video/audio, assembly, canonical-media, and durable
workflow test classes recorded in the release evidence. A successful test run
does not establish a completed Ferris output.

M0 through M6 are implemented and covered by the repository’s deterministic,
media, workflow, and recovery tests. M7 is a headless frame-simulator comparison
of five policy candidates against frozen P05. The sealed 168-case run from
commit `ce780af87107d90142d860f328dca4a72fea3047` selected `candidate_v4`.
It measured a 22.792052% quality increase with a 22.312761% paired-bootstrap
lower bound, plus a 97.478689% reduction in total engine time; median and p95
ratios also passed the 0.80 limit. This completes M7 in its declared simulator
scope.

M7 does not require a physical-machine matrix, signing, notarization, stapling,
shipping, or distribution. Those are separate owner decisions and are not
implied by simulator qualification. See
[`docs/v4/CURRENT_QUALIFICATION_STATUS.md`](docs/v4/CURRENT_QUALIFICATION_STATUS.md)
for the exact evidence boundary.

The historical build 7 macOS Debug suite completed 500 tests: 497 passed, zero
failed, and three expected opt-in capture tests skipped. The fresh version
1.4.1 build 10 full serial macOS Debug scheme completed 540 tests: 537 passed,
zero failed, and three expected opt-in capture tests skipped. The 1.4.2
fixture tests passed for finished, unfinished, row, and Clear Cache actions
with completed, failed, cancelled, paused, and contained jobs. The full 1.4.2
build-11 Debug result bundle reports 543 total tests: 540 passed, zero failed,
and three expected opt-in capture tests skipped. The historical local Apple
Distribution archive for 1.4.2 build 11 was prepared for owner handoff only at
`/Users/jimdaley/Library/Developer/Xcode/Archives/2026-10-01/Mirmir-1.4.2-11-TestFlight.xcarchive`;
the historical 1.4.1 build-10 owner-handoff archive remains at
`/Users/jimdaley/Library/Developer/Xcode/Archives/2026-09-30/Mirmir-1.4.1-10-TestFlight.xcarchive`;
neither historical archive is in Git, and neither was uploaded, submitted,
distributed, released, or installed. The owner-authorized live
cache clear removed all 22 records and owned job directories; the unchanged
installed app reopened that root with zero jobs and an enabled location
chooser. Broader large-media completion remains required.
