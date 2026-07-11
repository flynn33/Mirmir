# P05 spatial ASH v2 checkpoint

This immutable checkpoint records the P05 CPU-reference implementation and the G05 semantic-correctness decision.

The checkpoint binds the development mapping, direct 2x and direct 3/2 reconstruction paths, state-conditioned affine dispatch, all progressive chroma-siting policies, deterministic evidence generator, schemas, Xcode results, quality-lock reassessment, and independent audit.

Result: **PASS**.

- Full Xcode suite: 162 passed, one expected opt-in skip, zero failures.
- Focused G02 regression: 56 passed, zero failures.
- Release build: succeeded with zero recorded warnings, analyzer warnings, or errors.
- Spatial evidence: three byte-identical, schema-valid runs.
- Quality reassessment: 81 passed, zero skips or failures.
- SwiftLint: zero violations across 91 project Swift files.
- Holdout data and results: not accessed.

The mapping and operator values in this checkpoint remain development-only. P06 owns calibration and the release configuration lock.

