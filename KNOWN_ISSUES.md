# Mirmir accepted limitations and follow-up work

## QA-002 — Broad input support and reported error 11 remain release blockers

**Status:** Open; these defects are not accepted release limitations.

Resumed QA repaired omitted metadata, legacy sampling, durable audio, CPU
runtime admission and supported FMP4/H264 AVI imports. The two AVI fixtures now
complete real CPU and Metal workflows with correct picture order and exact
audio. H.264 MKV, Motion JPEG 4:2:2/4:4:4 MOV, MPEG-2 transport streams,
VP9 WebM and WMV ASF still need production importer/decoder/timing repairs.
MPEG4 ASP B-frame AVI also fails native decoder creation. Additional H264 POC/
field modes and richer AVI track/metadata graphs remain unverified compatibility
requirements. The native MPEG2 reader returns 70 real frames where independent
decoding returns 72; admitting its range alone would conceal missing frames.
These are required implementation repairs, not accepted format limitations.
The reported error-11 incident remains open; improved logging does not
establish a causal repair. See [the QA report](docs/FINAL_QA_2026-10-24.md).

Updated for Mirmir 1.7.2 build 20 on October 25, 2026. These entries distinguish
source repair from installed-product and full-media qualification. The historical
October 7 readback confirms the signed **1.7.0 (17)** repair installed and
launched, with the native About version/build and idle Metal route verified.
The earlier October 7 1.6.0 (16) and October 6 1.5.0 (15) checks are historical.

## QA-003 — Feature-length PCM finalization

**Status:** Repaired and qualified in the runtime7 snapshot.

The 90-minute AVI test exposed excessive per-frame hash formatting, then a
1,036,800,020-byte explicit PCM size table that FFmpeg rejected. A separate
defect truncated the test's source inventory at rounded global asset duration.
The PCM helper retains payload, timing and attachment identity while expressing
constant sizes once. The fresh runtime7 complete workflow passes independent
full decoding: all 129,600 pictures at exact 24 fps and all 259,200,000 PCM16
frames match the source; its size table is 20 bytes. This does not qualify 4K
throughput or later source changes. See [the continuation](docs/QA_FOLLOWUP_2026-10-25.md).

## QA-004 — Minimum macOS HDR ambient metadata

**Status:** Repaired and qualified in the runtime7 snapshot.

On macOS 15.4, PQ lost requested ambient metadata and HLG invented/replaced it.
Cross-reading and physical HEVC/container inspection confirmed incorrect output
bytes. The format-header repair preserves encoded samples, decoded pixels and
strict metadata checks. Focused 43/43 tests pass on host and guest; the complete
runtime7 minimum-OS suite passes 720 tests with zero failures and 13 opt-in skips.

## QA-005 — Native iTunes metadata and H.264 wrapper verification

**Status:** Single-audio repairs pass the frozen runtime8 native baseline;
multiple-audio technical metadata remains unfinished.

Native MOV/MP4/M4V export loses iTunes gapless metadata, and macOS 15.4 also loses
a custom freeform note. Exact restoration must account for changed AAC priming
when transcoding; blindly restoring the old technical value changes decoded
audio. Typed translation and durable queue replay pass focused tests and the
complete runtime8 host/minimum-OS suites. A separate
H.264 wrapper-only stream mismatch has seven passing regressions on arm64 and
Rosetta. Multiple-audio controls expose contradictory global gapless-hint
semantics: neither blindly restoring the old tag nor deriving it from the last
track preserves all consumer clocks and copied audio. No general repair has
been integrated. These findings do not establish the cause
of customer error 11. See [the continuation](docs/QA_FOLLOWUP_2026-10-25.md).

## QA-006 — Chroma calibration, interpretation and physical alignment

**Status:** Reproduced after the full native baseline suites; private repairs
under qualification. These are release blockers.

Actual Center H.264/HEVC jobs complete frame processing then fail final format
verification because calibration encoded an untagged synthetic Left frame.
The private Center fix alone exposes a silent TopLeft declaration regression:
CoreMedia labels physical H.264 SPS location 2 as Center. The isolated encoder
correctly writes TopLeft; authenticated source interpretation needs correction.

