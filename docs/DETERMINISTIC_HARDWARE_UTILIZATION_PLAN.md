# Deterministic engine hardware utilization plan

Prepared October 7, 2026 against `817f1f2f56f5b59a5d36818505c368e12069bf48` (1.6.0 build 16). Phase 1 is implemented for 1.7.0 build 17; phases 2–5 remain planned. The base identity above records the investigation baseline. The runtime identity gate and fresh full-run/throughput qualification remain open. The later [finish-stage repair](DETERMINISTIC_FINALIZATION_REPAIR.md) finalized the complete saved Metal job and installed/launched the signed 1.7.0 (17) repair; that recovery did not repeat GPU processing or measure matched whole-movie throughput.

Baseline verification subsequently ran on October 7: native Debug 628 passed, Release 624 passed, a separate Debug 8K allocation check passed, 57 Python contract tests passed, and M7 passed 168 synthetic cases selecting `candidate_v4`. [Baseline results and limits](../output/verification-2026-10-07-dxrupzdd/README.md). These results preceded the spatial change. Current implementation checks and timing evidence are retained separately in [the spatial verification report](v4/evidence/spatial-parallelism-2026-10-07/README.md).

The objective is lower elapsed upscale time through useful CPU/GPU concurrency and bounded reusable memory, with identical quality, validation, authentication, and recovery behavior. Higher resource utilization is supporting evidence; it is not the acceptance criterion.

## Evidence and constraints

The live Ferris investigation on the M4 Pro measured 2.58 average CPU core equivalents over 120 seconds, with short bursts engaging all 14 cores. A separate Metal trace recorded active GPU intervals for about 3% of its capture; shader occupancy, bandwidth and limiter counters were not measured. Physical footprint was 1.7–1.8G, recorded peak footprint 11.7G, with zero swap at inspection. These process measurements do not establish a per-job RAM budget or a memory shortage.

The prepared path orders source capture, source motion/measurement, scaling, output capture, spatial conditioning, output motion, temporal blending and history publication. Motion already uses bounded parallel workers. Several surrounding loops are serial, and Metal execution waits synchronously. This is a verified optimization opportunity; bandwidth, thermal limits, scheduling tails and achievable speedup remain unknown.

Local measurements and source references are in [the hardware report](../output/ferris-hardware-2026-10-07-dpp0p3tp/HARDWARE-UTILIZATION.md) and [the initial profile report](../output/ferris-performance-2026-10-07-uusm43pd/REPORT.md). These untracked evidence directories must remain available locally; they are not portable release evidence.

Every phase must preserve:

- All motion candidates and pixel comparisons, canonical tie order, confidence, occlusion, scene-cut and reset decisions.
- Exact integer arithmetic, ties-to-even rounding, borders, clamping, color/HDR/alpha handling and admitted timestamps.
- Every existing validation pass, including full-plane and off-window packing checks; the original first-error precedence and failure-before-mutation guarantees.
- Full-source authentication at every current segment boundary, timing/HDR preflight, encoded-output verification and durable publication barriers.
- Ordered temporal history, canonical checkpoint format/bytes, pause/resume and rollback/retry behavior. Retain the temporal actor's exclusive-operation guard.

## Implementation order

Each numbered phase is a separate reviewable change, measured before the next change is layered on. A candidate that fails parity, recovery or memory bounds returns to the last verified implementation.

| Phase | Deliverable | Completion gate |
| --- | --- | --- |
| 0 | Reproducible baseline, stage measurements and identity audit | Existing behavior and measurement scope are explicit; no active Ferris disruption |
| 1 | Bounded parallel spatial stripes | Exact serial/reference equality, bounded storage and measured benefit |
| 2 | Complete parallel validation/copy scans, histograms and temporal blocks, in separate changes | Every check retained; deterministic errors, pixels and history |
| 3 | Same-frame CPU analysis overlapped with staged GPU scaling | Owned buffer lifetimes, unchanged error/publication behavior and lower elapsed time |
| 4 | Optional exact GPU conditioning/blending, then matching or scaler tuning | Counters justify the work; CPU/GPU parity and runtime binding pass |
| 5 | Integrated native-media, recovery and full-movie qualification | Faster uninstrumented runs with identical output and no stability regression |

