# Media Clock Conversion Policy V4

## Scope and invariant

Mirmir keeps presentation geometry as `ExactRationalV4` until an API requires a
`CMTime` clock. `MediaClockConversionPolicyV4` is the single policy for that
projection:

1. If the rational is exactly representable on the required clock, emit the
   exact tick.
2. Otherwise, accept only an explicitly admitted source/container boundary
   whose value is the immediate floor or ceiling tick of that rational on the
   same clock.
3. Reject real timing gaps, a boundary two or more ticks away, rounded
   exact/admitted boundaries, nonzero epochs, invalid clocks, and arithmetic
   overflow. The canonical sample path may receive a
   decoder-observed tick carrying Core Media's `hasBeenRounded` flag, but its
   numeric value is accepted only when it is the exact, immediate floor, or
   immediate ceiling tick of the reconstructed rational.

The admitted boundary is consulted only when exact conversion reports that the
rational is not representable on the required clock. An exactly representable
rational returns its exact tick even when an independently observed container
duration differs. For an incommensurate rational, the admitted boundary remains
limited to the immediate floor or ceiling tick.

This clock policy does not infer whether the decoder omitted a source sample.
The durable coordinator owns that invariant separately: it inventories the
encoded primary-video sample count and requires the terminal decoded ordinal to
account for every source sample before terminal checkpointing or recovered
publication can finalize output.

For 24000/1001 video on 90 kHz, one frame is 3753.75 ticks. The observed
Ferris final decoded start `556211906/90000` is the floor tick of the exact
frame-148175 start `5932927/960` (`556211906.25/90000`). The reconstructed
end after frame 148175 is exactly `556215660/90000`, which equals the admitted
asset end. A path that starts from the observed floor tick and adds the exact
duration produces `556215659.75/90000`; the same policy permits only the
admitted ceiling tick `556215660/90000`.

The observed 24 fps short source has 241 decoded frames on a 12,288 Hz video
clock. Its last decoded frame starts at `122880/12288`, so the reconstructed
end is exactly `123392/12288`. AVFoundation reports a distinct video-track end
of `123396/12288`, four ticks later. The shared policy returns the exact decoded
end; the admitted container boundary does not participate because exact
conversion succeeded.

## Conversion inventory