An independent physical-coordinate oracle also shows that the current scaler
shifts Left chroma relative to luma by 0.5 output luma pixels at 2× and 1.5 at 4×.
CPU and the actual verified P06 Metal library agree on the incorrect geometry.
Siting-aware UV coordinates and decoded-boundary metadata are being corrected
privately; matching backend bytes alone does not qualify physical alignment.
See [the continuation](docs/QA_FOLLOWUP_2026-10-25.md) for exact evidence and
additional odd raw-carrier edge corruption found during broad-format work.

## MEDIA-001 — MP4 raw chapter list rejected during MOV finalization

**Status:** Reproduced and repaired in local 1.7.2 (20) source

The production HEVC MP4 workflow rejected finalization because the MOV writer
silently dropped raw ISO `chpl` asset metadata. The migration adapter now emits
the byte-identical item in the QuickTime userdata namespace and compares its
canonical identity. Payload, language, type, identifier and omission mutations
still fail. See [final QA](docs/FINAL_QA_2026-10-24.md) for before/after evidence.

## PROCESS-001 — Prepared backend not finished on early failure

**Status:** Reproduced and repaired in local 1.7.2 (20) source

Cancellation after asynchronous preparation and output setup rejection occurred
outside the cleanup path. The coordinator releases the backend before session
ownership transfers; the session catches setup as well as processing failures.
Tests require cleanup and preservation of an existing destination.

## UI-001 — Main window cannot be reopened after closing

**Status:** Native menu lifecycle correction verified in 1.7.1 (19)

App Review reported that 1.7.0 (18) had no menu item for reopening its main
window after closing it. The 1.7.1 patch adds **Window > Show Main Window**
(**Command-0**) to reopen or focus the workspace.
See [window lifecycle](docs/WINDOW_LIFECYCLE.md) for the verification procedure.
This source correction does not establish App Review acceptance.

## DV4-003 — Complete GPU job rejected during final assembly/migration

**Status:** Production repair and saved full-job recovery verified in 1.7.0 (17)

The installed 1.6.0 job completed 148,176 GPU frames and 2,470 segments, then
failed with `Mirmir.AVFoundationSegmentV4Error` 13 during final assembly.
The reproduced failure compared a changed AVAssetReader duration against
unchanged stored decode cadence. Completing the recovered job also exposed
equivalent chapter-clock representations, omitted individual grouped-audio
DTS, AC3 container-wrapper differences, and actual dropped ISO audio names.
The assembler and track migration now handle those verified boundaries with
exact, narrowly scoped checks; changed timing, payload, formats, or metadata
remain rejected.

Full production finalization and independent verification passed for all
148,176 video frames, both audio tracks and their names, all 14 chapters, and
complete decoded audio PCM. The source, checkpoint, and request hashes are
unchanged. The historical queue entry remains contained; its lifecycle was not
rewritten. See [repair details](docs/DETERMINISTIC_FINALIZATION_REPAIR.md).

This recovery used completed GPU cache. A fresh full GPU render and matched
whole-movie throughput remain separate qualification work.

## PARITY-001 — Intermittent Release decoded H.264 mismatch

**Status:** Encoder-arrival sensitivity reproduced and source repair verified in 1.7.2 (20)

The October 24 x86-64 run reproduced failures on 66-, 156-, and 157-frame jobs
while all traced pre-encoder pixels and presentation timing matched. A separate
writer-only control re-encoded the same frames and timestamps with fast versus
40 ms-delayed delivery. Default H.264 encoding changed B/P-frame decisions and
decoded pixels. Disabling frame reordering made both control outputs identical.

The deterministic H.264 writer now sets `AVVideoAllowFrameReorderingKey=false`.
The new arrival-pacing regression fails before that change and passes afterward
in Debug, native Release, and x86-64 Release. Existing strict CPU/Metal assertions
remain intact. See [final QA](docs/FINAL_QA_2026-10-24.md) for completed-suite
results, repeats, and release limits. The policy affects compression efficiency;
it does not claim fixed output size or whole-movie throughput.

The retained October 7 failure had 156 equal pre-encoder frames and different
decoded ordinals 125–148 and 154. Its original evidence remains unchanged in
`docs/v4/evidence/spatial-parallelism-2026-10-07/OPEN_QUALIFICATION.md`. Earlier
green repetitions did not identify the cause; the new controlled pacing
reproduction provides the evidence for this repair.

## PROV-001 — Packaged runtime source closure

**Status:** Current source closure passes; packaged release qualification remains separate

