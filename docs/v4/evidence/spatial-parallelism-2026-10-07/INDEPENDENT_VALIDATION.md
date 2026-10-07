# Independent pre-change spatial validation

The actual pre-change implementation versus the new default spatial path measured **6.91× at 1920×816** and **7.97× at 3840×1632**, using ten alternating measured pairs per size after five warmup pairs. All 60 complete calls, including warmups, matched every reference pixel and conditioning control; old and new output digests agree. Original Ferris PID 30948 remained active.

| Geometry | Original source median | New source median | Ratio of medians | Median paired ratio | Paired range | Paired Q1–Q3 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 1920×816 | 21.922 ms | 3.175 ms | 6.905× | 6.928× | 6.681–16.061× | 6.873–7.293× |
| 3840×1632 | 99.776 ms | 12.518 ms | 7.971× | 8.018× | 5.533–9.530× | 7.417–9.337× |

Observed scope: the complete production `ASHSpatialReconstructorV4.reconstructInPlace` call, including integrity/geometry/full-sample/program/control validation, retained scratch preparation, cancellation check, and stencil. The new path also includes saved boundary rows, dispatch and join. Input reset, canonical-program/reference construction, full pixel/control comparisons and SHA256 calculation occur outside the timer. Both binaries retain their own scratch and output arrays across calls.

Input uses the same `spatial-extrema-and-texture-v1` arithmetic as the QA fixture, with payload 85 (raw state 340), canonical program and code range 64...940. Reset uses an exclusive mutable output borrow before timing; output storage identity was unchanged during every timed call. The new automatic path used 14 workers, confirmed by actual scratch counts of 130,560 and 261,120 samples (261,120 and 522,240 bytes). Both binaries kept scratch allocation count 1 and a stable scratch identity through every measured call. Cold first-call allocation is retained in the raw warmup records. No observations were removed.

Observed provenance: the baseline binary was compiled from the exact complete production temporal/spatial module at Git `817f1f2f56f5b59a5d36818505c368e12069bf48`; the candidate binary used the frozen current module. Eight complete production source files were compiled in each binary. The sole extra dependency is the exact unchanged complete `ASHExecutorV4` enum declaration copied from the production execution-plan file. All other production dependencies, the generated harness, compiler, SDK, source order and flags were identical. These standalone executables do not use XCTest or start the application.

Both use Apple Swift 6.4, language mode 5, arm64 macOS 15.4 target, macOS 27.0 SDK, `-O -whole-module-optimization -warnings-as-errors -module-name IndependentSpatialValidation`. The raw JSON includes the exact shared flags and each invocation argv. `{REPO_ROOT}` in portable argv is explicitly normalized from the captured absolute checkout path; external compiler/SDK/app paths retain their captured values. Receipt references use repository-relative paths. Original absolute argv and original receipts remain preserved locally.

| Input | SHA256 |
| --- | --- |
| Original temporal/spatial module | `b3d6bb8d4d10dc23f1f85836c5df4b8a41fba7910c5f2674779a7f4bcae68ce5` |
| Candidate temporal/spatial module | `18883dcbdefefc05275560cfeab79b8c44db4cd04e44ca401ab3e7745792d559` |
| Shared harness | `bea9cc650da0e97a28760671583fda3d5d26a853f8606582b63f96089cb022fd` |
| Unchanged serial row/cancellation/commit source | `85f54a9cd91df5d5481ef7b873dec1810f12d5c2fd0fa593b3841da3a5c3da91` |
| Unchanged reference function source | `2ee8bc26f9bf7c39abe22f79ca17e50ef6180c8aaf365d65a6e231f14a45a814` |

Every dependency declaration/file, executable, source receipt and raw capture is hashed in [portable validation](independent-validation.json). The old and new references themselves have byte-identical source. The actual original binary is a separate control, independent of selecting `.serial` in the updated XCTest build.

| Geometry | Identical old/new output SHA256 |
| --- | --- |
| 1920×816 | `3cafd49707029ae4cacbd098c781d1fadde816af34c0fe0c2740ca312911a0b4` |
| 3840×1632 | `c90e71cf752f203be98b0e71f8a052e98ad2492082d8fc9cd3a64e34d5fbb764` |

Capture ran 2026-10-07T19:16:43.957278+00:00 through 2026-10-07T19:16:47.601388+00:00. The capture window began after all native builds/tests completed, and process snapshots before/after each geometry show no known build/test overlap. Ferris remained live and the production module and both executable hashes were unchanged before/after capture. Both standalone processes held an identical Foundation processing activity.

The original XCTest attachment was independently recomputed: at 3840×1632 its five measured pairs produce **8.911×** as the ratio of medians, median paired ratio **8.864×**, and paired range **8.410–9.440×**. That number is supported by the original samples. This separate actual-pre-change capture measured **7.971×**, so the multiplier varies across captures. At 1920×816 the original ratio was 9.220× and the separate result was 6.905×. Raw original and independent paired values and dispersion are preserved in the JSON.

Unverified: whole-engine/movie speedup, real-media and every pixel format, full-length completion on the new app, Intel execution and performance for payloads beyond 85. This spatial-stage timer excludes resampling, motion search, temporal history, measurement, encoding, checkpoints and I/O. Ten pairs establish observed local timing and dispersion; no confidence interval or constant multiplier is claimed. The exact cause of the observed latency variation remains unknown.

Local receipts: [raw capture](../../../../output/spatial-parallelism-2026-10-07/independent-spatial-validation/independent-spatial-raw.json), [source proof](../../../../output/spatial-parallelism-2026-10-07/independent-spatial-validation/source-provenance.json), [compiler/argv proof](../../../../output/spatial-parallelism-2026-10-07/independent-spatial-validation/compile-provenance.json), [shared harness](../../../../output/spatial-parallelism-2026-10-07/independent-spatial-validation/IndependentSpatialHarness.swift), [capture driver](../../../../output/spatial-parallelism-2026-10-07/independent-spatial-validation/run-independent-spatial.py), [capture log](../../../../output/spatial-parallelism-2026-10-07/independent-spatial-validation/independent-spatial-capture.log). Local binary/log/output receipts are excluded from the source publication; the portable JSON contains raw measured and warmup records, exact shared/source/executable hashes, controls, scratch/storage assertions and statistics.
