# P01 ASH Failure-Pattern Classification

## Method and evidence boundary

The pinned independent-reference audit is treated as supplied evidence. Each reference finding is mapped to current Swift source and existing controlled tests. “Confirmed by construction” means the current Swift data dependencies reproduce the same invariant without requiring a timing inference. No new quality or performance claim is made here.

## Reference finding classification

### F01 — State-independent branch priors

**Classification: `present`.**

The supplied audit reports identical aggregate priors for all 256 integrity-valid source states and identical fixed-source rankings. In Swift, `sourceState` affects only the affine node state (`sourceState.xor(codeword)`), while message transitions and branch weights depend only on path, level, and fixed action weights (`Mirmir/Modules/UpscalerEngine/ASH/ASHBranchTree.swift:15-16`, `:47-62`). Reconstruction decodes those affine states back to messages and sums their unchanged weights (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:278-298`).

**Causal chain:** source state changes affine representation -> affine decode recovers the same path message -> fixed path weights sum to the same message priors -> reference-policy candidate ranking receives no state-conditioned branch mass.

Existing tests verify one tree’s 121 nodes, 81 leaves, 16 messages, and total weight (`MirmirTests/ASHFeatureBranchReconstructionTests.swift:36-48`). They do not exhaustively require dispatch variation over all valid source states.

### F02 — Neutral message dominates the reference first frame

**Classification: `modified_but_still_noncausal`.**

The supplied audit records message `0000` as top-one for 1,000 first-frame random patches. The Swift reference golden vector also selects message 0 first (`MirmirTests/ASHFeatureBranchReconstructionTests.swift:157-183`). The current production configuration uses an adaptive feature score (`Mirmir/Modules/UpscalerEngine/ASH/ASHRuntimeConfiguration.swift:53-56`; `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:55-75`), and controlled fixture tests demonstrate multiple messages and at least four nonzero messages (`MirmirTests/ASHInternalAlphaTests.swift:38-51`, `:86-99`).

The mitigation reads continuous feature values, not the packed state as a dispatch index. It therefore demonstrates content-dependent selection but does not close the state-causality requirement.

### F03 — Four operator aliases reduce 16 nominal messages to 12 behaviors

**Classification: `present`.**

Message bit 2 adds the isotropic detail term and bit 3 subtracts the identical term (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:44-49`). When both bits are active, the two terms cancel before clamping. This preserves the supplied alias pairs `0000~0011`, `0100~0111`, `1000~1011`, and `1100~1111` for the current CPU operator basis.

The existing CPU/Metal parity test covers one message, not all 120 descriptor pairs. No current test requires all 16 descriptors to be behaviorally distinct over a discrimination suite.

### F04 — Branch geometry cannot affect branch priors

**Classification: `present`.** Geometry is absent from the Swift branch API, so it cannot influence priors.

The supplied audit reports that turn-angle and length-decay changes leave priors unchanged. The Swift branch API exposes no geometry parameter; it uses fixed action order, fixed action weights, and level-based message-bit toggles (`Mirmir/Modules/UpscalerEngine/ASH/ASHBranchTree.swift:15-22`, `:47-62`, `:89-96`). Geometry therefore cannot influence message mass or dispatch in this implementation.

## Correlated production failure patterns

### F05 — Runtime tree generation and 16 candidate evaluations occur per tile

**Classification: `present`.** The work shape is source-confirmed, and repeated reconstruction is measured as the dominant region in the bounded execution evidence.

The backend uses 32x32 tiles and `topK: 1` (`Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:38-43`). Each tile still generates a 121-node/81-leaf tree and evaluates all 16 messages (`Mirmir/Modules/UpscalerEngine/ASH/ASHBranchTree.swift:45-69`; `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:222-270`). Telemetry now exposes runtime-tree generations and records the current candidate population in the `more_than_two` bucket.

The signpost-validated one-frame telemetry artifact records 2,040 runtime-tree generations, 2,040 `candidate_more_than_two` observations, and 165,240 exact decodes: 81 leaf decodes per tile. Its `reconstruct_luma` intervals total 15,543.467141 ms, or 97.811058% of that artifact's 15,891.318833 ms `job_total`. The retained trace has matching begin, end, completed-interval, and telemetry counts for all 20 catalog stages (`analysis/signpost-validation.json`). This run used Debug test hosting with `SWIFT_OPTIMIZATION_LEVEL=-O`, coverage disabled, and hardened runtime disabled only for test injection; it is not characterized as ordinary Debug or Release.

A separate 30-second Debug+coverage attached Time Profiler capture places 29,602 ms of 30,316 ms sampled weight (97.644808%) inside `generateTopCandidates`, 28,495 ms (93.993271%) inside `makeCandidate`, and 21,240 ms (70.062013%) inside `applyOperator`. Inclusive weights are nested and the capture reached its time limit; these values describe that window only and are not a release-build or wall-time generalization. Full method and hashes are in `production-time-profile-aggregation.md` and `production-time-profile-aggregation.json`.

