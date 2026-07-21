# Apple Upscale Capability Report

- **Schema version:** `1.0`
- **Roadmap version:** `1.0.1`
- **Phase:** `R01`
- **Evidence kind:** `operator_observation_waiver`
- **Observation requirement:** `waived_not_a_blocker`
- **Source commit:** `8a14afb8ff0ba24abbebb5c72c47d8e38adbeffe`
- **Source tree:** `c5ac2cc72046f3a04599635fb7151ab95ecfbe24`
- **Generated at:** `2026-07-20T23:13:34Z`

Physical-hardware execution, simulator availability, simulator execution, and operator-observed execution were waived as blockers by explicit operator direction. Every capability below therefore remains diagnostic-only and unobserved.

The preregistration and fixture-catalog bindings preserve the original unassigned host/model state; no model identity or digest was synthesized.

## Anchor Observation Status

| Anchor | Target contract | Hardware | Simulator |
| --- | --- | --- | --- |
| `oldest-supported` | oldest-supported Apple Silicon on macOS 15.4 | `not_observed` | `not_observed` |
| `m3-air` | current M3 MacBook Air class on macOS 26 | `not_observed` | `not_observed` |
| `pro-max` | current Pro/Max performance tier | `not_observed` | `not_observed` |
| `core-ai` | macOS/Xcode 27 host capable of probing Core AI | `not_observed` | `not_observed` |

## Capability Matrix

| ID | Family / method | Probe class | Anchor | Compile | Runtime | Reason | Measurements |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `A01` | VideoToolbox / VTSuperResolutionScaler | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A01` | VideoToolbox / VTSuperResolutionScaler | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A01` | VideoToolbox / VTSuperResolutionScaler | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A01` | VideoToolbox / VTSuperResolutionScaler | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A02` | VideoToolbox / VTLowLatencySuperResolutionScaler | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A02` | VideoToolbox / VTLowLatencySuperResolutionScaler | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A02` | VideoToolbox / VTLowLatencySuperResolutionScaler | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A02` | VideoToolbox / VTLowLatencySuperResolutionScaler | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A03` | VideoToolbox / VTLowLatencyFrameInterpolation spatial scaling | `cadence_transform` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A03` | VideoToolbox / VTLowLatencyFrameInterpolation spatial scaling | `cadence_transform` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A03` | VideoToolbox / VTLowLatencyFrameInterpolation spatial scaling | `cadence_transform` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A03` | VideoToolbox / VTLowLatencyFrameInterpolation spatial scaling | `cadence_transform` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A04` | VideoToolbox / VTTemporalNoiseFilter | `support_filter` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A04` | VideoToolbox / VTTemporalNoiseFilter | `support_filter` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A04` | VideoToolbox / VTTemporalNoiseFilter | `support_filter` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A04` | VideoToolbox / VTTemporalNoiseFilter | `support_filter` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A05` | VideoToolbox / VTOpticalFlow | `temporal_analyzer` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A05` | VideoToolbox / VTOpticalFlow | `temporal_analyzer` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A05` | VideoToolbox / VTOpticalFlow | `temporal_analyzer` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A05` | VideoToolbox / VTOpticalFlow | `temporal_analyzer` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A06` | VideoToolbox / VTPixelTransferSession | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A06` | VideoToolbox / VTPixelTransferSession | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A06` | VideoToolbox / VTPixelTransferSession | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A06` | VideoToolbox / VTPixelTransferSession | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A07` | MetalFX / Spatial scaler | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A07` | MetalFX / Spatial scaler | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A07` | MetalFX / Spatial scaler | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A07` | MetalFX / Spatial scaler | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A08` | MetalFX / Temporal scaler | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A08` | MetalFX / Temporal scaler | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A08` | MetalFX / Temporal scaler | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A08` | MetalFX / Temporal scaler | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A09` | MetalFX / Temporal denoised scaler | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A09` | MetalFX / Temporal denoised scaler | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A09` | MetalFX / Temporal denoised scaler | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A09` | MetalFX / Temporal denoised scaler | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A10` | MetalFX / Frame interpolator | `cadence_transform` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A10` | MetalFX / Frame interpolator | `cadence_transform` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A10` | MetalFX / Frame interpolator | `cadence_transform` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A10` | MetalFX / Frame interpolator | `cadence_transform` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A11` | MPS / MPSImageLanczosScale | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A11` | MPS / MPSImageLanczosScale | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A11` | MPS / MPSImageLanczosScale | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A11` | MPS / MPSImageLanczosScale | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A12` | MPS / MPSImageBilinearScale | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A12` | MPS / MPSImageBilinearScale | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A12` | MPS / MPSImageBilinearScale | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A12` | MPS / MPSImageBilinearScale | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A13` | MPS / Guided/detail/artifact filters | `support_filter` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A13` | MPS / Guided/detail/artifact filters | `support_filter` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A13` | MPS / Guided/detail/artifact filters | `support_filter` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A13` | MPS / Guided/detail/artifact filters | `support_filter` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A14` | CoreImage / Lanczos/Bicubic scale | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A14` | CoreImage / Lanczos/Bicubic scale | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A14` | CoreImage / Lanczos/Bicubic scale | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A14` | CoreImage / Lanczos/Bicubic scale | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A15` | CoreImage / EdgePreserveUpsample | `support_filter` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A15` | CoreImage / EdgePreserveUpsample | `support_filter` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A15` | CoreImage / EdgePreserveUpsample | `support_filter` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A15` | CoreImage / EdgePreserveUpsample | `support_filter` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A16` | Accelerate / vImage Lanczos-3/Lanczos-5/custom | `primary_scaler` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A16` | Accelerate / vImage Lanczos-3/Lanczos-5/custom | `primary_scaler` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A16` | Accelerate / vImage Lanczos-3/Lanczos-5/custom | `primary_scaler` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A16` | Accelerate / vImage Lanczos-3/Lanczos-5/custom | `primary_scaler` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A17` | Metal / Custom compute | `support_filter` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A17` | Metal / Custom compute | `support_filter` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A17` | Metal / Custom compute | `support_filter` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A17` | Metal / Custom compute | `support_filter` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A18` | CoreAI / Custom model runtime | `analysis_runtime` | `oldest-supported` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A18` | CoreAI / Custom model runtime | `analysis_runtime` | `m3-air` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A18` | CoreAI / Custom model runtime | `analysis_runtime` | `pro-max` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |
| `A18` | CoreAI / Custom model runtime | `analysis_runtime` | `core-ai` | `not_observed` | `diagnostic_only` | `operator_gate_waiver` | `not_measured` |

## Limitations

- Physical-hardware execution was not required by explicit operator override.
- Simulator availability and simulator execution were not required by explicit operator override.
- No compile, runtime, support, hardware, performance, memory, repeatability, product-qualification, backend-eligibility, or perceptual-quality result is inferred from an unobserved record.