### Phase 0 — Establish the comparison and prerequisites

1. Preserve the original run's checkpoint, terminal diagnostics, profiling evidence, and independently verified recovered movie. The investigation's original app-preservation boundary applied while GPU processing was active. The subsequent authorized finish-stage repair preserved that evidence and installed/launched 1.7.0 (17) after processing had ended. Run a separate isolated whole-movie comparison with explicit source/build identity and no overlapping work.
2. After the run, freeze a development baseline with exact source/toolchain/configuration, input digest, geometry, backend, scale ratio, storage format, power state and thermal observations. Use separate output/cache locations for each comparison.
3. Measure stage wall time, CPU time, worker completion tails, GPU submission/execution/wait time, allocations, peak physical footprint/RSS and memory pressure. Use the existing diagnostics store/journal/export surface for any retained instrumentation; timing captures must not create a second diagnostics system. Compare traced and untraced runs to quantify measurement overhead.
4. Investigate the existing runtime source-closure mismatch before claiming a newly authenticated candidate. It affects Swift production edits as well as shader changes. Reconcile the source manifest, runtime artifacts and bound tool identities through the existing P06 generation/verification workflow. For the finalized candidate, update any changed artifact byte/hash bindings, generate a reproduced bundle/provenance into fresh directories with `build_p06_release_runtime.sh`, audit those identities, then update the candidate bundle and three expected trust constants in `DeterministicEngineV4Support.swift` together. The builder does not update those constants automatically. Verify repository identity and P06 reproduction against the new candidate; preserve historical bundles/seals and the verifier's rejection rules.
5. Investigate the earlier intermittent 157-frame CPU/Metal decoded-output mismatch. Repeat uninstrumented comparisons as well as diagnostic runs; capture exact pre-encoder pixels separately to locate any divergence. A passing traced repeat does not attribute or close the earlier failure.

The identity mismatch and parity incident are documented in [current qualification status](v4/CURRENT_QUALIFICATION_STATUS.md). They do not prevent isolated implementation experiments, but must remain visible until resolved; faster timing does not close either item or DV4-002.

### Phase 1 — Parallel spatial conditioning

Primary surface: `ASHTemporalReconstructionV4.swift`, `ASHSpatialReconstructorV4.reconstructInPlace` and its workspace.

- Partition output into disjoint horizontal stripes with a geometry-dependent worker limit bounded by active CPU count. Retain the serial path for small planes. Select thresholds from Release measurements rather than forcing 14 workers for every input.
- Before any output write, save both original rows around every stripe boundary. Each worker loads its initial ring from its own original stripe and the immutable saved halos. All later reads stay within its own stripe or those halos. Give each worker its own three-row ring; preserve the current stencil and replicated image borders. No worker may read a neighbor's mutating stripe.
- Finish all current state/range/program checks, gain computation, storage preparation and initiating-task cancellation preflight before the nonthrowing mutation phase. Join before returning or publishing history. Preserve cancellation semantics rather than adding partial-write cancellation points.
- Borrow storage within one scoped lifetime; workers receive disjoint mutable regions. Avoid concurrent Swift Array mutation through shared `inout`/copy-on-write storage.

At width 3840 and 14 nonempty stripes, ring plus boundary-row storage is `(3W + 2(W−1)) × width × 2 = 522,240 bytes`, about 0.50 MiB. The implementation asserts this scratch bound and reuse, alongside the existing serial three-row assertions.

Gate: every output sample and returned conditioning control equals the independent reference for all ASH states, border impulses, extrema and rounding ties. Force 1/2/3/7/14 workers on awkward geometries, including one-pixel dimensions, uneven stripes and more requested workers than rows. Existing tiny fixtures alone are insufficient; also exercise native 1920×816 and 3840×1632 Release inputs. Verify scratch reuse and invalid/cancelled input behavior.