The October 24 repair audits the changed capture observer, updates its frozen
source binding, and rebuilds the P06 runtime twice with byte-identical output.
`repository_identity_v4.py --repository .` passes for the candidate. Historical
captures are not relabeled as new evidence. Qualification contract/tool pins
and the aggregate trust root were refreshed together after producer review.
See [current QA](docs/FINAL_QA_2026-10-24.md) for the checks and remaining gates.

## PERF-002 — Spatial-stage speedup and whole-movie throughput

**Status:** Exact spatial parity and isolated timing measured; full-movie
throughput remains open

At 3840×1632 with 14 workers, five alternating measurements after warmup
reduced the spatial-conditioning median from 91.325 to 10.248 ms, **8.91×**,
with identical pixels and controls. The benchmark includes validation, halo
staging, dispatch, and joined completion; it excludes input reset and equality
checking. This result covers spatial conditioning only. Existing source
authentication, ordered history, encoding, checkpoints, and output verification
still contribute to complete-job time. See
[spatial parallelism](docs/DETERMINISTIC_SPATIAL_PARALLELISM.md).

## PERF-001 — Diagnostic overhead during long deterministic jobs

**Status:** Source repair and isolated measurements complete; full-length
throughput verification open

The previous persistent diagnostic append reread, decoded, canonicalized, and
privacy-validated every retained record. The broader credential checks added in
1.4.3 increased that existing history-replay cost. An optimized isolated
benchmark with 7,999 retained records measured 5.235 seconds per durable append
in the released source and 5.231 milliseconds with the 1.5.0 history cache.
The resulting journals were byte-identical. This is an append measurement,
not a completed-job speed result.

Version 1.5.0 retains privacy validation, cross-process locking, journal-change
detection, and corrupt-tail recovery. It records progress and active-job
process samples at minute intervals, keeps detailed failures, and omits
duplicate successful checkpoint notices. It also restores the scaler's cheaper
NV12/P010 validation without changing visible output bytes.

Full-source SHA-256 authentication still runs at every deterministic segment.
Removing the intermediate hash-buffer copy does not remove that full read.
The original one-hour throughput and the complete cause of the reported
18-hour run have not been established by a matched full-length rerun. See
[`docs/v4/CURRENT_QUALIFICATION_STATUS.md`](docs/v4/CURRENT_QUALIFICATION_STATUS.md)
for the measured scope and current verification results.

## CACHE-001 — Cache confirmations in installed 1.4.1

**Status:** Source and isolated-store fixture repaired in 1.4.2; installed
product verification open

The earlier installed 1.4.1 build 10 lacked visible Settings and queue-row
cache confirmations, preventing the deletion path from running and leaving
**Choose Location…** disabled. The 1.4.2 source uses
one workspace confirmation presenter and awaits the requested cleanup with an
explicit queue readback. Isolated tests deleted completed, paused, and
contained, failed, and cancelled jobs, verified owned files were removed, and
observed the empty-queue location gate become available. The owner then
authorized clearing the live root through those same methods. The installed
1.4.1 app reopened it with zero jobs and **Choose Location…** enabled. The
October 6 installation check reported `/Applications/Mirmir.app` 1.5.0 build
15; its cache confirmation behavior was not rechecked in that investigation.

## DV4-057 — Short nominal-cadence video terminal boundary

**Status:** Source repair, named regression, and historical 1.4.3 short-source
workflow complete; installed-product and extended large-media verification open

**Priority:** Corrective defect

The loaded `raven-forge-app-splash-2.mp4` has 241 decoded 24 fps video frames.
AVFoundation reports last decoded PTS `122880/12288` and track end
`123396/12288`. The exact end after frame 241 is `123392/12288`, four source
ticks before the container boundary. The earlier one-tick policy raised
`dv4_timing_057_exact_rational_not_adjacent_to_admitted_clock_boundary` at
terminal finalization.

The shared clock policy now returns the exact `123392/12288` boundary before it
considers the distinct container duration. An admitted boundary is consulted
only when the exact rational is incommensurate with the required clock, and it
must still be the immediate floor or ceiling tick. The named asset regression
derives the frame count and both boundaries from the source. The current
installed build's short-source completion has not been rechecked here.

The durable coordinator separately inventories 241 encoded primary-video
samples and requires the terminal decoded ordinal to account for all 241 before
finalization. The named terminal-completeness regressions reject a 240-of-241
terminal decode and verify that finalization is not called. This completeness
check does not change the shared clock-admission rule.

