# G04 Gate Report

## G04 — Benchmark and metric integrity: pass

The native-high-resolution corpus is locked as 12 source assets split by asset into six development, three validation, and three holdout records. Every record binds source bytes, provenance and rights evidence, dimensions, frame range, category, route eligibility, color metadata, and canonical display geometry. The corpus manifest hash is `7271022b4c78f7cb04b9be01773cd0d0a0e190580fa808456e5d90caf0d8ec6a`; its file hash is `244def78bcecc419f4a28d1660c75e83500399727955256e5e3218ce9a7cd234`.

The deterministic degradation policy covers both required routes and includes a real Apple H.264 software-encoder fixture with Left chroma siting. Metric implementations pass independently serialized analytic fixtures for PSNR, MS-SSIM, ringing, alias, severe-regression, chroma displacement, and source-asset paired bootstrap. The complete Python suite passed 80 tests without failures or skips.

The pre-change production dry run passed 24 development cases in both engine-raw and container-decoded domains. The post-encode path used 24 isolated HEVC writer processes, one per metric case; two additional H.264 writer runs produced route-specific low-resolution inputs. The semantic verifier reopened all bound inputs, source payloads, writer reports, decoded payloads, results, checkpoint, bootstrap record, and self-hashed manifest. The final tree contains 154 manifest-bound artifacts with an exact path set, read-only user-immutable file inodes, sealed directories, and one atomic final rename.

An injected interruption was preserved and a resumed run recomputed from the locked inputs. Both failure and successful-run evidence record `holdout_accessed: false`. The holdout loader's 13-hash authorization guard passed 32 focused tests, but holdout media and results remained unopened.

## Native regression assessment: pass

Seven focused product-writer tests passed. The full Xcode suite recorded 113 tests: 112 passed, zero failed, and one expected G01-only opt-in fixture skipped. The arm64 Release build completed with zero errors, warnings, or analyzer warnings. Strict lint reported zero violations in 78 files.

## Failure correlation

The hardening work found five recurring boundary classes: incomplete transitive provenance, stateful writer contamination, padded-versus-active pixel identity, pathname protection without inode detachment, and schema-valid evidence without cross-file semantic replay. Their evidence and downstream controls are documented in `analysis/failure-pattern-correlation.md`.

## Checkpoint boundary

G04 has zero mandatory failures. This pass establishes benchmark and metric integrity only. It does not claim that the current ASH reconstruction improves image quality. Spatial semantic correctness, configuration calibration, locked-holdout causal evidence, Metal parity/performance, media semantics, temporal quality, and final release audit remain owned by G05 through G12. No remote operation occurred.