### F05a — Per-pixel message-bit materialization creates a concentrated memory-work pattern

**Classification: `present`.** Source inspection and sampled stacks correlate this pattern within the bounded Debug capture.

`ASHMessage.bits` constructs a four-element array through `map` on every getter access (`Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:164-168`). The operator loop accesses the getter four times per output element (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:33-50`). The profiler assigns 18,770 ms inclusive sampled weight (61.914501%) to the getter. Memory-classified leaves whose nearest source-backed caller is this getter contribute 1,829 ms of allocator/release weight, 651 ms of `memmove`/`memcpy` weight, and 96 ms of array-storage weight. A broader deduplicated whole-stack matcher for malloc-library, move/copy, set/zero, and Swift allocation/deallocation frames assigns 3,043 ms (10.037604% of total sampled weight) to stacks whose nearest source-backed frame is this getter.

This supports hoisting bit decoding outside the pixel loop or using raw masks as the smallest focused improvement. It does not quantify the speedup of that change; a controlled before/after Release trace is required.

### F06 — Nearest-expanded luma basis and nearest chroma remain production substrates

**Classification: `present`.** The nearest-neighbor substrates are source-confirmed and remain assigned to the quality phases.

The luma operator basis begins with `nearestUpsample` (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:9-13`; implementation at `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:74-93`). Chroma uses integer coordinate mapping and direct source-pair copies (`Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:158-190`). These facts align with the supplied quality evidence: distinct pixels were produced, but improvement over controls was not demonstrated.

### F07 — Temporal scoring uses same-coordinate history without motion correspondence

**Classification: `present`.** The same-coordinate behavior is source-confirmed; the telemetry label is semantically incomplete.

The interval named `motion_estimate` wraps only history/reset classification (`Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:278-285`). That classification computes same-coordinate mean absolute difference (`Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:322-342`). Candidate temporal loss compares current and prior reconstructions at identical array positions (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:161-173`). No motion vector, forward/backward check, occlusion flag, or warped correspondence is present.

### F08 — 720p route aborts before cleanup

**Classification: `present`.** The supplied failure remains source-reproducible.

`LanczosPolishPass` commits before registering its completion handler (`Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:94-101`). The supplied evaluation records an assertion abort and a zero-byte hidden partial. In-process cleanup handles thrown errors and task cancellation, but a process abort bypasses those paths.

### F09 — Publication occurs without reopen verification

**Classification: `present`.** Publication without reopen verification is source-confirmed and assigned to G02.

On writer `.completed`, the session calls `commitOutput`, which moves or replaces the destination (`Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:395-403`, `:444-453`; `Mirmir/Modules/MediaPipeline/AtomicMediaOutput.swift:39-54`). No `AVURLAsset` reopen/inspection occurs before publication, and the `reopen_verify` telemetry stage has no production caller.

### F10 — Audio eligibility is based on returned track count, not enabled-track policy

**Classification: `present`.** The track-count policy is source-confirmed and consistent with the supplied media failure.

When audio preservation is requested, all audio tracks are loaded and count greater than one is rejected (`Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:201-207`). The supplied original contained one enabled AAC and one disabled APAC track and was rejected as two tracks.

## Improvement priorities supported by these correlations

1. Replace state-independent runtime branch generation with offline state-conditioned dispatch and require a controlled state-disabled comparison.
2. Replace the four aliasing descriptors so all 16 records are behaviorally distinct over a preregistered fixture suite.
3. Remove nearest-expanded luma and nearest chroma from the production reconstruction substrate.
4. Repair command-buffer completion ordering and status/error collection before rerunning the 720p route.
5. Add reopen verification before atomic publication and preserve crash-recovery evidence for recognized stale partials.
6. Add real motion correspondence before interpreting temporal stability as temporal reconstruction.
7. Eliminate per-pixel message-bit array construction, then rerun the same locked workload in Release and compare stage totals plus profiler samples.
8. Reduce or replace all-message candidate reconstruction only after a state-conditioned dispatch design defines which candidates remain causally required.

## Explicit limitations

- The supplied reference audit proves properties of the pinned independent reference. Swift equivalence is asserted only where current Swift data dependencies reproduce the same invariant.
- Existing fixture tests show adaptive content variation; they do not prove packed-state causal dispatch.
- The source audit does not establish visual improvement, GPU utilization percentage, or maximum in-flight resources.
- Runtime shares reported for F05/F05a are restricted to the named successful telemetry artifact and the separate Debug+coverage profiler capture. They are not assumed to be the same run and are not generalized to Release or overall product wall time.
