# Mirmir UI Workflow Fix Closeout - D.1.1.0.0.0

## Commit

- Local commit hash: recorded in the final closeout response after commit creation.
- Commit message: Refine Mirmir product upscaling workflow
- Worktree clean after commit: verified after commit creation.
- PR opened: no.

## Summary

The product shell now opens by default in Debug and Release. The developer host is available only when `MIRMIR_DEVELOPER_WORKSPACE=1` is set in a Debug build.

The primary UI is a guided Mirmir workflow: select video, choose quality/effects, choose target/output, run upscale, and review completion. Architecture details are confined to Settings/About technical sections.

The workflow state and validation now require a supported source, supported target, resolved output path, available processing engine, and ready state before starting.

## Changed files

- `.gitignore`
- `Mirmir.xcodeproj/project.pbxproj`
- `Mirmir/App/MirmirDeploymentMode.swift`
- `Mirmir/Modules/UI/MirmirViewModel.swift`
- `Mirmir/Modules/UI/Views/MirmirRootView.swift`
- `Mirmir/Modules/UI/Views/MirmirSettingsViews.swift`
- `Mirmir/Modules/UI/Views/MirmirWorkflowViews.swift`
- `Mirmir/Modules/UI/Views/UpscaleControlsView.swift`
- `MirmirTests/ASHBackendIntegrationTests.swift`
- `MirmirTests/ArchitectureGuardrailTests.swift`
- `MirmirTests/MirmirUIWorkflowTests.swift`
- `project-notes/mirmir-ui-workflow-fix-D.1.1.0.0.0-log.md`
- `project.yml`

## Build and test evidence

```text
SwiftLint:
swiftlint lint --strict --config .swiftlint.yml
Result: passed, 0 violations, 0 serious.

Debug build:
xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/mirmir-ui-workflow-deriveddata build
Result: BUILD SUCCEEDED.

Release build:
xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Release -destination 'platform=macOS' -derivedDataPath /tmp/mirmir-ui-workflow-deriveddata build
Result: BUILD SUCCEEDED.

Full tests:
xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/mirmir-ui-workflow-deriveddata test
Result: TEST SUCCEEDED, 44 tests, 0 failures.

UI workflow tests:
xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/mirmir-ui-workflow-deriveddata -only-testing:MirmirTests/MirmirUIWorkflowTests test
Result: TEST SUCCEEDED, 8 tests, 0 failures.

ASH focused/proof tests:
xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/mirmir-ui-workflow-deriveddata -only-testing:MirmirTests/ASHBackendIntegrationTests -only-testing:MirmirTests/ASHInternalAlphaTests -only-testing:MirmirTests/ASHAssetConformanceTests -only-testing:MirmirTests/ASHBitwiseCoreTests -only-testing:MirmirTests/ASHFeatureBranchReconstructionTests test
Result: TEST SUCCEEDED, 20 tests, 0 failures.

Guardrails:
./Scripts/verify-mirmir-guardrails.sh
Result: Mirmir guardrails passed.

Attribution scan:
xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/mirmir-ui-workflow-deriveddata -only-testing:MirmirTests/ArchitectureGuardrailTests/test_repositorySurfacesHaveNoProhibitedAttribution test
Result: TEST SUCCEEDED, 1 test, 0 failures.

Duplicate-class warning scan:
rg -n "is implemented in both|duplicate class" /tmp/mirmir-ui-workflow-deriveddata/Logs/Test /tmp/mirmir-guardrails-deriveddata/Logs/Test
Result: no matches.
```

## User Workflow Evidence

- Select video: `SourceVideoStepView` exposes the product-first Choose Video command.
- Drag/drop video: `WorkflowDropZone` loads dropped file URLs through `MirmirViewModel.loadSource`.
- Source probe: supported extensions are checked before probing; unsupported files show a visible error.
- Quality selection: `MirmirQualityMode` provides selectable quality modes.
- Effects selection: effect controls are visible but disabled with alpha-build reasons because effect switches are not wired to the current engine.
- Target selection: available targets derive from source resolution, with 720p to 1080p and 1080p to 2160p support.
- Output path: default output is `<source>_mirmir_<target>.mp4` in the source folder.
- Upscale: `canStart` now requires valid source, target, output, engine readiness, and ready state.
- Progress/cancel: `JobProgressView` and `UpscaleActionBar` expose progress and cancel controls.
- Completion/reveal: `CompletionActionsView` exposes Reveal in Finder and Upscale Another.

## Known Limitations

- Effect toggles are disabled because the current engine contract has no effect payload.
- Manual screenshot evidence was not captured in this pass.
- Test launch still emits local App Intents `linkd.autoShortcut` connection messages; these are non-fatal and existing local macOS service messages.
- iOS target testing is waived because this repository currently has no iOS target.
- Windows and Visual Studio conformance are waived because this is a macOS Xcode project.

## PR Status

No pull request was opened.
