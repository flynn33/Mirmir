# ASH Internal Alpha Big Push Log

Date: 2026-07-09
Starting commit: `75a7f51081e88e87b5eb64861c01b8d21665748b`
Branch: `main`
Instruction package: Mirmir ASH Big Push - Internal Testable Alpha, package date 2026-07-09

## Phase Completion

| Phase | Status | Evidence | Notes |
|---|---|---|---|
| 0 Workspace | complete | `git status --short --branch`, `git log -1 --oneline`, `gh pr list`, `xcodebuild -list` | Starting commit confirmed; prior patch export ignored via `.gitignore`; no open PR found. |
| 1 Asset conformance | complete | `ASHInternalAlphaTests.test_runtimeConformanceReportValidatesAllBundledASHAssets` | Bundled ASH assets validate against runtime mapping, state, branch, and certificate checks. |
| 2 Tile processing | complete | `ASHInternalAlphaTests.test_tileProcessorSelectsMultipleMessagesForStructuredFrame` | 32-pixel luma tiles map through feature extraction, branch candidates, scoring, selection, and stitched output. |
| 3 Chroma features | complete | `ASHInternalAlphaTests.test_nv12ChromaEnergyChangesFeatureVector` | NV12 chroma energy feeds feature coordinate 5 without changing the feature vector width. |
| 4 Branch evidence | complete | `ASHInternalAlphaTests.test_branchFixtureSuiteSelectsAtLeastFourNonNeutralMessages` | Fixture suite selects at least four non-neutral ASH messages across structured luma patterns. |
| 5 Metal alpha | complete | `ASHInternalAlphaTests.test_metalLumaOperatorMatchesCPUReference` | Metal luma operator output matches the CPU reference within the pixel tolerance. |
| 6 Buffer tests | complete | `ASHInternalAlphaTests.test_backendProcessesNV12BufferAndWritesDeterministicOutput` | Backend processes real NV12 `CVPixelBuffer` input into deterministic luma and chroma output. |
| 7 UI/debug evidence | complete | `ASHInternalAlphaTests.test_backendStatusDoesNotClaimReadyBeforeValidation`; `ASHInternalAlphaTests.test_backendDebugSummaryReportsTilesAndChroma` | UI status uses validation states; backend summary reports tiles, branch histogram, temporary bytes, and chroma use. |
| 8 Final validation | complete | Build, test, proof suite, guardrail, diff, and attribution scan gates | All applicable local gates passed. iOS and Windows gates are documented as not applicable below. |

## Command Attempts and Fallbacks

| Command or service | Available? | Fallback | Output summary |
|---|---:|---|---|
| Project inventory shortcut | no | `find . -maxdepth 5 -type f \| sort` | Project files enumerated locally. |
| Status shortcut | no | `git status --short --branch` | Baseline branch/status captured. |
| Build helper defaults | no | `xcodebuild` shell commands | Helper defaults were unset; project exposes macOS `Mirmir` and `MirmirTests` targets only. |
| ASH proof suite with system Python | no | Homebrew Python 3.12 and `/tmp/mirmir-ash-proof-venv` | System Python 3.9 lacked the required runtime/dependencies. |

## Failures and Repairs

| Iteration | Phase | Failure | Repair | Rerun result |
|---:|---|---|---|---|
| 1 | Focused ASH tests | Initial focused test run failed before the alpha APIs existed. | Added asset catalog validation, tile processing, chroma feature support, branch scoring, Metal luma operator, and buffer-level backend tests. | Focused ASH tests passed: 9 tests, 0 failures. |
| 2 | Full tests | Existing view-model integration test did not set the new ASH validation state. | Updated the test to set `ashBackendStatus = .available` while preserving the model-readiness assertion. | Full `MirmirTests` suite passed: 35 tests, 0 failures. |
| 3 | ASH proof suite | `python3 tools/run_proof_suite.py` failed under Python 3.9 with missing `numpy`. | Installed Python 3.12 via Homebrew and installed ASH model dependencies in `/tmp/mirmir-ash-proof-venv`. | Proof suite passed with `all_checks_pass: true`. |
| 4 | ASH proof suite setup | Unquoted optional dependency spec was expanded by the shell. | Reran install as `pip install -e '.[dev]'`. | Dependency install and proof suite passed. |

