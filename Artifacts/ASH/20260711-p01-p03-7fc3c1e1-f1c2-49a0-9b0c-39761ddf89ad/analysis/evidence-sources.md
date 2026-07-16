# P01 Evidence Sources

## Current production source

- Bootstrap and dependency injection: `Mirmir/App/MirmirForsettiBootstrap.swift`
- UI submission: `Mirmir/Modules/UI/MirmirViewModel.swift`, `Mirmir/Modules/UI/Views/MirmirUpscaleWorkspaceView.swift`
- Job orchestration and route execution: `Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift`, `Mirmir/Modules/UpscalerEngine/UpscaleStrategy.swift`
- Reader, writer, transaction, and pixel-buffer bridge: `Mirmir/Modules/MediaPipeline/AVFoundationMediaPipeline.swift`, `AVFoundationMediaSessionConfiguration.swift`, `AtomicMediaOutput.swift`, `PixelBufferBridge.swift`
- ASH analysis and reconstruction: `Mirmir/Modules/UpscalerEngine/ASH/*.swift`
- Conditional Lanczos route: `Mirmir/Modules/UpscalerEngine/LanczosPolishPass.swift`
- Telemetry catalog, recorder, and models: `Mirmir/Modules/Telemetry/*.swift`

## Controlled tests inspected

- `MirmirTests/ASHFeatureBranchReconstructionTests.swift`
- `MirmirTests/ASHInternalAlphaTests.swift`
- `MirmirTests/ASHCoreConformanceTests.swift`
- `MirmirTests/ASHTelemetryTests.swift`
- `MirmirTests/ASHBackendIntegrationTests.swift`
- `MirmirTests/MirmirUIWorkflowTests.swift`

## Supplied contracts and baseline evidence

- `<instruction-package>/config/audit_gates.json`
- `<instruction-package>/config/telemetry_stage_catalog.json`
- `<instruction-package>/schemas/telemetry.schema.json`
- `<instruction-package>/instructions/01_EVIDENCE_BASELINE_AND_SCOPE.md`
- `<instruction-package>/instructions/16_PHASE_BY_PHASE_IMPLEMENTATION_BLUEPRINT.md`
- `<instruction-package>/instructions/17_TELEMETRY_AND_EVIDENCE_RUNBOOK.md`
- `<instruction-package>/evidence/ash_reference_pipeline_audit.json`
- `<instruction-package>/evidence/ash_reference_pipeline_audit.md`
- `<instruction-package>/evidence/mirmir_evaluation_baseline.json`
- `<instruction-package>/evidence/mirmir-upscale-evaluation.md`

## Runtime evidence inspected

- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/telemetry-signpost-final.json` — SHA-256 `1daab305ff3319b5430c19102af1aced811033bc6fd2524dd9267dad6e15c045`
- Associated direct-route config — SHA-256 `38f10c03b9e2caa5df38e151593853ebad43054747f26c021d2d2e52bcb87618`
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/analysis/signpost-validation.json` — status `pass`, SHA-256 `2a7d14c5e81524868389e2fb35f6ccd0f54860b4d5a7015423b64d4160e59dff`
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/production-signposts-raw.xml` — SHA-256 `e35c9d7fa9f28e245077224eb74239e4891a6645cdd7f4ecdb2a93f677146c7f`
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/production-signpost-intervals.xml` — SHA-256 `135a1a67a53a394ab0bff830bdc7e007417967cd1de2b378a6fe6eb1d42b9151`
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/production-signposts-toc.xml` — SHA-256 `a0919e0c4ca06e56efa1b85928a7021976800c877132a287415a4cce8946b3c1`
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/production-time-profile.xml` — SHA-256 `374632ff7612857064e87fe5aad71a51f7f4948b3d981d4ccf6d8c2443654b4d`
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/production-time-profiler-toc.xml` — SHA-256 `a6cf9c837faf26e5dc4015e032a950da38f7fc752a74a4760af9e03b8546f3d5`
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/tests/focused-p01-p03-pass.xcresult` — native summary: 18 passed, 0 failed, 0 skipped
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/tests/full-debug-pass.xcresult` — native summary: 82 passed, 0 failed, 1 explicit evidence-only skip
- `Artifacts/ASH/20260711-p01-p03-7fc3c1e1-f1c2-49a0-9b0c-39761ddf89ad/runtime/production-signpost-xcodebuild.log` — configured direct-route test: 1 passed, 0 failed, 0 skipped

The successful telemetry run and the time-limited profiler capture are separate measurements with different test-host configurations. Their absolute values are not combined. Static source findings are identified separately from runtime observations throughout this evidence set.
