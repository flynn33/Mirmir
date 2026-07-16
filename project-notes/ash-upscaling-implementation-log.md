# ASH Upscaling Implementation Log

Date: 2026-07-09

Starting commit: `c97468a784be256a132268bea297a6cd1a867d46`

Historical status: this log records the 2026-07-09 development-backend state.
The current product composition was superseded by the locked V3 wiring merged
through PR #7. See
`project-notes/ash-v3-production-wiring-design.md` for the current call graph,
artifact contract, fail-closed behavior, and remaining release gates.

## Scope

- Added a deterministic ASH Swift core for 9-bit state handling, strict codeword recovery, feature extraction, branch generation, CPU reconstruction, and candidate pruning.
- Added an explicit `ASHDeterministicUpscaleBackend` for the production upscaler engine.
- Switched the default export path to the ASH backend while preserving the existing media session, output writer, timing, audio passthrough, progress, and Lanczos polish path.
- Removed model-staging readiness as a blocker for ASH upscaling in the UI.

## ASH Assets

| Asset | SHA-256 |
| --- | --- |
| `ash_mapping_v1.json` | `aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79` |
| `codewords.csv` | `cccb4077ec79e52d428f4fc41dabb6e91e565c95b7f8cca2d53356e7cd408fe4` |
| `ash-state-reference.csv` | `20e885ce6f83ca584ec13b53161dd25f5ed2e42baeeb60633b0ce19d2975c310` |
| `branch-topology.json` | `e114168b20ce2842126b949399b07750160fb0acbdf3971a028f5fcc15d3748c` |
| `computational-certificate.json` | `b0ea48e16ede4d09d8361fcb374c7f3072d9c498685623b9bc747103efb9febf` |

## Build And Test Targets

- macOS app target: `Mirmir`
- macOS unit test target: `MirmirTests`
- Focused ASH test classes:
  - `ASHAssetConformanceTests`
  - `ASHBackendIntegrationTests`
  - `ASHBitwiseCoreTests`
  - `ASHFeatureBranchReconstructionTests`

## Verification Log

- Red check: focused ASH core tests initially failed to compile because ASH Swift symbols were absent.
- Red check: backend integration initially failed because `DefaultUpscalerEngineService` still staged model assets.
- Red check: UI start condition initially failed because `MirmirViewModel.canStart` still required model readiness.
- Green check: focused ASH slice passed 11 tests with `xcodebuild test -project Mirmir.xcodeproj -scheme Mirmir -destination 'platform=macOS'`.
- ASH source proof suite passed with a Python runtime that includes NumPy: `python3 tools/run_proof_suite.py`.
- Full repository guardrail passed with `./Scripts/verify-mirmir-guardrails.sh`.

## Follow-Up Gates

- iOS ASH core build/test is not applicable for this local completion because the current project does not include an iOS target. Add an iOS target and run this as a follow-up gate if iOS support is introduced later.
- Windows Visual Studio conformance is not applicable for this local completion because this is a macOS workspace. Run native Windows conformance as a follow-up gate on a Windows host when that environment is available.
