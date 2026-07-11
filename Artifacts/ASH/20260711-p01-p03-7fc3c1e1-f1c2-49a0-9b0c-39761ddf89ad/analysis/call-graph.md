# P01 Production Call Graph

## Evidence boundary

This is a static trace of the current production source. It identifies concrete calls, storage, synchronization, and CPU/GPU boundaries. It does not assign a percentage of elapsed runtime to any stage; that requires a completed production run with reconciled stage totals and a profiler trace.

## Construction and injection

`MirmirForsettiBootstrap` is main-actor isolated and constructs the media and engine services (`Mirmir/App/MirmirForsettiBootstrap.swift:7`, `:23`, `:39-48`). The bootstrap supplies a factory that creates a new production recorder for each accepted job. `DefaultUpscalerEngineService.submit` reserves its single active-job slot, obtains that job's recorder, and creates an AVFoundation pipeline scoped to the same recorder before constructing the handle (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:9-24`, `:30-55`; `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:7-9`, `:36-49`). The handle then passes that isolated recorder to the production ASH backend and conditional Lanczos pass (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:68-84`, `:177-194`).

## End-to-end path

1. The production Start button calls `MirmirViewModel.startUpscale()` (`Mirmir/Modules/UI/Views/MirmirUpscaleWorkspaceView.swift:412-422`). `MirmirViewModel` is `@MainActor` (`Mirmir/Modules/UI/MirmirViewModel.swift:87`) and submits an `UpscaleJob` at `Mirmir/Modules/UI/MirmirViewModel.swift:299-312`.
2. `DefaultUpscalerEngineService.submit` verifies that input and output are distinct, atomically reserves the only active-job slot, rejects overlap with `jobAlreadyRunning`, creates the job recorder and matching media scope, then creates and starts the handle (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:30-55`; typed error at `Mirmir/Modules/UpscalerEngine/UpscalerEngineService.swift:3-24`).
3. `DefaultUpscalerJobHandle.start` opens a telemetry run and launches a detached user-initiated task. Its terminal `defer` finishes progress delivery and releases the engine reservation (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:92-133`). The task can resume on different executor threads after suspension; no stable OS thread is declared.
4. `runJob` opens security-scoped resources, probes the asset, chooses a route, constructs the output profile, and begins the media session (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:147-175`).
5. The job-scoped `AVFoundationMediaPipeline.probe` loads track metadata and records the `media_probe` interval (`Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:51-97`). `beginSession` records `reader_setup` and constructs `AVFoundationMediaSession` with the same recorder (`Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:99-108`, `:184-296`).
6. Reader output requests IOSurface-backed, Metal-compatible, video-range NV12 (`420v`) and sets `alwaysCopiesSampleData = false` (`Mirmir/Modules/MediaPipeline/AVFoundationMediaSessionConfiguration.swift:15-34`). The request does not independently prove decoder zero-copy behavior.
7. Each loop iteration obtains a sample with `copyNextSampleBuffer`, extracts its `CVPixelBuffer` and PTS, and records `frame_read` (`Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:298-330`; caller at `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:200-202`).
8. The engine dequeues a destination buffer and invokes `ASHDeterministicUpscaleBackend.process` (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:204-207`).
9. The backend locks and copies the complete luma plane into `[Double]` and the complete chroma storage into `[UInt8]` (`Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:30-37`, `:56-106`). This is the current `canonicalize` interval and remains CPU work.
10. `ASHTileProcessor.process` builds a serial tile list and allocates a full output `[Double]` (`Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:221-265`). For every tile it copies a crop, performs same-coordinate history/reset analysis, computes chroma energy, maps the patch, and records selected state/message/operator telemetry (`Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:269-319`, `:322-342`, `:371-390`).
11. `ASHReferencePipeline.mapPatch` records luma analysis and state packing, generates a runtime branch tree, then evaluates the selected candidate path (`Mirmir/Modules/UpscalerEngine/ASH/ASHReferencePipeline.swift:14-76`).
12. `ASHBranchTree.generate` allocates a 121-node depth-four tree with 81 leaves for every tile and increments `runtime_tree_generations` (`Mirmir/Modules/UpscalerEngine/ASH/ASHBranchTree.swift:19-69`).
13. `ASHReconstruction.generateTopCandidates` decodes all leaf messages, records a candidate count of 16 for the current tree, forms a nearest-expanded basis, evaluates all 16 message operators, and retains the requested top-k (`Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:222-270`, `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstructionHelpers.swift:9-52`). Production passes `topK: 1`, but `evaluatedCount` remains 16 (`Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:38-43`).
14. The backend writes luma to the destination in a CPU full-frame loop and reconstructs chroma with coordinate-quantized nearest sampling in another CPU full-frame loop (`Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:109-190`).
15. Direct 1080p-to-4K sends that buffer to the writer. The 720p route first creates a 2560x1440 intermediate pool and invokes `LanczosPolishPass` (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:181-194`, `:209-216`).
16. `LanczosPolishPass` bridges NV12 luma and chroma planes through `CVMetalTextureCache`, encodes one MPS command buffer per plane, and records created/committed observations (`Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:24-103`). This is the only production GPU boundary visible in the current source.
17. The writer path polls `isReadyForMoreMediaData` with a one-millisecond task suspension, appends the video buffer at source PTS, drains optional audio with the same polling pattern, and awaits `finishWriting` (`Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:333-412`).
18. On writer completion, `AtomicMediaOutput.commit` moves or replaces the final destination (`Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:395-403`, `:444-453`; `Mirmir/Modules/MediaPipeline/AtomicMediaOutput.swift:39-54`). No output reopen occurs before publication.

## Cancellation and error edges

- Task cancellation calls `session.cancel()` through `withTaskCancellationHandler`; all other job errors also call `session.cancel()` before propagation (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:176-177`, `:254-262`).
- Session cancellation serializes lifecycle state with `NSLock`, cancels active reader/writer objects, and requests partial-file deletion (`Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:414-453`).
- The UI ignores source replacement while a job is running and a cancellation request does not return the workflow to ready until the handle terminates (`Mirmir/Modules/UI/MirmirViewModel.swift:121-124`, `:222-234`, `:299-370`).
- Every job terminal path releases the service's single-flight reservation through the detached task's `defer`; a new recorder is created only for a subsequently accepted job (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:34-55`, `:98-101`).
- Partial deletion failures increment `partial_cleanup_failures` and record the error (`Mirmir/Modules/MediaPipeline/AtomicMediaOutput.swift:56-67`).
- The Lanczos path still commits before adding its completion handler (`Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:94-101`). The supplied baseline records an assertion abort on this ordering. Process abort bypasses in-process cancellation and cleanup.

## Current proof limits

- `Date`-based progress throughput is not a stage profiler (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:196-253`).
- CPU loops and allocation sites are source-proven; their runtime shares are not inferred from the static call graph.
- No production call to `recordGPUTime` exists, so zero GPU timing fields cannot be interpreted as zero GPU time.
- No `temporal_fuse` or `reopen_verify` production interval is present.

## Runtime confirmation

The final one-frame direct-route capture executes this path under process `Mirmir (51165)`. `analysis/signpost-validation.json` reports `pass`: for every one of the 20 catalog names, raw begin and end counts equal completed trace interval counts and the in-memory telemetry count. The zero-count `temporal_fuse`, `audio_process`, and `reopen_verify` entries also match across both mechanisms; they remain unexecuted operations, not performance measurements. The retained telemetry is `runtime/telemetry-signpost-final.json`, SHA-256 `1daab305ff3319b5430c19102af1aced811033bc6fd2524dd9267dad6e15c045`.
