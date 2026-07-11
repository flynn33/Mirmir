# P04 Quality-Harness Evidence

This run records the G04 benchmark-and-metric-integrity checkpoint.

The evidence contains the locked 12-asset native-high-resolution corpus metadata, six exact development samples, deterministic degradation and metric policies, analytic metric fixtures, a real H.264 software-codec fixture, an interrupted production run preserved under a distinct failed-run path, and its fully recomputed successful run. The production control contains 24 engine-domain rows, 24 isolated post-encode rows, two H.264 route writer runs, and 24 one-case HEVC writer runs. Holdout media and evaluation results were not opened.

Native regression evidence includes seven focused Xcode tests, the complete 113-test suite with one documented G01-only opt-in skip, a Release build, strict lint, and source-attribution scanning. The complete Python suite passed 80 tests without failures or skips.

`GATE_REPORT.md` records the gate decision. `analysis/failure-pattern-correlation.md` identifies recurring failure classes and the controls required in later phases. `analysis/production-run-verification.json` and `analysis/final-correctness-review.json` record the semantic and publication checks. `artifact-manifest.json` binds every file in this run directory except the manifest itself.

This checkpoint validates the measurement system and pre-change control. It makes no claim that the existing ASH algorithm meets the final visual-quality thresholds.
