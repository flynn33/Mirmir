# Spatial reconstruction parallelism — 1.7.0 (17)

The production change is in the existing `ASHSpatialReconstructorV4.reconstructInPlace` and workspace. Large planes use bounded horizontal CPU stripes; small planes retain the original serial loop. Both prepared-engine callers use the automatic policy. No validation, arithmetic, temporal ordering, authentication or recovery gate was removed.

Base revision: `817f1f2f56f5b59a5d36818505c368e12069bf48`. [Engine](../../../../Mirmir/Modules/UpscalerEngine/ASHTemporalReconstructionV4.swift), [tests](../../../../MirmirTests/ASHTemporalReconstructionV4Tests.swift), [implementation and scope](../../../DETERMINISTIC_SPATIAL_PARALLELISM.md), [remaining plan](../../../DETERMINISTIC_HARDWARE_UTILIZATION_PLAN.md).

## Recorded stage timing

Optimized Release XCTest on My Mac arm64, Xcode 27.0 (27A266a), macOS 27.0.1 (26A434), M4 Pro with 14 CPU cores and 48 GiB RAM. Five warmup pairs precede five alternating measured pairs for each geometry and 1/2/4/8/14 worker limit. Inputs use the deterministic `spatial-extrema-and-texture-v1` pattern. The complete in-place call is timed, including validation, controls, storage preparation, halo capture, dispatch and join. Input reset and exact reference comparisons occur outside the timer.

| Geometry | Workers | Serial median | Parallel median | Ratio | Scratch |
| --- | ---: | ---: | ---: | ---: | ---: |
| 512×512 | 14 | 3.762 ms | 0.606 ms | 6.20× | 68 KiB |
| 1024×256 | 14 | 3.785 ms | 0.551 ms | 6.86× | 136 KiB |
| 1920×816 | 14 | 22.571 ms | 2.448 ms | 9.22× | 255 KiB |
| 3840×1632 | 14 | 91.325 ms | 10.248 ms | 8.91× | 510 KiB |

Every pixel and conditioning control equals the independent reference. Scratch is `(5W−2)×width×2` bytes, bounded by active CPU count and nonempty stripes. At width 3840 and 14 workers this is 522,240 bytes. The automatic parallel threshold is 262,144 samples. [Unchanged raw XCTest attachment](raw-benchmark.json), [recomputed medians](benchmark-summary.json), [byte-identical serial-loop proof](serial-baseline-equivalence.json).

Ferris remained active on the installed 1.6.0 app. These synthetic spatial-stage measurements establish a measured local improvement. They do not establish whole-engine or whole-movie elapsed time, GPU occupancy, or a faster installed Ferris run.

## Independent old-source comparison

A second capture compiled the actual pre-change production module and current module into separate optimized arm64 binaries with the same compiler, shared dependencies and harness. With no build/native test host overlapping, five warmup pairs and ten alternating measured pairs produced **99.776 → 12.518 ms (7.971×)** at 3840×1632 and **21.922 → 3.175 ms (6.905×)** at 1920×816. All warmup/measured pixels, controls and cross-binary output hashes match the unchanged reference; scratch stayed allocated once and timed output storage did not copy. Ferris remained active. The recorded 8.91× first result is a valid observation, while the independent result shows the multiplier varies between captures. Both cover the spatial stage. [Independent methodology and limits](INDEPENDENT_VALIDATION.md), [raw samples, compiler/source hashes and dispersion](independent-validation.json).

## Verification and limits

Fresh version-aligned **1.7.0 (17)** checks passed: full native Debug **635 passed, zero failed, six skipped**; full Release **630 passed, zero failed, six skipped**; explicit 8K CPU allocation gate **1/1 passed**. Native Debug/Release test builds and the universal production Release build succeeded with warnings treated as errors and zero compiler warnings/errors. The universal app reports 1.7.0 (17), contains arm64 and x86_64, and passes strict signature verification. The actual project also built in Xcode’s Any Mac destination with an empty, unfiltered Issue Navigator. These are build and native test results; the earlier parity incident remains unresolved. [Publication checks and original-receipt digests](publication-verification.json), [exact built source/project/version hashes](FINAL_SOURCE_SHA256SUMS).

The pre-version-update candidate passed full Debug (635 passed, six skipped), focused Debug (39 passed, two skipped), the explicit 8K bounded CPU allocation gate, and three serialized Thread Sanitizer spatial tests with no race reports. Debug and Release builds treated compiler warnings as errors and reported none. Full Release passed 630 tests, failed one strict decoded H.264 equality check and skipped five; the spatial timing capture passed. [Initial native checks](initial-verification.json).

The later four-run CPU/Metal/same-backend repeat passed. An actual original-HEAD control also passed after all 399 production sources were matched to the base revision, but its unsigned host and initial fixed-home preference warning make it a different host configuration. Neither passing repeat explains the retained failing result.

The development M7 synthetic capture matched all 840 baseline output artifacts across 168 cases and five variants; quality index 122.792052 and paired-bootstrap 95% lower bound 122.312761. Its 64×48 frames select the serial path. This unsealed working-tree capture is not a new committed or packaged qualification, and `releaseQualityGatePass=false` remains recorded.

[Open qualification evidence](OPEN_QUALIFICATION.md) records the decoded parity incident and canonical runtime producer/source-identity failure. Runtime assets, expected trust constants, historical locks and strict test assertions remain unchanged. Full-movie DV4-002, Intel execution, a new installed-app acceptance run and the earlier untraced 157-frame mismatch remain unverified. Source publication does not close these gates.

Raw `.xcresult`, build logs, generated products and synthetic failed MOV attachments are preserved locally under `output/spatial-parallelism-2026-10-07/` and `output/publication-1.7.0-17-2026-10-07/`. They are excluded from the source commit; this directory retains portable numerical evidence and failure summaries.
