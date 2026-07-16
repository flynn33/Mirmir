# P01 Production Time-Profile Sample Aggregation

## Measurement boundary

This report covers one attached Time Profiler window only. The trace table of contents records a 30-second limit, 30.617131-second trace duration, termination because the time limit was reached, a Debug product path, an injected test bundle, and `LLVM_PROFILE_FILE`. The exported sample table spans 30.336999 seconds.

The associated harness config names a one-frame 1920x1080 input and requests 3840x2160; the production selector maps that pair to `direct2x` (`MirmirTests/ASHTelemetryTests.swift:8-40`; `Mirmir/Modules/UpscalerEngine/UpscaleStrategy.swift:38-48`). This capture therefore does not exercise the conditional Lanczos route.

**Do not generalize this window to product wall time.** Debug code generation, coverage instrumentation, test injection, and profiler attachment can perturb execution. The trace reached its time limit; the capture alone is not completion evidence.

Inputs:

- `/Users/jimdaley/GitHub/Mirmir/Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/production-time-profile.xml` — SHA-256 `374632ff7612857064e87fe5aad71a51f7f4948b3d981d4ccf6d8c2443654b4d`
- `/Users/jimdaley/GitHub/Mirmir/Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/production-time-profiler-toc.xml` — SHA-256 `a6cf9c837faf26e5dc4015e032a950da38f7fc752a74a4760af9e03b8546f3d5`

## Reproducible method

`aggregate_time_profile.py` resolves the export’s `id`/`ref` dictionaries for weights, backtraces, frames, binaries, and source paths. It defines:

- **inclusive stack-presence weight:** each sample contributes its weight once to every distinct source-backed production symbol present in its backtrace;
- **exact leaf weight:** a sample contributes to a production symbol only when frame zero is that source-backed symbol;
- **source-backed production symbol:** a `Mirmir.debug.dylib` frame whose source path is under the repository’s `Mirmir` directory;
- **memory-related stack:** frame zero matches the script’s explicit memory-copy, allocator/release, or array-storage classifier, grouped by the nearest source-backed production frame.

Inclusive rows are nested and not additive. Exact leaf weight excludes runtime and standard-library leaves even when their nearest production caller caused the operation.

## Total samples and weight

| Measure | Result |
|---|---:|
| Exported sample rows | 30,316 |
| Weight per row | 1.000 ms |
| Total sampled weight | 30,316 ms |
| Rows containing a source-backed production symbol | 30,313 |
| Corresponding sampled weight | 30,313 ms (99.990104%) |
| Rows whose exact leaf is in the product binary | 2,271 |
| Corresponding exact product-binary leaf weight | 2,271 ms (7.491094%) |
| Exported sample-time span | 30.336999 s |

The 30,316 ms figure is sampled weight, not an independently measured job wall time.

## Production-symbol aggregation

The machine-readable result includes 148 product-binary symbols, including compiler-generated frames, and a separately filtered set of 72 source-backed production symbols. The table below reports the major source-backed call chain and work symbols.

| Production symbol | Inclusive weight | Inclusive share | Exact leaf weight | Exact leaf share | Source anchor |
|---|---:|---:|---:|---:|---|
| `ASHDeterministicUpscaleBackend.process` | 30,298 ms | 99.940625% | 0 ms | 0% | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:43` |
| `ASHTileProcessor.makeTileContext` | 30,230 ms | 99.716321% | 0 ms | 0% | `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:294` |
| `ASHReferencePipeline.mapPatch` | 30,173 ms | 99.528302% | 0 ms | 0% | `Mirmir/Modules/UpscalerEngine/ASH/ASHReferencePipeline.swift:53` |
| `ASHReconstruction.generateTopCandidates` | 29,602 ms | 97.644808% | 0 ms | 0% | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:247` |
| candidate-loop closure | 29,525 ms | 97.390817% | 0 ms | 0% | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:254` |
| `ASHReconstruction.makeCandidate` | 28,495 ms | 93.993271% | 0 ms | 0% | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:311` |
| `ASHReconstruction.applyOperator` | 21,240 ms | 70.062013% | 35 ms | 0.115451% | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:38` |
| `ASHMessage.bits` getter | 18,770 ms | 61.914501% | 38 ms | 0.125346% | `Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:165` |
| `ASHReconstruction.sourceConsistencyScore` | 6,838 ms | 22.555746% | 2 ms | 0.006597% | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:147` |
| `ASHReconstruction.blockMeanDownsample` | 2,283 ms | 7.530677% | 33 ms | 0.108853% | Definition: `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:95-125`; trace carried no positive line for this symbol |
| `ASHReconstruction.gradientEnergy` | 2,093 ms | 6.903945% | 21 ms | 0.069270% | Definition: `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:110-139`; trace carried no positive line for this symbol |
| `ASHReconstruction.makeOperatorBasis` | 1,021 ms | 3.367859% | 0 ms | 0% | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:11` |
| `ASHImage.init(width:height:channels:values:)` | 610 ms | 2.012139% | 16 ms | 0.052777% | Definition: `Mirmir/Modules/UpscalerEngine/ASH/ASHImageFeatures.swift:9-22`; trace carried no positive line for this symbol |
| `ASHFeatureExtractor.extract` | 535 ms | 1.764745% | 0 ms | 0% | `Mirmir/Modules/UpscalerEngine/ASH/ASHImageFeatures.swift:122` |
| `ASHReconstruction.blurAxis` | 461 ms | 1.520649% | 11 ms | 0.036284% | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:89` |
| `ASHFeatureExtractor.boxBlur3` | 385 ms | 1.269956% | 4 ms | 0.013194% | `Mirmir/Modules/UpscalerEngine/ASH/ASHImageFeatures.swift:203` |