October 7 implementation result: the existing serial stencil remains byte-identical, and the two prepared-engine callers use the new automatic policy. Release measurements with five warmup pairs and five alternating measured pairs showed 22.571 → 2.448 ms at 1920×816 and 91.325 → 10.248 ms at 3840×1632 with 14 workers. All pixels and controls matched the independent reference. The 262,144-sample threshold keeps small planes serial; both measured geometries at that threshold benefited from parallelism. These are spatial-stage measurements while Ferris remained active, not full-movie speedups.

The candidate is still gated: Debug passed 635 tests; the Release full suite passed 630 but failed one strict 156-frame decoded H.264 equality check. Its 156 pre-encoder records matched and its 192×128 geometry uses the original serial path. A focused CPU/Metal repeat passed without explaining that failure. Full evidence and unresolved encoding/handoff/assembly questions are in the spatial report. The fresh runtime producer also failed on the pre-existing frozen capture-input lock; no trust root or historical evidence was changed.

### Phase 2 — Other independent CPU work

Implement and measure these individually, in this order:

1. **Complete validation and copy scans.** Partition the existing loops without removing or merging away checks. Each chunk returns its earliest failure; choose the result in original plane/row/pixel/component order, regardless of completion order. Join validation before its original mutation boundary. Preserve pixel-buffer locking, chroma, padding and valid video-range excursion policy.
2. **Histograms.** Use private exact integer bins and a fixed-order reduction. Scan the same full current/previous planes; preserve scene-cut evidence and every decision derived from the bins.
3. **Temporal blend.** After the complete existing vector/layout/range/weight preflight, process disjoint output blocks with immutable previous history. Join before publishing pixels/history. Keep fallback/reset behavior exact.

Primary surfaces: `PixelBufferSignalCodecV4`, `ASHMeasurementExtractorV4`, `ASHTemporalMotionAnalyzerV4` and `ASHTemporalReconstructorV4`. If profiling still shows motion join tails, separately test smaller row batches with unchanged candidate evaluation and row-major result/error order. Raising the worker ceiling is not the initial change; current motion already reaches all 14 cores.

Gate: compare all samples, bins, motion fields, confidence/occlusion, measurement state and checkpoint bytes. Inject two distinguishable bad samples in different chunks with reversed completion order; match the serial first error. Include malformed P010 packing outside the 32×32 evidence window and at the final chroma code. Check caller/workspace/history immutability wherever the current contract guarantees it. Exercise forced workers, concurrent callers, cancellation and failure before commit.

### Phase 3 — Overlap CPU analysis with GPU scaling

Primary surfaces: `PreparedDeterministicV4Upscaler.processProgressive`, `FixedPointPixelBufferScalerV4` and `FixedPointMetalPreparedBatchV4`.

Start with one staged GPU operation for the same frame. After unchanged source validation, submit fixed scaling into owned staging storage while CPU source motion/measurement reads immutable source/history. Defer download and caller-destination publication until CPU analysis has passed and the GPU has completed. Preserve the original CPU-before-scaler error precedence even if both operations fail.

Separate submission/completion ownership from the current upload/wait/download critical section using the existing executor patterns. Retain source/destination pixel buffers, Metal scratch and leases until all consumers complete. On analysis failure, GPU failure, cancellation or pause, drain/discard staged work before reuse and publish no partial state. Keep ordered frame history and the operation guard.

A second independent scaling slot is a later experiment only if one slot leaves measured idle gaps and its lifetime/cap tests pass. It requires explicit maximum in-flight leases; the pixel-buffer pool's minimum count is not a maximum. Any lookahead must retain authentication barriers and ordered history/encode/checkpoint commits.

Gate: inject delayed CPU/GPU completions, simultaneous failures and cancellation at each handoff. Confirm original error precedence, no destination/history publication on failure, no early buffer reuse, exact retry and pause/resume. Validate progressive first, then interlaced, telecine and forced-tiled paths before enabling the change on those routes. Accept only measured end-to-end benefit.

