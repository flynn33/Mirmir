# Bounded parallel motion benchmark — 2026-10-06

The final native optimized Release XCTest `ASHTemporalReconstructionV4Tests.testCaptureParallelMotionBenchmarkWhenRequested` passed: one test, zero failures. The retained XCTest attachment is copied unchanged into [motion-parallel-benchmark.json](motion-parallel-benchmark.json).

## Environment and result

- Xcode 27.0 (27A266a), macOS 27.0.1 (26A434), native arm64.
- Apple M4 Pro with 14 CPU cores: 10 performance and 4 efficiency.
- Release compilation used `-O`, whole-module optimization, and `ENABLE_TESTABILITY=YES` for the XCTest bundle. This is an optimized test build.
- Five measured pairs per geometry, alternating serial-first and parallel-first. Each mode had a warm-up before measurement.
- Parallel policy used 14 workers. `MirmirProcessingActivity` remained active across both modes, and the motion executor requested `.userInitiated` QoS.

| Luma plane | Serial median (seconds) | Parallel median (seconds) | Ratio of medians | Identical fields |
| --- | ---: | ---: | ---: | --- |
| 1920 × 816 | 0.077411708 | 0.011989584 | 6.456580× | true |
| 3840 × 1632 | 0.312957834 | 0.048316292 | 6.477273× | true |

The final measurements include the scoped, read-only sample-buffer borrows used during each full-frame block search and supersede the earlier benchmark runs. The test measured one full-frame motion analysis per sample, including validation, scene histogram, matching, fixed-order merge, and field validation. Inputs were generated textured luma planes with a two-pixel horizontal translation. Frame generation, warm-up, JSON encoding, and field equality assertions were outside each timed interval. Every measured field was asserted equal to the serial reference, including motion vectors and evidence values.

These ratios cover this motion-analysis fixture. They do not measure decoding, scaling, reconstruction, diagnostics, encoding, segment assembly, tiled motion, total movie completion time, CPU frequency, or device utilization. The independently inspected native 4K job is documented separately in [the production-job receipt](PRODUCTION_JOB.md).

## Final build and completion verification

[final-verification.json](final-verification.json) records the final native Debug suite (628 passed, zero failed, five opt-in skips), Release suite (623 passed, zero failed, five opt-in skips), and universal production Release build. All three commands emitted zero compiler warnings or errors. The Release test command enables testability without changing the production Release setting. The app contains arm64 and x86_64 slices and identifies as 1.6.0 (16).

[FINAL_SOURCE_SHA256SUMS](FINAL_SOURCE_SHA256SUMS) binds the final production files, tests, and Xcode project. Local original logs, `.xcresult` bundles, and kept media are outside Git in `Mirmir-1.6.0-Build16-Evidence` on the owner's Desktop. The final GUI Issue Navigator could not be rechecked while the Mac was locked.

[ntsc-parity-investigation.json](ntsc-parity-investigation.json) retains an earlier untraced Release decoded-frame mismatch and the subsequent four matching traced runs. Its cause remains unknown: the earlier run lacks pre-encoder capture, and instrumentation changes timing. Input, pre-encoder output, timing, and decoded-frame checks passed in the traced CPU/Metal and same-backend repeats; strict assertions remain enabled. These receipts do not close the pre-existing P06 source-closure gate or qualify a full-length movie speedup.

## Invocation and provenance

The following commands show the build and test invocation with portable local artifact paths in place of the run's host-specific paths:

```sh
xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath ./build/motion-release \
  ONLY_ACTIVE_ARCH=YES ENABLE_TESTABILITY=YES \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES \
  build-for-testing

xcodebuild test-without-building \
  -xctestrun ./build/motion-release/Build/Products/Mirmir-final-borrowed-motion-benchmark-quiet.xctestrun \
  -destination 'platform=macOS,arch=arm64' -parallel-testing-enabled NO \
  -resultBundlePath ./build/motion-benchmark.xcresult \
  -only-testing:MirmirTests/ASHTemporalReconstructionV4Tests/testCaptureParallelMotionBenchmarkWhenRequested
```

The benchmark `.xctestrun` configured the test target's `EnvironmentVariables` with `MIRMIR_V4_MOTION_BENCHMARK_SAMPLES=5` and `MIRMIR_V4_MOTION_BENCHMARK_DIR` set to a writable sandbox directory. The worker override was absent, so the test used the host's active processor count. The kept JSON attachment provides the portable result independently of that directory.

[SHA256SUMS](SHA256SUMS) records the benchmark data and the frozen motion implementation, benchmark/oracle tests, processing activity, and prepared-engine caller. Hashes were computed directly from file bytes using SHA-256. From the repository root, the source hashes can also be reproduced with:

```sh
shasum -a 256 \
  Mirmir/Modules/UpscalerEngine/ASHTemporalReconstructionV4.swift \
  MirmirTests/ASHTemporalReconstructionV4Tests.swift \
  Mirmir/App/MirmirProcessingActivity.swift \
  Mirmir/Upscaling/Deterministic/PreparedDeterministicV4Upscaler.swift

shasum -a 256 -c docs/v4/evidence/motion-parallelism-2026-10-06/SHA256SUMS
```