| Path | File and function | Site/error | Required clock | 0.25/0.5-tick remainder behavior |
|---|---|---|---|---|
| Shared conversion | `RationalPresentationGeometryV4.swift`; `MediaClockConversionPolicyV4.exact` | `MediaClockConversionV4Error.exactValueNotRepresentable` | Caller-declared source, writer, or encoder clock | Exact conversion rejects every remainder. |
| Shared admitted boundary | `RationalPresentationGeometryV4.swift`; `exactOrAdmittedAdjacent` | `admittedBoundaryNotExactlyRepresentable`, `admittedBoundaryNotAdjacent` | Same caller-declared clock for exact value and admitted boundary | Returns an exactly representable value before considering the admitted boundary. For an incommensurate value, accepts only the independently admitted floor/ceiling tick and rejects a boundary at least two ticks away. |
| Deterministic workflow exact rational | `DeterministicV4MediaProcessingSession.swift`; `workflowTime(_:timescale:)` | `dv4_timing_010`, `dv4_timing_011` | Primary track timebase, capped at 1 GHz | Rejects a remainder; no admitted boundary was supplied. |
| Deterministic workflow `CMTime` | same file; `workflowTime(_:timescale:)` | `dv4_timing_053`, `dv4_timing_054` | Primary track timebase | Non-numeric is 053; a remainder is 054. |
| Deterministic admitted boundary | same file; `workflowTime(exact:admittedBoundary:timescale:)` | `dv4_timing_053`, `dv4_timing_054`, `dv4_timing_056`, `dv4_timing_057` | Primary track timebase | An exact rational returns exact without comparing the admitted boundary. For an incommensurate rational, 056 means the admitted boundary itself is not exact on the clock and 057 means it is not the adjacent floor/ceiling tick. |
| Nominal decoded frame reconstruction | same file; `nominalDecodedPresentationTime` | `dv4_timing_054`, `dv4_timing_055` | Exact cadence denominator before writer projection | Reconstructs `trackStart + frameIndex × nominalDuration`; never truncates to 90 kHz. Denominators outside `Int32` fail at 055. |
| Decoded cadence validation | same file; `validateNominalDecodedCadence`, `canonicalizedNominalDecodedSample` | `dv4_timing_038` | Decoder-observed clock | Allows only exact/immediate floor/immediate ceiling numeric observations of the reconstructed lattice; a real gap fails. The canonical sample check tolerates an observed `hasBeenRounded` flag after validating the numeric tick. Preflight requires unflagged presentation times, while decoded durations may be flagged and are canonicalized only after the same numeric adjacency check. |
| Segment writer clock | same file; `bindSegmentWriterClock`, `processSegment` | sites above | Primary source-track timebase, including 90 kHz | Writer/movie clocks remain the source clock. Samples carry exact reconstructed PTS; every exact/admitted conversion uses the same shared policy. |
| Terminal source completeness | `WorkflowApplicationCoordinatorV4.swift`; `primarySourceSampleCount`, `validateTerminalSourceCompleteness` | `invalidAssembledOutput` | Encoded primary-video sample inventory and terminal decoded input ordinal | Requires `lastCompletedInputOrdinal + 1` to equal the source sample count before terminal checkpointing, finalization, or interrupted-publication recovery. This check is independent of clock admission. |
| Direct mapped/edit timeline | same file; private `workflowTime(_:)`, `directDecodedReaderTimeRange`, `canonicalDecodedPresentationTime` | `dv4_timing_055` and mapped-range sites | Exact rational denominator | Direct mappings remain exact and reject unrepresentable denominators; no adjacent-boundary exception is used. |
| Segment identity and assembly | `AVFoundationSegmentAssemblerV4.swift`; `workflowTime`, `exactTime`, sequence verification and sample retiming | `invalidSegmentSequence` | Reduced exact identity clock or plan-declared movie clock | Identity no longer rounds to 1 GHz. Plan ranges must be exact on the assembly clock; sample retiming adds exact offsets. |
| Track migration | `AVFoundationTrackMigrationExecutorV4.swift`; `exactEditMapMovieTimescale`, `sessionStartTime`, `cmTime`, processed/non-video sample verification | migration sequence/timing errors | LCM edit-map clock and each declared track timebase | Chooses an exact common clock and forwards exact sample timing. It does not project 24000/1001 samples onto 90 kHz by rounding. |
| Conventional video | `VideoProcessingSession.swift`; `processVideo` | conventional reader/writer errors | Original decoded PTS supplied to the pixel-buffer adaptor | No 90 kHz conversion occurs. A 0.25/0.5-tick family is preserved in the sample's own `CMTime`; variable cadence is not forced to a lattice. |
| Conventional audio drain/migration | same file; `makeAudioPath`, `copyAudioTracks` | conventional reader/writer errors | Original audio sample clocks | Pass-through and AAC paths append source-reader samples without projecting them onto the video 90 kHz clock. The NTSC remainder condition is therefore not applicable. |
| Conventional writer finalization | same file; `process` | conventional writer failure | `source.duration` as admitted by AVFoundation | Passes the admitted duration directly to `endSession`; there is no rational-to-90-kHz projection. |
| Output validation | `OutputMediaValidator.swift`; `validate`, `readBoundarySample` | `outputFinalizeFailed` | Output asset's own duration and track timing | Checks positive duration and readable first/final samples. It performs no clock conversion and cannot raise 053–055. |
| Media-pipeline writer configuration | `AVFoundationMediaSessionConfiguration.swift`; writer/input construction and `makeSampleBuffer` | media-pipeline timing errors | Planned video clock | Uses the planned clock and forwards `FrameTiming`; it does not perform lossy rescaling. |
| Media-pipeline final mux | `AVFoundationMediaSessionFinalization.swift`; `finalize`, `buildFreshSeededMovie` | metadata/finalization errors | Exact LCM from `ExactVideoWriterTimeScale.commonBoundaryScale` | Computes a clock that exactly represents source/edit boundaries; a remainder is rejected during scale construction rather than rounded. |
| Output identity verification | `OutputMediaIdentityVerification.swift`, AAC/PCM identity readers, `OutputMediaVerifier.swift` | identity mismatch | Native sample clocks | Compares or shifts timing with exact `CMTime` arithmetic; it does not coerce video/audio onto 90 kHz. |
| Packaged smoke/parity identity | `MirmirApp.swift`; `normalizedTime`, `timeIdentity` | smoke/parity invariant | Reduced exact rational clock | Former 600 kHz rounding was removed. Identities now use canonical exact rationals. |

## Forensic sites

- `dv4_timing_053_cm_time_not_numeric`: input has no numeric time.
- `dv4_timing_054_cm_time_not_exactly_representable`: no admitted-boundary
  rule was applicable and exact projection failed.
- `dv4_timing_055_rational_denominator_not_representable`: an exact rational
  cannot be encoded in a `CMTimeScale`.
- `dv4_timing_056_admitted_clock_boundary_not_exactly_representable`: the
  independent admitted boundary is invalid for the declared clock.
- `dv4_timing_057_exact_rational_not_adjacent_to_admitted_clock_boundary`:
  an incommensurate exact value was supplied with an admitted boundary that is
  neither its immediate floor nor its immediate ceiling tick.

## Evidence boundary

Unit and fixture tests establish the conversion policy and the production
segment path. Named durable-coordinator regressions separately reject a
240-of-241 terminal decode before finalization and accept ordinal 240 for a
241-sample source. They do not establish completion of the historical Ferris
job.
Before the owner-authorized October 1 cache clear, that job had checkpoint
ordinal 2,468, 2,469 committed segment files, and 36 source frames remaining.
Its cached checkpoint, segments, and recovery lock have since been removed.
A later, separate job completed all 148,176 GPU frames and 2,470 segments, then
failed in assembly/migration. The October 7 1.7.0 (17) repair finalized that
saved job with all tracks verified and installed/launched the signed repair.
Its exact DTS-based assembly-duration rule and reduced chapter-item clocks
preserve the shared admission policy above. See
[finish-stage repair](../DETERMINISTIC_FINALIZATION_REPAIR.md). Fresh full GPU
processing and matched whole-movie throughput remain separate work.