## Asset Hashes

| Asset | Expected | Observed | Result |
|---|---|---|---|
| `ash-state-reference.csv` | `20e885ce6f83ca584ec13b53161dd25f5ed2e42baeeb60633b0ce19d2975c310` | `20e885ce6f83ca584ec13b53161dd25f5ed2e42baeeb60633b0ce19d2975c310` | pass |
| `ash_mapping_v1.json` | `aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79` | `aef24e8eba2441025e1e440e2791215d32d163e0b7b91d25bb7e9b7018260c79` | pass |
| `branch-topology.json` | `e114168b20ce2842126b949399b07750160fb0acbdf3971a028f5fcc15d3748c` | `e114168b20ce2842126b949399b07750160fb0acbdf3971a028f5fcc15d3748c` | pass |
| `codewords.csv` | `cccb4077ec79e52d428f4fc41dabb6e91e565c95b7f8cca2d53356e7cd408fe4` | `cccb4077ec79e52d428f4fc41dabb6e91e565c95b7f8cca2d53356e7cd408fe4` | pass |
| `computational-certificate.json` | `b0ea48e16ede4d09d8361fcb374c7f3072d9c498685623b9bc747103efb9febf` | `b0ea48e16ede4d09d8361fcb374c7f3072d9c498685623b9bc747103efb9febf` | pass |

## Branch Distribution Evidence

| Fixture | Tile count | Selected message histogram | Notes |
|---|---:|---|---|
| Structured 64x32 frame | 2 | varied; more than one selected message | Verifies per-tile branch selection is not collapsed to one message. |
| Eight-fixture branch suite | 8 | at least four non-neutral messages | Covers horizontal, vertical, checker, pseudo-random, diagonal, stripe, and constant luma inputs. |

## Buffer-Level Test Evidence

| Test | Result | Notes |
|---|---|---|
| Real NV12 source to NV12 destination | pass | Output is deterministic across independent backend instances. |
| Backend debug summary | pass | Summary reports 2 tiles, chroma enabled, varied selected-message histogram, and nonzero temporary byte estimate. |

## Final Validation

| Gate | Command | Result |
|---|---|---|
| Debug build | `xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -destination 'platform=macOS' -configuration Debug build` | pass |
| Release build | `xcodebuild -project Mirmir.xcodeproj -scheme Mirmir -destination 'platform=macOS' -configuration Release build` | pass |
| Full tests | `xcodebuild test -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug -destination 'platform=macOS'` | pass; 35 tests, 0 failures |
| Focused ASH tests | `xcodebuild test -project Mirmir.xcodeproj -scheme Mirmir -configuration Debug -destination 'platform=macOS' -only-testing:MirmirTests/ASHInternalAlphaTests` | pass; 9 tests, 0 failures |
| ASH proof suite | `/tmp/mirmir-ash-proof-venv/bin/python tools/run_proof_suite.py` from `ASH-Model-main` | pass; `all_checks_pass: true` |
| Guardrails | `./Scripts/verify-mirmir-guardrails.sh` | pass |
| Diff check | `git diff --check` | pass |
| Attribution scan | `./Scripts/verify-mirmir-guardrails.sh`; staged-diff scan before commit | pass |
| PR check | `gh pr list --head main --state open --json number,title,url` | pass; no PR returned |

## Known Limitations

- Visual Studio / Windows conformance is not part of this macOS alpha gate.
- iOS target testing is not applicable unless an iOS target is added later.
- `xcodebuild -list -project Mirmir.xcodeproj` shows only `Mirmir` and `MirmirTests`; no iOS target is present.
- Windows conformance remains a follow-up only if a Windows target or separate Windows repository is added for this product.
- Final local commit hash is recorded in the closeout report after commit creation.

## Final Local Commit

Commit hash:
Commit message:
Worktree clean: recorded after commit creation
PR opened: no
