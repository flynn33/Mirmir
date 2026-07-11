# P01 Telemetry Coverage

## Scoped G01 result

The catalog contains all 20 required interval names and all 16 required counter names (`Mirmir/Modules/Telemetry/ASHTelemetryCatalog.swift:3-23`, `:51-67`). Static production-call-site coverage is 18 of 20 intervals and 13 of 16 counters. The traced one-frame direct production route emitted balanced stage timing, ASH decisions, copy/loop counts, and a successful terminal record through the explicit evidence harness. The retained Logging trace contains matching begin, end, completed-interval, and telemetry counts for every catalog stage, including matched zero counts for operations not executed by this fixture (`analysis/signpost-validation.json`).

**G01 can pass for the traced direct production route.** The two catalog intervals without callers represent operations not implemented or executed in this route: real temporal fusion belongs to G10, and reopen verification plus conditional command-buffer completion belongs to G02. Final locked-schema packaging and route-complete GPU/in-flight evidence belong to G11. Their absence is retained explicitly here and is not represented as a measured zero. The app job path still discards the terminal snapshot returned by `finish`, while the evidence harness snapshots and serializes it (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:102-132`; `Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:256-265`, `:377-400`; `MirmirTests/ASHTelemetryTests.swift:30-84`). The signpost validator reports `pass`, no unexpected names or event types, no nonpositive completed intervals, and exact count agreement for all 20 stages.

This scoped pass does not pass G02, G10, or G11 and does not claim the Lanczos route, temporal fusion, reopen verification, GPU timing, readback count, or maximum in-flight count is complete.

## Required interval matrix — 20 of 20 catalog entries audited

| # | Interval | Production status | Production evidence | Qualification |
|---:|---|---|---|---|
| 1 | `media_probe` | Instrumented | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:51-97` | Measures asynchronous source inspection. |
| 2 | `reader_setup` | Instrumented | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:99-108` | Wraps media-session setup. |
| 3 | `frame_read` | Instrumented | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:298-330` | Measures sample acquisition and frame record construction. |
| 4 | `canonicalize` | Instrumented | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:27-37` | Measures CPU extraction of full-frame luma and chroma arrays. |
| 5 | `analyze_luma` | Instrumented | `Mirmir/Modules/UpscalerEngine/ASH/ASHReferencePipeline.swift:19-25` | Per-tile feature extraction. |
| 6 | `analyze_chroma` | Instrumented | `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:291-293` | Per-tile chroma-energy calculation. |
| 7 | `motion_estimate` | Instrumented, semantically incomplete | `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:278-285`, `:322-342` | Wraps same-coordinate history-reset classification; no motion vector or warped correspondence is computed. |
| 8 | `state_pack` | Instrumented | `Mirmir/Modules/UpscalerEngine/ASH/ASHReferencePipeline.swift:26-28` | Per-tile feature binarization and state construction. |
| 9 | `dispatch_decode` | Instrumented | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:191-198`, `:239-246` | Decodes every leaf and forms message priors. |
| 10 | `reconstruct_luma` | Instrumented, mixed semantics | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:199-216`, `:247-270`; `Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:45-52` | Aggregates CPU ASH candidate generation and conditional GPU Lanczos luma work under one name. |
| 11 | `reconstruct_chroma` | Instrumented, mixed semantics | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:122-129`; `Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:45-52` | Aggregates CPU chroma copy and conditional GPU Lanczos chroma work under one name. |
| 12 | `temporal_fuse` | Not executed; G10-owned future operation | Catalog only: `Mirmir/Modules/Telemetry/ASHTelemetryCatalog.swift:15` | Current same-coordinate scoring is not treated as completed temporal fusion. |
| 13 | `telemetry_reduce` | Instrumented, CPU-only meaning | `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:309-313` | Wraps three locked CPU histogram updates; it is not a GPU reduction/readback interval. |
| 14 | `writer_backpressure` | Instrumented | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:333-344` | Measures readiness polling, including one-millisecond task suspensions. |
| 15 | `writer_append` | Instrumented | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:345-357` | Measures video adaptor append. |
| 16 | `audio_process` | Conditionally instrumented | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:359-386` | Exists only when both passthrough audio output and writer input exist. |
| 17 | `writer_finish` | Instrumented | `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:388-390` | Measures `finishWriting`; output commit occurs after the interval. |
| 18 | `reopen_verify` | Not executed; G02-owned future operation | Catalog only: `Mirmir/Modules/Telemetry/ASHTelemetryCatalog.swift:21`; publication at `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:395-403`, `:444-453` | Output is published without reopening and validating the written asset. |
| 19 | `frame_total` | Instrumented | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:200-225` | Covers backend, optional polish, and append for each video frame. |
| 20 | `job_total` | Instrumented | `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:92-133` | Covers asynchronous job execution through success, cancellation, or failure. |

## Required counter matrix — 16 of 16 catalog entries audited

| # | Counter | Production status | Production evidence | Qualification |
|---:|---|---|---|---|
| 1 | `state_histogram_512` | Instrumented | `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:309-313`; recorder at `Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:278-290`, `:402-424` | One selected source-state observation per tile. |
| 2 | `message_histogram_16` | Instrumented | Same anchors as counter 1 | One selected message observation per tile. |
| 3 | `operator_histogram_16` | Instrumented with duplicate input | `Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:309-313` | Receives the same `selected.message.rawValue` as the message histogram; it does not independently identify an executed operator. |
| 4 | `decode_exact` | Routed through production decode | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:278-298`; `Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:292-300` | Can increment when a decoded leaf reports exact. |
| 5 | `decode_corrected` | Routed through production decode | Same anchors as counter 4 | Call path exists; current generated affine leaves do not inject a one-bit error, so a positive current-production observation is not demonstrated. |
| 6 | `decode_rejected` | Routed through production decode | Same anchors as counter 4 | Call path exists; current generated affine leaves do not inject an uncorrectable error, so a positive current-production observation is not demonstrated. |
| 7 | `candidate_one` | Routed through production candidate count | `Mirmir/Modules/UpscalerEngine/ASH/ASHReconstruction.swift:191-199`, `:239-247`; recorder at `Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:303-313` | The current topology supplies 16 decoded messages, so this bucket is not expected to increment on the traced path. |
| 8 | `candidate_two` | Routed through production candidate count | Same anchors as counter 7 | The current topology supplies 16 decoded messages, so this bucket is not expected to increment on the traced path. |
| 9 | `candidate_more_than_two` | Instrumented and positive on current topology | Same anchors as counter 7 | Records one observation per tile with the current 16-message population. |
| 10 | `runtime_tree_generations` | Instrumented | `Mirmir/Modules/UpscalerEngine/ASH/ASHBranchTree.swift:19-31` | Increments once for every runtime tree generation. |
| 11 | `full_frame_cpu_loops` | Instrumented as declared site counts | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:30-37`, `:122-129` | Four increments per backend frame; neither duration nor bytes touched is represented. |
| 12 | `full_frame_gpu_readbacks` | No observer; direct route has no GPU polish | Catalog only: `Mirmir/Modules/Telemetry/ASHTelemetryCatalog.swift:63` | The artifact's zero is not claimed as verified absence; route-complete evidence belongs to G11. |
| 13 | `full_frame_copies` | Instrumented as declared site counts | `Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:30-37`, `:122-129` | Four increments per backend frame; copy bytes and framework-internal transfers are not measured. |
| 14 | `command_buffer_errors` | No observer; G02-owned conditional route | Catalog only: `Mirmir/Modules/Telemetry/ASHTelemetryCatalog.swift:65`; observations at `Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:67-101` | The direct route created no command buffers; completion status/error repair is G02 work. |
| 15 | `in_flight_frames` | No observer; G11-owned route-complete evidence | Catalog only: `Mirmir/Modules/Telemetry/ASHTelemetryCatalog.swift:66` | Pool thresholds do not measure actual concurrent frames or a maximum; no zero claim is made. |
| 16 | `partial_cleanup_failures` | Instrumented on cleanup-error path | `Mirmir/Modules/MediaPipeline/AtomicMediaOutput.swift:56-67` | Increments only when removal of an existing temporary output throws; a process abort bypasses this observer. |

## Recorder and artifact boundary

- Each accepted production job receives a new recorder from the engine's factory. Before the handle starts, the AVFoundation service is cloned into a job scope backed by that same recorder; the handle supplies it to the media session, ASH backend, and conditional Lanczos pass (`Mirmir/App/MirmirForsettiBootstrap.swift:39-48`; `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:9-24`, `:30-55`, `:68-84`, `:177-194`; `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift:7-9`, `:36-49`).
- An unfair-lock-protected single-flight reservation prevents concurrent jobs from mixing telemetry. Overlap is rejected with `jobAlreadyRunning`, and terminal `defer` releases the reservation (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:14`, `:30-55`, `:98-101`; `Mirmir/Modules/UpscalerEngine/UpscalerEngineService.swift:3-24`).
- The recorder uses paired token identity, monotonic timestamps, bounded sample/event arrays, an unfair lock, and percentile/total snapshots (`Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:145-175`, `:193-265`, `:429-573`).
- `recordGPUTime` exists but has no production caller (`Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:256-265`; production-call search recorded in `commands.log`).
- Command-buffer observations have fields for status, error, and GPU timestamps, but production supplies only `created` and `committed` (`Mirmir/Modules/Telemetry/ASHTelemetryModels.swift:68-99`; `Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift:67-101`).
- `finish` creates and returns a snapshot, but every app job caller discards the return value; no app-path serializer or artifact writer was found (`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:102-132`; `Mirmir/Modules/Telemetry/ASHTelemetryRecorder.swift:377-400`).
- The explicitly configured test harness calls `snapshot`, checks selected fields, and writes JSON (`MirmirTests/ASHTelemetryTests.swift:30-84`). This is an evidence seam, not app-path persistence. A separate regression test proves sequential accepted submissions use two distinct recorders and matching media scopes (`MirmirTests/ASHTelemetryTests.swift:8-27`).

## Observed successful direct-route telemetry artifact

Artifact boundary:

- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/telemetry-signpost-final.json` — SHA-256 `1daab305ff3319b5430c19102af1aced811033bc6fd2524dd9267dad6e15c045`
- Associated config — SHA-256 `38f10c03b9e2caa5df38e151593853ebad43054747f26c021d2d2e52bcb87618`
- One 1920x1080 frame to 3840x2160, HEVC, audio disabled; result reports `success` and balanced intervals.
- Run context: Debug test hosting with `SWIFT_OPTIMIZATION_LEVEL=-O`, coverage disabled, and hardened runtime disabled only to permit test injection. This is not characterized as an ordinary Debug build or a Release build.

Native result-bundle verification:

- `tests/focused-p01-p03-pass.xcresult`: 18 passed, 0 failed, 0 skipped, overall `Passed`.
- `tests/full-debug-pass.xcresult`: 82 passed, 0 failed, 1 skipped, overall `Passed`. The sole skip is `test_productionTraceFixtureWhenExplicitlyConfigured`, whose explicit configuration is supplied only for the evidence run (`MirmirTests/ASHTelemetryTests.swift:30-35`).
- `runtime/production-signpost-xcodebuild.log`: the explicitly configured route passed 1 test with 0 failures in 15.963 seconds.

Retained signpost validation:

- `analysis/signpost-validation.json` — status `pass`, SHA-256 `2a7d14c5e81524868389e2fb35f6ccd0f54860b4d5a7015423b64d4160e59dff`.
- Process filter: `Mirmir (51165)`; subsystem `com.mirmir.ash.engine`; category `ASH`.
- `runtime/production-signposts-raw.xml` — SHA-256 `e35c9d7fa9f28e245077224eb74239e4891a6645cdd7f4ecdb2a93f677146c7f`.
- `runtime/production-signpost-intervals.xml` — SHA-256 `135a1a67a53a394ab0bff830bdc7e007417967cd1de2b378a6fe6eb1d42b9151`.
- `runtime/production-signposts-toc.xml` — SHA-256 `a0919e0c4ca06e56efa1b85928a7021976800c877132a287415a4cce8946b3c1`.
- Every stage's raw begin count, raw end count, completed interval count, and in-memory telemetry count match. No unexpected stage name or event type is present.

Observed interval totals:

| Interval | Count | CPU total ms |
|---|---:|---:|
| `media_probe` | 1 | 2.352000 |
| `reader_setup` | 1 | 123.384875 |
| `frame_read` | 2 | 2.129583 |
| `canonicalize` | 1 | 3.688833 |
| `analyze_luma` | 2,040 | 30.862365 |
| `analyze_chroma` | 2,040 | 1.342056 |
| `motion_estimate` | 2,040 | 0.619851 |
| `state_pack` | 2,040 | 1.011721 |
| `dispatch_decode` | 2,040 | 59.344041 |
| `reconstruct_luma` | 2,040 | 15,543.467141 |
| `reconstruct_chroma` | 1 | 1.405833 |
| `temporal_fuse` | 0 | 0 |
| `telemetry_reduce` | 2,040 | 1.122095 |
| `writer_backpressure` | 1 | 0.008083 |
| `writer_append` | 1 | 0.131333 |
| `audio_process` | 0 | 0 |
| `writer_finish` | 1 | 36.463042 |
| `reopen_verify` | 0 | 0 |
| `frame_total` | 1 | 15,725.812417 |
| `job_total` | 1 | 15,891.318833 |

For this artifact only, `reconstruct_luma` is 97.811058% of `job_total` and 98.840472% of `frame_total`. These are elapsed recorder intervals in the explicitly configured optimized test-host run described above, not a Release or general product ratio.

Observed required counters:

| Counter | Value |
|---|---:|
| `state_histogram_512` | 2,040 |
| `message_histogram_16` | 2,040 |
| `operator_histogram_16` | 2,040 |
| `decode_exact` | 165,240 |
| `decode_corrected` | 0 |
| `decode_rejected` | 0 |
| `candidate_one` | 0 |
| `candidate_two` | 0 |
| `candidate_more_than_two` | 2,040 |
| `runtime_tree_generations` | 2,040 |
| `full_frame_cpu_loops` | 4 |
| `full_frame_gpu_readbacks` | 0 |
| `full_frame_copies` | 4 |
| `command_buffer_errors` | 0 |
| `in_flight_frames` | 0 |
| `partial_cleanup_failures` | 0 |

The counts corroborate the source work shape: 81 exact leaf decodes for each of 2,040 tiles, one runtime tree per tile, and one `more_than_two` candidate observation per tile. A zero in an uninstrumented counter remains “not observed,” not proof of absence. The message and operator histograms are identical and place all 2,040 observations in bucket 1 because production passes the same raw message to both recorders (`Mirmir/Modules/UpscalerEngine/ASH/ASHTileProcessing.swift:309-313`). The state histogram has four occupied buckets: 0→94, 129→28, 257→1,888, and 384→30. This occupancy is evidence for this one input only.

Locked-schema validation reports eight errors:

1. Missing root properties: `run`, `environment`, `configuration`, `input`, `route`, and `artifacts`.
2. `media` is an array while the locked schema requires an object.
3. `result.status` is `success`; the locked schema permits `pass`, `fail`, or `blocked`.

The record is syntactically valid JSON but does not yet conform to the locked final telemetry schema. Final schema conformance is retained as G11 work; it is not used to fail this scoped G01 trace result.

## Explicit limitations

- Static call-site coverage and observed execution are distinct. The successful direct-route record establishes only the listed observations.
- The successful direct-route record uses the explicit test-host configuration described above and does not cover the Lanczos route, audio, temporal fusion, or reopen verification.
- No frame-time share, GPU utilization, copy bandwidth, readback count, synchronization cost, or maximum in-flight count is attributed from source alone.
- CPU timing for async intervals includes elapsed suspension time; it is not synonymous with CPU-active time.
- The mixed `reconstruct_luma` and `reconstruct_chroma` labels prevent unambiguous separation of CPU ASH work from conditional GPU polish using aggregate stage totals alone.
- Stage totals and the separate profiler capture both concentrate in candidate reconstruction, which is a bounded directional reconciliation. They are separate runs and their absolute values are not combined.
- G01's scoped pass does not waive or pre-pass G02, G10, or G11.
