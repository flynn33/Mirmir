# Mirmir known product issues

Verified against the `rollback/pre-resource-bar` checkout on September 27,
2026. These entries describe open product gaps. They are not implementation,
qualification, release, or shipment claims.

## DV4-001 — Original 1:43 Deterministic v4 error-16 failure is unverified

**Status:** Open
**Priority:** High — reported beta upscale failure on a larger source

### Current evidence

The original 1:43 beta asset has not been rerun against version 1.3.3 build 7,
so its `Mirmir.DeterministicV4MediaSegmentError` error 16 failure is not
verified closed. Error 16 currently bridges from `invalidSampleTiming`, but
that mapping does not identify the root-cause throw site for the beta asset.

Build 7 accepts legal 90 kHz NTSC timestamp quantization in cadence validation
and tests the legal lattice through approximately the original source's frame
range. That is candidate regression coverage only. Every
`invalidSampleTiming` throw now carries a distinct stable site identifier so a
future reproduction can name the actual failing check.

### Required closure evidence

- Rerun the original beta asset or an authenticated byte-identical copy.
- Capture the stable timing site identifier if error 16 recurs.
- Tie any further correction to that exact throw site and preserve rejection
  of real timestamp discontinuities.
- Complete the same requested Deterministic v4 upscale and verify the published
  movie's frame timing, duration, audio topology, and other planned tracks.

The local archive at
`/Users/jimdaley/Desktop/Mirmir-Beta-1.3.3-7.xcarchive` is a TestFlight handoff
artifact, not closure evidence. It is excluded from Git; upload remains an
owner action.

## UI-001 — Completed Before/After comparison lacks playback in the active UI

**Status:** Open
**Priority:** High — advertised user-facing comparison functionality

### Current behavior

The active application composition routes completed jobs through
`MirmirProductUpscaleWorkspace` and `MirmirBeforeAfterComparison`. That viewer
loads one still image near the midpoint of the source and one near the midpoint
of the completed output. It provides a draggable split, but it has no play,
pause, replay, or timeline controls.

A separate `MirmirCompletedComparisonPlaybackView` already expresses the
intended interaction, but it is not wired into the active application
composition. It loads the original and verified completed output into
synchronized players with shared playback and scrubbing.

### Product impact

A midpoint still cannot expose temporal reconstruction defects, flicker,
motion instability, cadence problems, compression changes over time, or
source/output synchronization errors. The active behavior therefore does not
satisfy the documented completed-job Before/After comparison feature.

### Required behavior

After an output completes and passes semantic verification, the active
Before/After viewer must:

- load the original source and verified completed output;
- provide play, pause, replay, current time, duration, and shared scrubbing;
- keep both videos synchronized after play, pause, seek, end-of-playback, and
  application focus changes;
- apply the movable split to the same presentation time on both sides;
- play no more than one audio stream, with the completed output as the default;
- distinguish loading, ready, ended, and actionable playback-failure states;
  and
- retain progress as a separate processing presentation. Any live sampled
  frames must be labeled as a preview and must not be presented as the final
  completed comparison.

### Acceptance evidence

- A UI or integration test proves that a completed job exposes enabled
  play/pause, replay, timeline, and split controls.
- A multi-frame fixture proves both players remain within the declared sync
  tolerance during playback and after repeated seeks.
- Manual validation exercises motion, scrubbing, divider movement, audio,
  replay, and playback failure in the active packaged application.

## VT-001 — VideoToolbox routes lack a geometry compatibility layer

**Status:** Open
**Priority:** High — explicit Apple processing methods are unusable for common
source or target geometries

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

### Required compatibility layer

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
