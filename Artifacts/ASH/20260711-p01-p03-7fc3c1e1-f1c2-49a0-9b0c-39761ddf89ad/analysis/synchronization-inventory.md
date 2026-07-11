# P01 Synchronization, Allocation, and Copy Inventory

## Execution and synchronization

| ID | Mechanism | Scope | Evidence | Classification |
|---|---|---|---|---|
| S01 | Main actor | Bootstrap and view-model submission | `Mirmir/App/MirmirForsettiBootstrap.swift:7-23`; `Mirmir/Modules/UI/MirmirViewModel.swift:87`, `:299-312` | UI isolation |
| S02 | Detached task | Complete upscale job | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:92-133` | Task can change executor threads after suspension |
| S03 | AsyncStream newest-one buffer | Progress delivery | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:62-89` | Older unconsumed progress values may be replaced |
| S04 | Task cancellation handler | Session teardown | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:176-177`, `:254-262` | Calls `session.cancel()` |
| S05 | Session `NSLock` | Lifecycle state | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:179-182`, `:414-453` | Serializes active/cancelled/committed checks |
| S06 | Recorder unfair lock | Open intervals, counters, histograms, observations, terminal state | `Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:145-150`, `:178-253`, `:267-399` | Low-level lock around bounded mutable state |
| S07 | Pixel-buffer base-address locks | Luma/chroma extraction and destination writes | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:56-58`, `:85-87`, `:109-120` | CPU access synchronization |
| S08 | Writer readiness polling | Video and audio append | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:333-344`, `:365-385` | One-millisecond task suspension loop |
| S09 | Writer completion await | Container finalization | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:388-412` | Async writer completion |
| S10 | Shared Metal command queue | Conditional Lanczos plane commands | `Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:67-94`; queue ownership at `Mirmir/Modules/MetalRendering/DefaultMetalRenderingService.swift:13-36` | One command buffer per plane |
| S11 | Checked continuation | Lanczos completion | `Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:94-103` | Invalid ordering remains: handler registered after commit |
| S12 | Cooperative cancellation checks | Frame, tile, row, and candidate loops | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:200-225`; `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:27-53`, `:75-80`, `:99-104`; `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:245-249`; `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:252-268` | Cancellation latency depends on loop checkpoint spacing |
| S13 | Service unfair lock | Single active-job reservation | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:14`, `:30-55`, `:98-101` | Overlapping submit is rejected; every terminal path releases the reservation |
| S14 | Per-job recorder factory and media scope | Telemetry isolation across accepted jobs | `Mirmir/App/MirmirForsettiBootstrap.swift:39-48`; `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:9-24`, `:42-50`; `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:7-9`, `:36-49` | Engine, media session, backend, and conditional polish share only the current job recorder |
| S15 | Main-actor running-state guard | Source selection and cancellation convergence | `Mirmir/Modules/UI/MirmirViewModel.swift:121-124`, `:222-234`, `:299-370` | Source replacement is ignored during a job; cancel remains running until handle termination |

## Storage, allocation, and copy sites

| ID | Site | Storage transition | Allocation/reuse fact | Evidence |
|---|---|---|---|---|
| C01 | Reader output | Compressed track to NV12 `CVPixelBuffer` | Reader requests IOSurface/Metal compatibility and `alwaysCopiesSampleData = false`; actual decoder copy behavior is not proven by this flag | `Mirmir/Modules/MediaPipeline/AVFoundationMediaSessionConfiguration.swift:15-34` |
| C02 | Output pool | Pool to destination NV12 buffer | Pool created per media session with requested threshold 8 | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:267-271`; `Mirmir/Modules/MediaPipeline/PixelBufferBridge.swift:12-35` |
| C03 | Intermediate pool | Pool to 2560x1440 NV12 buffer | Created only for 720p route with requested threshold 6 | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:181-194` |
| C04 | Luma extraction | NV12 Y bytes to full-frame `[Double]` | New array per frame; one value per source luma sample | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:56-82` |
| C05 | Chroma extraction | NV12 CbCr storage to full-frame `[UInt8]` | New array per frame; copies each byte through `bytesPerRow`, including padding | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:85-106` |
| C06 | Tile crop | Full-frame `[Double]` to tile `[Double]` | New cropped array per tile | `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:371-390` |
| C07 | Frame output | Empty full-frame `[Double]` | New stitched output per frame | `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:240-256` and state initialization at `:103-119` |
| C08 | Runtime tree | Value arrays of nodes/frontiers | 121 nodes and 81 leaves allocated per tile at depth four | `Mirmir/Modules/UpscalerEngine/ASH/ASHBranchTree.swift:45-69`; count test at `MirmirTests/ASHFeatureBranchReconstructionTests.swift:36-48` |
| C09 | Operator basis | Nearest-expanded image plus horizontal, vertical, and isotropic detail arrays | New basis per tile | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:9-25` |
| C10 | Candidate evaluation | Basis to candidate images and downsample/gradient arrays | Current topology evaluates 16 messages; production retains top one | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:222-270`; `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:38-43` |
| C11 | Destination luma | Full-frame `[Double]` to NV12 Y bytes | Full-frame CPU write | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:132-156` |
| C12 | Destination chroma | Source NV12 CbCr to destination NV12 CbCr | Full-frame CPU nearest-coordinate copy | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:158-190` |
| C13 | Lanczos bridge | NV12 planes to `CVMetalTexture` views | Texture wrappers created for both source and destination planes per invocation | `Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:51-65`; `Mirmir/Modules/MediaPipeline/PixelBufferBridge.swift:49-80` |
| C14 | Writer append | Destination `CVPixelBuffer` to encoder | Sequential append in one job loop; encoder internals are opaque to this source audit | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:200-225`; `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:333-357` |

