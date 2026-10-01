# Mirmir accepted limitations and follow-up work

Updated for the 1.4.2 source patch on October 1, 2026. These entries distinguish a
source repair from installed-product and full-media qualification. Product
source identity is version 1.4.2 build 11.

## CACHE-001 — Cache confirmations in installed 1.4.1

**Status:** Source and isolated-store fixture repaired in 1.4.2; installed
product verification open

The installed `/Applications/Mirmir.app` remains 1.4.1 build 10. Its Settings
and queue-row cache confirmations did not appear, preventing the deletion path
from running and leaving **Choose Location…** disabled. The 1.4.2 source uses
one workspace confirmation presenter and awaits the requested cleanup with an
explicit queue readback. Isolated tests deleted completed, paused, and
contained jobs, verified owned files were removed, and observed the empty-queue
location gate become available. The live cache was not cleared for this test.

## DV4-001 — Deterministic v4 error 16 on legal NTSC timing

**Status:** Source repaired in 1.4.1; installed-product/full-job qualification open
**Priority:** Corrective defect

### Current evidence

The preserved approximately 91 GB Ferris job has authenticated checkpoint
ordinal 2,468, 2,469 committed 60-frame segments, and video
`nextInputSampleIndex` 148,140. The source contains 148,176 frames, so the
failed terminal segment is the remaining 36 frames. The installed 1.3.4 build
8 application failed that terminal segment at
`dv4_timing_054_cm_time_not_exactly_representable`; it did not publish a final
movie. The job has not been resumed by the 1.4.1 patch.
Its checkpoint and 2,469 committed segment files have not advanced. A zero-byte
`recovery-v4/decision.lock` first observed at 15:32:46 during source-test
verification is retained because the installed app was already running; it is
not removed or interpreted as job progress.

The observed last PTS `556211906/90000` is the floor tick below the exact
frame-148175 start `5932927/960` (`556211906.25/90000`). Adding exact
`1001/24000` to the observed floor produces `556215659.75/90000`, while the
independently admitted asset end is `556215660/90000`.

### Resolution

The planner supplies exact `1001/24000` cadence. Version 1.4.1 additionally
reconstructs each nominal PTS as `trackStart + frameIndex × cadence`, so the
last frame keeps its exact start before writer projection. One shared policy is
used by terminal and nonterminal boundaries: exact values must equal the
admitted boundary; an incommensurable value may use only the admitted immediate
floor or ceiling tick. Forensic site 056 identifies an invalid admitted clock
boundary, while site 057 identifies a non-adjacent boundary or genuine gap.

Named unit and production-path fixture tests cover the Ferris rational,
frame-148175 reconstruction, a 90 kHz nonterminal boundary, exact terminal
values, a mismatch two ticks away, and a missing final frame. This is source
and fixture evidence, not proof that the preserved job completes end to end.

## DV4-002 — Extended large-media Deterministic qualification

**Status:** Post-first-release qualification
**Priority:** Non-blocking follow-up

The preserved Ferris run did not publish a complete output movie. Its recorded
failure is the 36-frame terminal timing defect described in DV4-001; the 1.4.1
source repair has not been exercised by resuming that job. Further testing
remains required after an explicitly authorized candidate run.

### Qualification work

- Complete the original beta asset or an authenticated byte-identical copy.
- Capture the stable timing site identifier if any timing failure occurs.
- Tie any further correction to the exact throw site and preserve rejection of
  real timestamp discontinuities.
- Complete the same requested Deterministic v4 upscale and verify the published
  movie's frame timing, duration, audio topology, and other planned tracks.

The current local archive at
`/Users/jimdaley/Library/Developer/Xcode/Archives/2026-09-30/Mirmir-1.4.1-10-TestFlight.xcarchive`
is a TestFlight-capable handoff artifact, not closure evidence. It is excluded
from Git and has not been uploaded to App Store Connect. The previously
documented Desktop path is not present.

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