### RAM policy across phases 1–3

Allocate memory for measured concurrency or reuse, with geometry-derived limits and explicit lifetimes. Do not reserve a large arbitrary fraction of the Mac's RAM.

For Ferris, source pixels `S=1,566,720` and target pixels `T=6,266,880`. Existing UInt16 Metal source/output sample buffers require `3(S+T)`, about 22.41 MiB; three source/output luma workspace pairs require `6(S+T)`, about 44.82 MiB. Another GPU slot adds roughly 22.41 MiB of sample storage plus codec surfaces, padding and other ownership costs. These are buffer calculations, not total job footprint estimates.

Record planned/actual bytes, allocation count and high-water marks. Preserve the declared temporal-history memory allowance. Verify bounds across geometry changes, long runs, cancellation and resume; reject unbounded growth or memory-pressure-induced throughput regression. Investigate which allocations produced the existing 11.7G peak. Byte-identical streaming checkpoint encoding is a later candidate only if allocation profiling proves its current JSON intermediates materially affect time or memory; keep cadence and canonical bytes unchanged.

### Phase 4 — Optional additional GPU work

Proceed only after phases 1–3 are reprofiled. Capture shader occupancy and limiter counters while kernels run; the earlier 3% activity-time observation cannot identify a kernel bottleneck.

Evaluate exact spatial conditioning first, temporal blending second, and complete motion matching separately. Keep integer widths, rounding, border behavior, every candidate/pixel comparison and canonical reductions. Retain the CPU reference and strict parity tests. Rebuild and bind shader/executor/source identities through the verified runtime workflow before authenticated qualification.

Separately benchmark scaler threadgroup shapes, border-index preparation, threadgroup caching or an exact separable implementation if counters justify them. Metal 4 support alone does not select an optimization. Do not substitute approximate/neural processing for the current deterministic algorithm, or silently change the selected backend when a GPU path fails.

Gate: bit-exact CPU/GPU output and fields across the supported format/geometry matrix, unchanged failure/recovery behavior, bounded scratch, and lower total elapsed time including transfers and synchronization. Retain only changes that pass these gates.

## Verification and acceptance

Run focused checks after each implementation, then the area's normal native suites. All existing strict assertions remain; new tests must force the new paths.

| Area | Existing coverage to retain and extend |
| --- | --- |
| Spatial | `testThreeRowSpatialWorkspaceMatchesReferenceForEveryState`; `testInPlaceConditioningCancellationAndInvalidFieldNeverMutate` |
| Motion | `testParallelMotionMatchesIndependentSortedOracleAtUnevenEdges`; `testParallelMotionPreservesTiesOcclusionAndSceneCut`; repeated/concurrent and tiled equivalents |
| Input/Metal boundaries | `testP010ValidationIgnoresPaddingAndRejectsEveryLowBitInLastChromaCode`; `testMetalRejectsMalformedScheduleBeforeRetainedInputMutation`; `testDirectTransferRejectsOverlappingStorageBeforeDispatch` |
| Recovery | `testPreparedCheckpointProducesByteIdenticalProgressiveResume`; `testInterlacedFailureAndCancellationRollbackForByteIdenticalRetry`; `testTiledCancellationLeavesCanonicalStateAndSeekRetryExact`; telecine/tiled checkpoint equivalents |
| Workflow | `testParallelDeterministicCPUAndMetalFinalize66FrameNTSCJob`, 156-frame and 157-frame counterparts; `testParallelDeterministicMetalPauseResumePreservesDecodedFrames` |
| Authentication/publication | `testActivatedSnapshotRejectsRetainedWritableMappingWithUnchangedMetadata`; `testTamperedPrivateSourceSnapshotFailsClosedAcrossRelaunch`; `testPublicationRejectsTamperedVerifiedStageBeforeFinalRename`; `testFreshTerminalSourceCompletenessFailureStopsBeforeFinalization` |