The named 1.4.3 asset regression passed 1 of 1. The production
durable-workflow run on the reported source and its independent postvalidation
passed 66 of 66 checks, with 241 video frames in the source and output. This
historical short-source result does not complete DV4-002 or qualify the current
source or installed application.

## AUD-001 — Singleton audio selection group

**Status:** Source repair, focused regression, and historical 1.4.3
short-source workflow complete; installed-product verification open

**Priority:** Corrective defect

The loaded MP4 presents its sole AAC track as a one-member audible selection
group. The conventional writer previously skipped groups with fewer than two
audio members, while `OutputMediaValidator` compared that source group with the
output, so a completed encode was rejected as changed alternate-audio
membership or default selection.

The writer now emits the singleton group and preserves its enabled/default
selection. `testConventionalSessionPreservesSingletonAudioGroupAndDefaultSelection`
creates a real one-member `AVAssetWriterInputGroup`, processes it through
`UpscaleCoordinator`, and compares the source and output topology. The source
track-group probe identifies one AAC track in one audible selection group with
that track as its default selection.

The same production workflow and independent postvalidation preserved all 470
source audio packets in the output and matched the one-member audible selection
group and default track. That historical result does not verify audio
preservation in the current installed application.

## DV4-001 — Deterministic v4 error 16 on legal NTSC timing

**Status:** Source repaired in 1.4.1; installed-product/full-job qualification open
**Priority:** Corrective defect

### Current evidence

Before the owner-authorized October 1 cache cleanup, the approximately 91 GB
Ferris job had authenticated checkpoint
ordinal 2,468, 2,469 committed 60-frame segments, and video
`nextInputSampleIndex` 148,140. The source contains 148,176 frames, so the
failed terminal segment is the remaining 36 frames. The installed 1.3.4 build
8 application failed that terminal segment at
`dv4_timing_054_cm_time_not_exactly_representable`; it did not publish a final
movie. The job was not resumed by the 1.4.1 patch. Its cached checkpoint,
segments, and zero-byte `recovery-v4/decision.lock` were removed with the
authorized cache clear. This historical evidence does not imply a completed
movie.

The observed last PTS `556211906/90000` is the floor tick below the exact
frame-148175 start `5932927/960` (`556211906.25/90000`). Adding exact
`1001/24000` to the observed floor produces `556215659.75/90000`, while the
independently admitted asset end is `556215660/90000`.

### Resolution

The planner supplies exact `1001/24000` cadence. Version 1.4.1 additionally
reconstructs each nominal PTS as `trackStart + frameIndex × cadence`, so the
last frame keeps its exact start before writer projection. One shared policy is
used by terminal and nonterminal boundaries: exact values return exact without
comparison to an independently observed boundary; an incommensurable value may
use only the admitted immediate floor or ceiling tick. Forensic site 056
identifies an invalid admitted clock boundary, while site 057 identifies a
nonadjacent admitted boundary. The durable coordinator's independent terminal
sample-count invariant identifies missing decoded source samples.

Named unit and production-path fixture tests cover the Ferris rational,
frame-148175 reconstruction, a 90 kHz nonterminal boundary, exact terminal
values, and a mismatch two ticks away. Separate terminal-completeness tests
cover a missing final source sample. This is source and fixture evidence, not
proof of an end-to-end large-media completion.

## DV4-002 — Extended large-media Deterministic qualification

**Status:** Saved full-job finalization verified; fresh full-run qualification open
**Priority:** Non-blocking follow-up

The historical run described in DV4-001 did not publish a complete movie and
its cache was cleared on October 1. A later, separate job completed all 148,176
GPU frames, then encountered the finish-stage defects described in DV4-003.
The October 7 repair finalized that complete saved job and independently
verified the published movie's frame timing, duration, audio, labels, and
chapters. The signed repair is installed and launched. Recovery reused saved
GPU frames, so fresh complete-run stability and matched throughput remain open.

### Qualification work

- Repeat the original beta asset or an authenticated byte-identical copy through
  the repaired candidate's full GPU processing and finalization path.
- Capture the stable timing site identifier if any timing failure occurs.
- Tie any further correction to the exact throw site and preserve rejection of
  real timestamp discontinuities.
- Complete the same requested Deterministic v4 upscale and verify the published
  movie's frame timing, duration, audio topology, and other planned tracks.

