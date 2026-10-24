# Deterministic spatial parallelism

Mirmir **1.7.0 build 17** runs state-conditioned spatial reconstruction in
bounded CPU row stripes on both deterministic routes. The canonical fixed-point
scaler continues to execute on the selected CPU or Metal backend. This change
parallelizes the following conditioning stencil; it leaves frame ordering,
temporal history, source authentication, output verification, and durable
checkpoint publication intact.

## Execution and storage

`ASHSpatialExecutionPolicyV4` chooses one worker below 262,144 samples and
otherwise caps automatic workers by plane height and active processor count.
The internal forced serial/parallel policies support parity checks and paired
measurements. There is no user setting or promise of proportional CPU/GPU
utilization.

`ASHSpatialReconstructorV4.reconstructInPlace` validates state integrity,
geometry, code range, every input sample, and program controls before mutation.
The parallel path snapshots both original rows adjacent to each stripe boundary
before dispatch. Each worker then reads only its own stripe or those immutable
boundary rows and writes its disjoint output range. Every worker owns a
three-row ring. Dispatch joins before the exclusive output and scratch borrows
end; cancellation is checked before the write phase. The original serial loop
remains available for exact comparison and small planes.

The prepared scratch requirement is `width × (5 × workers − 2)` UInt16 samples:
three rows per worker plus two rows for every boundary. At width 3840 and 14
workers that is 522,240 bytes (510 KiB), without a full-plane snapshot. Reusable
workspace capacity retains its high-water allocation. Spatial gains, target
messages, signed ties-to-even rounding, clamps, and every visible output pixel
retain the reference contract. Frames are not processed concurrently.

Source:
[`ASHTemporalReconstructionV4.swift`](../Mirmir/Modules/UpscalerEngine/ASHTemporalReconstructionV4.swift),
symbols `ASHSpatialExecutionPolicyV4`, `ASHSpatialReconstructionWorkspaceV4`,
`ASHSpatialReconstructorV4.reconstructInPlace`, `reconstructParallelStripes`,
and `reconstructStripe`.

## Spatial-stage measurement

On the observed 14-core M4 Pro, the optimized 3840×1632 fixture measured a
serial median of **91.325 ms** and a 14-worker parallel median of **10.248 ms**,
an **8.91×** speedup. Five alternating serial/parallel pairs follow warmup.
Full sample validation, conditioned controls, scratch preparation, boundary
copies, dispatch, and joined completion remain inside the timer. Resetting and
uniquifying the mutation input happens before timing; full pixel/control
equality happens afterward. This result covers spatial conditioning only.

The raw receipt includes 256×256, 512×512, 1024×256, 1920×816, and 3840×1632
planes with requested worker limits 1, 2, 4, 8, and 14. The automatic threshold
is an execution choice supported by those retained timings, not a full-movie
qualification. Source hashing, motion matching, temporal blending, GPU scaling,
encoding, checkpoints, and final semantic verification still contribute to
complete-job time.

See the [portable evidence](v4/evidence/spatial-parallelism-2026-10-07/README.md)
and [raw benchmark](v4/evidence/spatial-parallelism-2026-10-07/raw-benchmark.json).

Actual pre-change and current optimized binaries independently confirmed the
stage gain across ten alternating pairs after five warmups. At 3840×1632,
median time was **99.776 → 12.518 ms (7.971×)**; at 1920×816 it was
**21.922 → 3.175 ms (6.905×)**. All pixels, controls, and cross-binary output
digests match. Ferris remained active, and no builds or tests overlapped the
paired measurements. The original five-pair 8.91× observation remains a
separate receipt; the multipliers describe these fixtures and do not guarantee
full-movie speedup. See
[independent validation](v4/evidence/spatial-parallelism-2026-10-07/INDEPENDENT_VALIDATION.md)
and its [machine-readable receipt](v4/evidence/spatial-parallelism-2026-10-07/independent-validation.json).

## Retained checks

The following tests in
[`ASHTemporalReconstructionV4Tests.swift`](../MirmirTests/ASHTemporalReconstructionV4Tests.swift)
compare an independent reconstruction reference and retain the existing
three-row serial assertions:

- `testParallelSpatialStripesMatchReferenceForEveryStateAndWorkerLimit`:
  all 256 ASH states, uneven stripes, and requested worker limits 1/2/3/7/14.
- `testParallelSpatialBoundaryImpulsesExtremaAndRoundingTiesMatchReference`:
  stripe-edge impulses, full UInt16 extrema, ties, and degenerate geometry.
- `testParallelSpatialWorkspaceReusesBoundedStorage`: scratch bounds and
  stable storage identity after preparation.
- `testSpatialExecutionPolicyAndInvalidInputsFailBeforeMutation` and
  `testCancelledParallelSpatialConditioningNeverMutates`: input/control
  rejection and cancellation before mutation.
- `testParallelSpatialRepeatedAndConcurrentCallsUseIndependentScratch`:
  repeated calls and concurrent copies of a prepared workspace.
- `testParallelSpatialMatchesReferenceAtNativeMovieGeometries`: complete
  1920×816 and 3840×1632 pixel/control parity with forced and automatic policies.
- `testCaptureParallelSpatialBenchmarkWhenRequested`: opt-in optimized timing
  fixture, enabled by `MIRMIR_V4_SPATIAL_BENCHMARK_DIR` with five samples per
  policy by default; `MIRMIR_V4_SPATIAL_BENCHMARK_SAMPLES` selects the count.

## Open qualification boundaries

The later October 7 [finish-stage repair](DETERMINISTIC_FINALIZATION_REPAIR.md)
fully finalized the saved 148,176-frame Metal job, independently verified its
two audio tracks and 14 chapters, and installed/launched the signed 1.7.0 (17)
repair. Its native Debug suite passed 658 tests with zero failures and 12
explicit opt-in skips. Saved GPU cache recovery does not establish fresh full
GPU processing or a matched whole-movie speedup, and does not close the
separate parity or runtime source-identity issues below.

The earlier version-aligned 1.7.0 (17) default Debug suite passed 635 tests with
zero failures and six skips (641 total). Fresh default Release passed 630 tests
with zero failures and six skips (636 total). Both report no runtime warnings.
These passing runs do not identify or repair the earlier decoded H.264 parity
incident. The separately enabled one-frame 4096×2160 → 8192×4320 CPU allocation gate
passed 1/1 with no failures, skips, or reported runtime warnings. These receipts
are separate from the earlier candidate runs below and do not qualify 8K Metal
or full-movie throughput.

The pre-version-alignment candidate passed native Debug with 635 tests,
zero failures, and six opt-in skips. Release passed 630 tests with one strict
decoded H.264 parity failure and five opt-in skips. All 156 pre-encoder frames
match; 25 decoded ordinals, 125–148 and 154, differ. Four traced repeats match,
but the cause remains unknown. This is retained as an open beta issue; the
assertion was not weakened. Spatial timing capture was enabled in that Release
suite; the five skips must not be combined with default-suite receipts.

The development-unsealed quality replay reproduced all 840 baseline artifacts
and the quality result. Its 64×48 planes run serially and do not qualify the
parallel path. At that checkpoint the runtime source-identity gate remained open; the
attempted runtime producer stopped at stale frozen capture-observer locks.
Those assets, trust constants, and historical seals were retained. The October 24
source-identity rebuild is recorded separately in the final QA report. No new
canonical M7 or fresh full-run stability/performance result follows. See
[current qualification](v4/CURRENT_QUALIFICATION_STATUS.md) and
[known issues](../KNOWN_ISSUES.md).