## Measured versus unmeasured

- The optimized direct-route telemetry run observes four full-frame CPU loop counts and four full-frame copy counts for its one frame (`Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:30-37`, `:122-129`). It does not record bytes copied. Run context: Debug test hosting, `SWIFT_OPTIMIZATION_LEVEL=-O`, coverage disabled, and hardened runtime disabled only for test injection.
- No production call updates `full_frame_gpu_readbacks`; absence of an update is not a verified zero-readback measurement.
- No production call updates `in_flight_frames`; pool thresholds do not establish actual maximum concurrency.
- The recorder has a GPU-time API (`Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:13`, `:256-265`), but the production path does not call it.
- The signpost-validated optimized direct-route telemetry run places 15,543.467141 ms of its 15,891.318833 ms `job_total` in `reconstruct_luma` (97.811058%) and 15,543.467141 ms of its 15,725.812417 ms `frame_total` there (98.840472%). The raw signpost begin/end counts, completed interval counts, and in-memory counts match for every catalog stage (`analysis/signpost-validation.json`).
- A separate time-limited Debug+coverage attached profile places 29,602 ms of 30,316 ms sampled weight in `generateTopCandidates` (97.644808%), 28,495 ms in `makeCandidate` (93.993271%), and 21,240 ms in `applyOperator` (70.062013%). This directionally reconciles stage concentration with the production call hierarchy; the runs are separate and their absolute values are not combined.

## Profiler-observed memory-related stacks

The separate attached profile contains 30,316 one-millisecond running-stack samples. Whole-backtrace matchers produce overlapping category totals; the union is deduplicated by sample.

| Matcher | Sampled weight | Share of total |
|---|---:|---:|
| Any `libsystem_malloc.dylib` frame | 3,662 ms | 12.079430% |
| Any `memmove`/`memcpy`/`bcopy` frame | 916 ms | 3.021507% |
| Any `memset`/`bzero` frame | 658 ms | 2.170471% |
| Any Swift allocation/deallocation primitive | 320 ms | 1.055548% |
| Deduplicated union | 5,284 ms | 17.429740% |

Within that deduplicated union, 3,043 ms (10.037604% of all sampled weight) has `ASHMessage.bits` as the nearest source-backed production frame. The getter constructs a four-element array with `map` (`Mirmir/Modules/UpscalerEngine/ASH/ASHState.swift:164-168`), and `applyOperator` accesses it four times inside each output-element iteration (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:33-50`). Exact aggregation rules and all 135 leaf-stack groups are in `production-time-profile-aggregation.json`.

These are sampled stack weights, not allocation counts, copy-byte counts, wall time, or Release-build measurements. The profiler capture covers the direct route and does not measure GPU execution or establish zero GPU readback.