Phase 5 runs native Debug and Release tests on **My Mac arm64**, warnings as errors, plus concurrency race checking for the new ownership paths. Verify the universal production Release build separately. Hardware-dependent Metal checks must actually execute; report skips as missing coverage. Cover NV12/P010, HDR/alpha where supported, integer/noninteger scaling, borders, progressive/interlaced/telecine and forced-tiled routes. A native fixture is not an Apple Simulator destination.

For performance, use identical Release input/configuration and stable power/thermal conditions, without concurrent builds or other upscale jobs. First compare forced 1/2/4/8/14-worker stage timings using five warmups and at least ten alternating paired samples. Validate exact results outside microbenchmark timers. Then measure uninstrumented end-to-end short and representative media runs, including unchanged authentication, validation, checkpoint, encode and finalization costs. Retain raw timings, median/p95, paired confidence intervals, footprints and pressure observations. Reject a result whose apparent gain cannot be separated from run-to-run noise or whose stability/latency regresses.

Complete a matched full Ferris before/after comparison with the same media/configuration and independent final output verification. Short-job speedups and synthetic benchmarks do not establish full-movie time. Keep this new comparison against 1.6.0 separate from the frozen-P05 qualification; no numerical new-version speedup is promised by this plan.

Re-run the adopted [M7 simulation qualification](v4/M7_SIMULATION_QUALIFICATION_V1.md) at the final clean committed candidate state using `script/v4/run_m7_simulation_v4.sh`. Preserve its quality index and paired-bootstrap lower bound of at least 105, and total/median/p95 processing-time ratios at most 0.80 of frozen P05. M7 uses headless XCTest on macOS; its adopted scope does not require archive signing, distribution or a physical-device matrix. The older [packaged performance lane](v4/PERFORMANCE_QUALIFICATION_V1.md) remains a distinct documented workflow, not an added M7 shipping requirement. Do not alter locked evidence or thresholds to accept a candidate.

Each phase's evidence records the source identity, exact change, tests executed/skipped, output/checkpoint equality, raw performance results and memory limits. Preserve the last verified baseline and existing cache/checkpoints. Source publication for 1.7.0 build 17 does not close the documented parity, source-identity, or matched-throughput gates. The separately authorized installed repair and saved full-job finalization are recorded in the [repair evidence](v4/evidence/end-finalization-repair-2026-10-07/README.md).

## Source anchors

- [Temporal reconstruction](../Mirmir/Modules/UpscalerEngine/ASHTemporalReconstructionV4.swift): worker policy, motion analysis, histogram, spatial/temporal in-place reconstruction and block-layout preflight.
- [Prepared engine](../Mirmir/Upscaling/Deterministic/PreparedDeterministicV4Upscaler.swift): workspaces, progressive/tiled processing, history/checkpoint publication and exclusive-operation guard.
- [Pixel-buffer codec](../Mirmir/Modules/UpscalerEngine/PixelBufferSignalCodecV4.swift): complete validation and luma transfer boundaries.
- [Metal executor](../Mirmir/Modules/UpscalerEngine/FixedPointMetalExecutorV4.swift) and [scaler](../Mirmir/Modules/UpscalerEngine/FixedPointPixelBufferScalerV4.swift): retained storage, locks and synchronous completion.
- [Metal shader](../Mirmir/Modules/UpscalerEngine/FixedPointMetalKernelsV4.metal): current exact scaler.
- [Queue](../Mirmir/Persistence/WorkflowApplicationQueueV4.swift) and [coordinator](../Mirmir/App/WorkflowApplicationCoordinatorV4.swift): source authentication and durable segment processing.
- [Runtime identity verifier](../script/v4/repository_identity_v4.py), [P06 source identity](../script/v4/p06_source_identity_v4.py) and [qualification status](v4/CURRENT_QUALIFICATION_STATUS.md): provenance and unresolved qualification limits.
- [Release runtime builder](../script/v4/build_p06_release_runtime.sh) and [engine trust constants](../Mirmir/Upscaling/Deterministic/DeterministicEngineV4Support.swift): reproduced candidate generation and audited deployment binding.