The largest exact production leaf is the closure inside `ASHMessage.bits`: 409 samples / 409 ms / 1.349123%. The trace assigns its closure a compiler-generated line; its enclosing source is `Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:164-168`. Other high leaf weights are `ASHImage.value` at 51 ms (`Mirmir/Modules/UpscalerEngine/ASH/ASHImageFeatures.swift:75-77`) and `ASHReconstruction.index` at 41 ms (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:145-147`).

## Allocation and memory-copy sampled stacks

Two related views are retained. The exact-leaf categories are disjoint because each sampled leaf is assigned to at most one classifier category.

| Leaf category | Samples | Weight | Share of total sampled weight |
|---|---:|---:|---:|
| Allocator or release | 3,441 | 3,441 ms | 11.350442% |
| Memory copy (`memmove`/`memcpy`) | 916 | 916 ms | 3.021507% |
| Array-storage growth/initialization | 103 | 103 ms | 0.339755% |

The broader whole-stack view searches every frame. Its category totals overlap, while its union is deduplicated by sample:

| Backtrace matcher | Samples | Weight | Share of total sampled weight |
|---|---:|---:|---:|
| Any `libsystem_malloc.dylib` frame | 3,662 | 3,662 ms | 12.079430% |
| Any `memmove`/`memcpy`/`bcopy` frame | 916 | 916 ms | 3.021507% |
| Any `memset`/`bzero` frame | 658 | 658 ms | 2.170471% |
| Any Swift allocation/deallocation primitive | 320 | 320 ms | 1.055548% |
| Deduplicated union of those four matchers | 5,284 | 5,284 ms | 17.429740% |

The most concentrated nearest-caller groups are:

| Category | Nearest source-backed production caller | Weight | Source anchor |
|---|---|---:|---|
| Allocator or release | `ASHMessage.bits` | 1,829 ms | `Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:165` |
| Memory copy | `ASHMessage.bits` | 651 ms | `Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:165` |
| Array storage | `ASHMessage.bits` | 96 ms | `Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:165` |
| Allocator or release | `ASHReconstruction.applyOperator` | 436 ms | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:38` |
| Allocator or release | `ASHReconstruction.sourceConsistencyScore` | 263 ms | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:147` |
| Allocator or release | `ASHImage.init` | 224 ms | Definition: `Mirmir/Modules/UpscalerEngine/ASH/ASHImageFeatures.swift:9-22` |
| Allocator or release | `ASHReconstruction.gradientEnergy` | 175 ms | Definition: `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:110-139` |
| Allocator or release | `ASHReconstruction.blockMeanDownsample` | 158 ms | Definition: `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:95-125` |

The three exact-leaf `ASHMessage.bits` groups total 2,576 samples / 2,576 ms / 8.497163%. In the broader whole-stack view, the deduplicated union whose nearest source-backed frame is this getter is 3,043 samples / 3,043 ms / 10.037604%. At source level, the getter constructs a four-element array with `map` on every access (`Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:164-168`), while the per-output-element operator loop accesses that getter four times (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:33-50`). The captured allocation/copy stacks and this direct data dependency support a focused improvement: decode or mask the four bits once per candidate, outside the pixel loop. This is a capture-specific hotspot finding, not a release-build speedup claim.

## Correlation with ASH work shape

The sample hierarchy places 97.644808% of weight inside `generateTopCandidates`, 93.993271% inside `makeCandidate`, and 70.062013% inside `applyOperator`. Current source evaluates every decoded message and constructs a candidate before retaining top one (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:239-270`; production `topK: 1` at `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:38-43`).

Separately, the signpost-validated one-frame telemetry artifact records 2,040 runtime trees, 2,040 `candidate_more_than_two` observations, and 165,240 exact leaf decodes. Those counts equal 2,040 tiles and 81 leaf decodes per tile, matching the fixed runtime topology (`Mirmir/Modules/UpscalerEngine/ASH/ASHBranchTree.swift:45-69`). Its `reconstruct_luma` intervals total 15,543.467141 ms, 97.811058% of that artifact’s 15,891.318833 ms `job_total`. Raw begin/end counts, completed trace intervals, and in-memory counts match for every catalog stage (`analysis/signpost-validation.json`). That run used Debug test hosting with `SWIFT_OPTIMIZATION_LEVEL=-O`, coverage disabled, and hardened runtime disabled only for test injection. It is a separate measurement artifact and is not numerically combined with the time-limited Debug+coverage profiler capture.

Together, the independent measurements support the bounded finding that repeated candidate reconstruction is the principal sampled work region in these two explicitly configured test-host measurements. They do not establish Release throughput, a production wall-time ratio, GPU utilization, or the effect size of any proposed change.

## Limitations

- Sample weights are not wall-clock duration; inclusive percentages are nested and cannot be summed.
- Exact leaf weights understate production responsibility when the sampled leaf is a runtime or standard-library helper; memory stacks are therefore reported separately.
- The memory classifier measures sampled leaves only. A missing sample does not prove an allocation, copy, or readback is absent.
- The trace is Debug with coverage and test injection, covers the direct route, and ended at its time limit.
- No Release trace, GPU trace, or before/after implementation comparison is included.
