# G05 gate report — Spatial ASH v2 semantic correctness

Status: **PASS**

## Mandatory criteria

1. **Every state bit has controlled fixture coverage — pass.** Nine controlled packed-state bits are exercised, including parity, with 256 parity-valid fixed-phase states represented in `evidence/run-a/state-fixtures.json`.
2. **Structure-tensor normal/tangent convention passes orientation fixtures — pass.** Horizontal, vertical, positive-diagonal, and negative-diagonal fixtures verify the edge normal and the tangent obtained by the required half-turn-axis quarter-turn conversion.
3. **Direct 2x and 3/2 CPU reference passes synthetic tests — pass.** `evidence/run-a/cpu-reference-vectors.json` contains 192 passing CPU vectors and 32 source-aligned preservation vectors across both coordinate policies.
4. **All 16 descriptors are semantically and behaviorally distinct — pass.** All 120 descriptor pairs differ on at least one qualifying nonconstant fixture across 1,056 discrimination cases; constant-patch preservation remains intact.
5. **Nearest is not the production reconstruction substrate — pass.** The evidence records direct source-neighborhood sampling and `nearest_expanded_substrate: false`.
6. **Dispatch is not constant across valid states — pass.** The exhaustive fixed-phase set reaches all 16 decoded primary descriptors. Route/phase checks cover 3,328 combinations; all-siting luma/chroma expansion covers 46,592 enabled dispatches and 93,184 exact decoded evaluations with every failure counter at zero.
7. **The first-frame top operator is not universal by construction — pass.** Seven distinct decoded primary descriptors are selected by the seven controlled first-frame fixtures at a fixed phase.
8. **The state-disabled result differs on controlled fixtures — pass.** Twenty-four actual Y/Cb/Cr pipeline ablations are positive; the minimum overall absolute delta is `0.30075150495061587`.

## Determinism and provenance

Builder runs A and B and the independent third run are byte-identical for all eight evidence documents. Every document passes its project-owned schema and binds 11 production files, two configuration assets, and 11 generator/schema files by SHA-256. The quality-harness implementation lock independently binds 86 files, including all 34 mandatory P05 paths, with canonical hash `6862702ddf2bbb2398599e10ba3903b384e0f53b91ea938d14de2d2d7d3b112c`.

## Dependent regressions

- G02 route/transaction regression: 56/56 passed.
- G04 quality-integrity reassessment: 81/81 passed.
- Full Xcode suite: 162 passed, one expected opt-in skip, zero failures.
- Release build: zero recorded warnings or errors.
- Architecture guardrails and strict lint: pass.
- Holdout access: false.

No severity-1 or severity-2 defect remains in P05 scope. Full-frame Metal performance, release calibration/LUT locking, and container-level media semantics remain assigned to their later gates.

