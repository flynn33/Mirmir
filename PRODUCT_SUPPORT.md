# Mirmir product support

Current product identity: **Mirmir 1.4.1 (10)**.

Mirmir is a sandboxed macOS 15.4-or-later application. It reads local media
through security-scoped bookmarks, builds an explicit whole-asset plan, and
publishes a semantically verified QuickTime movie atomically. An explicit
backend selection is never replaced by a different scaler after failure.

## Implemented backends

| Backend | Current contract |
| --- | --- |
| Mirmir Deterministic — CPU Reference | Explicit ASH P06 selection. Shared fixed-point spatial and temporal reconstruction, arbitrary integral upscale geometry, supported opaque and alpha formats, verified runtime assets, and no Apple fallback. |
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

## Timing correction and large-media boundary

Version 1.4.1 reconstructs nominal presentation timestamps from exact frame
ordinal and cadence. One shared conversion policy covers nonterminal lookahead
and terminal boundaries: exact values remain exact, while an incommensurable
value can use only an independently admitted adjacent source-clock tick. A
missing frame or any non-adjacent gap fails under forensic site 057.

The preserved original 1:43 Ferris job is not completion evidence. Checkpoint
ordinal 2,468 contains 2,469 committed 60-frame segments and records the video
`nextInputSampleIndex` as 148,140. The source contains 148,176 frames, leaving a
36-frame terminal remainder where the installed build failed at site 054. The
approximately 91 GB job directory remains unchanged. A full candidate run and
published output verification remain separate qualification work.

VideoToolbox methods fail closed when the exact source, target, or scale
geometry is unsupported. Automatic pre-scale and post-scale geometry
adaptation is a post-first-release enhancement, not part of the version 1.4.0
contract. Deterministic resource allocation is likewise outside the
first-release target. These accepted boundaries and follow-up work are tracked
in [`KNOWN_ISSUES.md`](KNOWN_ISSUES.md).

## Upscale and Compare surfaces

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
- CPU and Metal consume one fixed-point semantic contract. Release evidence
  requires byte equality for visible output planes across NV12, P010, arbitrary
  geometry, temporal, interlaced, and alpha conformance cases.

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
- Deterministic cadence validation accepts only exact or immediately adjacent
  legal 90 kHz NTSC quantization. Error 16 (`invalidSampleTiming`) diagnostics
  carry stable site identifiers 053–057 for numeric, exact-representation,
  rational-denominator, admitted-boundary, and non-adjacent-gap failures.
- The installed application remains version 1.3.4 build 8 and does not contain
  the 1.4.1 source correction. The preserved Ferris job has not been resumed;
  its checkpoint and 2,469 committed segment files have not advanced. Its
  zero-byte `recovery-v4/decision.lock` is intentionally left in place.

## Qualification boundary

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
zero failed, and three expected opt-in capture tests skipped. The current local
TestFlight-capable handoff archive is 1.4.1 build 10 at
`/Users/jimdaley/Library/Developer/Xcode/Archives/2026-09-30/Mirmir-1.4.1-10-TestFlight.xcarchive`;
it is not in Git and has not been uploaded, notarized, or installed. The
previously documented Desktop path is not present. The installed 1.3.4 build 8
app and preserved failed job are not upgraded by creating that archive. Broader
large-media completion remains required.
