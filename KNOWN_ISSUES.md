# Mirmir accepted limitations and follow-up work

Updated for Mirmir 1.6.0 build 16 on October 6, 2026. These entries distinguish
source repair from installed-product and full-media qualification. The
installed `/Applications/Mirmir.app` reports 1.5.0 build 15 and has not been
replaced by this source update.

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
current installed `/Applications/Mirmir.app` reports 1.5.0 build 15, but its
cache confirmation behavior has not been rechecked in this investigation.

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

**Status:** Post-first-release qualification
**Priority:** Non-blocking follow-up

The historical Ferris run did not publish a complete output movie. Its recorded
failure is the 36-frame terminal timing defect described in DV4-001; its cache
was cleared on October 1 with owner authorization. Further testing requires a
new candidate run.

### Qualification work

- Complete the original beta asset or an authenticated byte-identical copy.
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