The historical local archive at
`/Users/jimdaley/Library/Developer/Xcode/Archives/2026-10-01/Mirmir-1.4.2-11-TestFlight.xcarchive`
is an Apple Distribution signed artifact prepared for owner handoff only, not
full-media closure evidence. It is excluded from Git and was not uploaded,
submitted, distributed, released, or installed.

## VT-001 — VideoToolbox geometry adaptation

**Status:** Post-first-release enhancement
**Priority:** Not a first-release target

### Affected methods

- VideoToolbox Smooth Motion + Spatial Upscale
- VideoToolbox Super Resolution — Quality
- VideoToolbox Super Resolution — Low Latency where the current Mac reports
  restrictive source, target, or scale-factor support

### Current behavior

Mirmir asks the current VideoToolbox API whether the selected source geometry,
target geometry, and scale factor are accepted. Smooth Motion + Spatial
Upscale additionally requires the API-supported 2× spatial configuration. When
the exact request is outside those limits, Mirmir reports unsupported source
dimensions, unsupported target dimensions, or an unsupported scale factor and
does not run the selected method.

The existing target-adjustment flow can offer a VideoToolbox-supported scale
factor for the Super Resolution methods. It does not adapt an unsupported
source raster into a supported VideoToolbox working raster, and it does not
restore the user-requested final dimensions after VideoToolbox processing.

Version 1.4.0 intentionally reports the selected VideoToolbox method as
unavailable when the Mac rejects the exact geometry. That truthful fail-closed
behavior, with no backend substitution, is the first-release contract.

### Post-first-release compatibility layer

Add an explicit geometry-compatibility planner and execution layer around the
selected VideoToolbox engine:

1. Query and record the current Mac's actual VideoToolbox source-dimension,
   pixel-count, target-dimension, pixel-format, and scale-factor limits.
2. Use the original raster directly when VideoToolbox accepts it.
3. Otherwise, derive a positive integral intermediate raster that fits every
   reported limit, preserves display aspect ratio, respects clean aperture and
   sample aspect ratio, and satisfies the selected VideoToolbox configuration.
4. Convert or resize decoded frames into that declared intermediate raster
   before VideoToolbox processing.
5. Run the explicitly selected VideoToolbox method. Do not silently substitute
   a different backend.
6. If the VideoToolbox result does not equal the requested final raster, apply
   a declared post-scale to the exact requested output dimensions.
7. Preserve timing, cadence, color range, color/HDR metadata, orientation,
   alpha policy, audio, and all other supported tracks across the complete
   pipeline, then run the normal semantic output verification.

The plan must be shown to the user before processing whenever it introduces a
pre-scale or post-scale. It must identify the original raster, VideoToolbox
working raster, native VideoToolbox output raster, requested final raster, and
the scaler used at each compatibility boundary. Cropping, stretching, aspect
ratio changes, or quality-reducing downscales require explicit consent; they
must never occur as hidden fallback behavior.

If no valid compatibility plan can satisfy the selected method and preservation
contract, Mirmir must keep the method unavailable and report both the rejected
request and the Mac's accepted limits. The compatibility layer must not turn an
unsupported or lossy plan into a misleading success.

### Design risks requiring qualification

- Downscaling a large source before spatial upscaling may erase detail and can
  negate the user's quality goal.
- A post-scale may make the final raster valid without making it equivalent to
  native VideoToolbox processing at that raster.
- Frame interpolation requires temporal history; tiled processing cannot be
  assumed safe without explicit seam and motion-boundary proof.
- Odd dimensions, chroma subsampling, clean aperture, rotation, anamorphic
  video, HDR, and alpha can require different integral working geometries.
- Intermediate conversion must remain bounded in memory and must participate
  in cancellation, diagnostics, progress, temporary-artifact accounting, and
  recovery.

### Acceptance evidence

- Table-driven planner tests cover exact-fit, maximum-dimension,
  maximum-pixel-count, odd-size, rotated, anamorphic, HDR, and impossible-plan
  cases using injected VideoToolbox capability limits.
- Integration tests prove the pre-scale → VideoToolbox → post-scale path emits
  the exact requested final raster without silent backend substitution.
- Media-preservation tests cover cadence, duration, audio, color/HDR metadata,
  orientation, aperture/aspect metadata, and auxiliary tracks.
- Diagnostics record the reported device limits and every planned and executed
  geometry transition.
- Real-file testing on supported macOS and hardware proves both a formerly
  rejected compatible input and a truthful no-valid-plan rejection.
