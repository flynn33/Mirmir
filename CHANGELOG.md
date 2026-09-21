# Changelog

All notable changes to Mirmir are recorded in this file.

The project uses `release.feature.patch` version numbers. Repository versions
do not publish, sign, notarize, or distribute the application automatically.

## [Unreleased]

## [1.3.1] - 2026-09-21

### Added

- A live README roadmap tracker that is deterministically regenerated and
  validated on every push and pull request.
- A simulator-only M7 contract, reproducible runner, and independent selector
  for comparing the full v4 policy with four deterministic ablations.
- A pinned Xcode 26.2 M7 workflow that uploads sealed simulator evidence while
  preserving negative no-winner results for audit.
- Sealed 168-case M7 evidence from source commit
  `ce780af87107d90142d860f328dca4a72fea3047`, selecting `candidate_v4` after
  all five policies passed the quality and processing-time targets.
- Exact archived-executable qualification tooling for whole-asset media
  preservation, bounded tiled-temporal CPU/Metal parity, and all 15 recovery
  fault scenarios.
- Session-derived media execution receipts, independent alpha verification,
  and fail-closed preservation checks for HDR metadata and enabled track graphs.
- Canonical Swift and external Metal build receipts that bind effective compiler
  controls, transitive Metal resources, and three-run reproducibility evidence.
- A dated qualification-status record for the signed universal 1.3.0 (3)
  Developer ID archive, its reproducible identities, completed controls, and
  owner-deferred distribution boundary.

### Changed

- Revised M7 to require deterministic headless XCTest frame-simulator
  comparison and selection of the best eligible candidate rather than
  physical hardware, notarization, shipping, or distribution qualification.
- Made quality and timing replay deterministic across supported Python
  runtimes while retaining exact sealed-evidence equality.
- Made recovery evidence causal and scenario-owned across two independent
  packaged processes instead of relying on a source-hosted capture path.
- Replaced the clean-aperture tuple loop with explicit field validation to
  eliminate nondeterministic release compiler IR ordering without disabling
  optimization.
- The v4 identity workflow now derives the production P06 manifest identity,
  source revision, and builder hash from the bundled runtime manifest and
  passes those values into the runtime load check.
- Preserved exact edit-list offsets and terminal marker timing through media
  assembly, including high-timescale HDR inputs.
- Serialized Swift 6.4 release compilation and hardened archive publication so
  canonical builds and failed staging cleanup remain deterministic.
- Added a canonical `BUILD_NUMBER` authority and drift checks, and aligned all
  Xcode target configurations at version 1.3.1 build 4, the Developer ID team,
  and the video application category without creating or distributing a
  release artifact.

## [1.3.0] - 2026-08-14

### Added

- A research-backed deterministic engine v4 roadmap covering P06 release
  locking, arbitrary and temporal ASH, CPU/Metal parity, expanded media and
  track preservation, durable jobs, restart recovery, and measurable quality
  and processing-time gates.
- Exhaustive strict-decoder conformance for every nine-bit ASH state, every
  two-bit codeword corruption, and every integrity-valid affine anchor with a
  one-bit error.
- A bundled, hashed ASH P06 runtime with a fail-closed loader, verified
  measurement and branch artifacts, and no shipping P05 preview identity.
- Shared fixed-point CPU and Metal execution for arbitrary integral target
  dimensions, including bounded tiled processing and one canonical plan.
- State-conditioned spatial reconstruction plus bounded, motion-compensated
  temporal history with deterministic checkpoint and resume identity.
- Native 8-bit NV12 and 10-bit P010/HDR ingest, field-aware deinterlacing,
  rational sample-aspect and clean-aperture geometry, and ProRes 4444 alpha
  delivery.
- An explicit whole-asset track graph for multiple video tracks, audio,
  subtitles, captions, chapters, timecode, timed metadata, and auxiliary
  tracks, with process, transcode, pass-through, or consent-bound drop actions.
- A durable bookmark-backed batch queue with pause and resume, segment
  checkpoints, deterministic assembly, launch reconciliation, and crash
  recovery.
- Exact packaged-candidate quality, performance, parity, media, recovery,
  support-matrix, provenance, and aggregate qualification tooling, including
  forced multi-tile temporal cases and evaluator-owned allocation and route
  proofs.
- Repository identity replay for corpus, runtime, and ASH algebra certificates.

### Changed

- Replaced per-decode canonical codeword scans with a behavior-equivalent
  immutable 512-entry lookup table.
- Made the prepared deterministic CPU adapter enforce idempotent finalization
  and reject processing after finish.
- Replaced the P05 CPU reference and Metal preview routes with the P06
  deterministic engine and the matching product-support contract.
- Advanced the application version to 1.3.0. Signing, notarization, stapling,
  and publication remain operator-owned.

## [1.2.0] - 2026-08-02

### Added

- In-app Mirmir brand lockups for the sidebar, empty workspace, completion
  state, and About screen using the supplied application artwork.
- A complete About Mirmir screen covering James Daley’s ASH Model, the
  Apple-native supporting pipeline, and Raven Forge Software publication.
- Live Dashboard cards for Mirmir CPU, physical-memory footprint, disk I/O,
  explicit Metal-route activity, job progress, and video progress.

### Changed

- Made Dashboard the initial workspace and expanded its responsive layout while
  preserving the locked Midnight Nordic and Arctic Indigo visual system.

## [1.1.0] - 2026-08-02

### Added

- Canonical `VERSION` tracking synchronized with the Xcode marketing version.
- Pull-request label automation for release, feature-release, and patch/hotfix
  increments.
- Version consistency checks and unit coverage for increment behavior.
- Initial product README with build, test, support, and versioning guidance.

### Changed

- Replaced the small macOS AppIcon renditions with the locked supplied artwork.
- Sourced bundle display and build versions from Xcode build settings.
- Kept unavailable methods selectable for inspection and explicit intent. Apple
  Super Resolution selections now warn before changing an incompatible target
  to a scale factor reported by VideoToolbox.

## [1.0.0] - 2026-08-02

### Added

- Native macOS application with explicit video ingest, output configuration,
  progress, completion, and failure states.
- Midnight Nordic workspace and interactive completed-job before-and-after
  comparison viewer.
- Deterministic CPU reference and Metal accelerated preview routes.
- Explicit Apple-native spatial and motion processing adapters with actionable
  availability reporting and no silent fallback for explicit selections.
- Sandboxed media access, validated atomic output publication, and supported
  timing, color, orientation, and audio preservation.
- Focused unit, integration, GPU, and end-to-end media test coverage.
