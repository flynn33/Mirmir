# ASH P06 failure-to-code map

This map separates measured gate behavior from implementation hypotheses. It is supporting material for the bounded P06 diagnostic and does not claim that a proposed change has passed a gate.

## Gate definitions

- `validation/calibration_v2/runner.py:4629` builds the source-asset paired bootstraps; `runner.py:4890` applies domain feasibility; and `runner.py:5030` collapses global predicates into one canonical `check:` label.
- `validation/calibration_v2/contracts/metric-performance-tolerances-v1.json:13` fixes the 10,000-replicate bootstrap, strict zero-dB lower-bound gates, the 0.25-pixel absolute chroma limit, and the 0.1-pixel increase limit.
- `validation/calibration_v2/runner.py:3164` defines route-quality as a composite of coverage, per-source Y, ringing, alias, and chroma predicates.
- `validation/quality/src/mirmir_quality/metrics.py:235` defines chroma edge displacement from Cb/Cr and Y edge crossings.

## Shared runtime seams

- `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedReferencePipelineV2.swift:14` constructs one analysis/dispatch path that is reused by Y, Cb, and Cr.
- `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedSampleRuntimeV2.swift:244` applies per-plane coordinates while reusing descriptor IDs, weights, and parameter slots.
- `Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerV2.swift:228` emits one primary/secondary descriptor pair for an entry.
- `Mirmir/Modules/UpscalerEngine/ASH/ASHVideoAnalyzerV2.swift:529` measures chroma alignment and edge confidence, while `ASHLockedRuntimeV2.swift:174` does not carry chroma edge confidence in the locked sidecar.
- `Mirmir/Modules/UpscalerEngine/ASH/ASHLUTCompilerSemanticsV2.swift:20` reduces chroma state to binary alignment in the legacy base-descriptor path.
- `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedPlanePolicyDiagnosticV3.swift:65` already exercises independent plane-policy behavior diagnostically but does not connect it to production.

## What each Y comparison isolates

- Best fixed: adaptive selection and blending must exceed the strongest single same-bank descriptor. Control selection is in `validation/calibration_v2/production_evaluator.py:1541`; fixed runtime behavior is in `ASHLockedControlRuntimeV2.swift:151`.
- Non-ASH selector: the full compiler must retain enough information to exceed continuous same-bank selection. The continuous selector is in `ASHLockedControlRuntimeV2.swift:255`; thresholded state is in `ASHVideoAnalyzerV2.swift:569`.
- Conventional: the operator bank and reconstruction core must exceed the strongest selected conventional baseline. Conventional selection is in `production_evaluator.py:1548`; per-plane conventional reconstruction is in `ASHLockedControlResamplerV2.swift:21`.

## Versioned improvement boundary

- Existing binary output is format 1.1 in `ASHLUTBinaryFormatV2.swift:6`; the loader accepts 1.1 in `ASHImmutableLUTLoaderV2.swift:92`.
- The G05 lock makes policy 0 the exact legacy descriptor formula and distinguishes true isotropic mode from rotated mode at q12 zero.
- The next contract layer must preserve 1.1 bytes and decode behavior while defining a 1.2 path with one policy ID per route and explicit luma/chroma modes. Runtime work must carry plane-specific mode semantics; serialization alone cannot remove the measured coupling.
- Full ASH pixels must be reevaluated when route policy or plane mode changes. Existing cached recombination is limited to non-ASH selector controls.

## Improvement order supported by current evidence

1. Freeze the compiler-v2, locked-input-v2, and binary-1.2 contracts with exact 1.1 compatibility.
2. Carry route policy and explicit luma/chroma mode through compiler, validator, oracle, loader, and runtime.
3. Preserve chroma edge confidence and permit plane-specific descriptor/weight/parameter decisions.
4. Reevaluate adaptive uplift versus fixed and non-ASH controls, then address any remaining operator-bank ceiling versus conventional.
5. Keep all thresholds unchanged and rerun the complete G06 evidence closure before P07.
