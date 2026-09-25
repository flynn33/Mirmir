# Changelog

All notable changes to Mirmir are recorded in this file.

The project uses `release.feature.patch` version numbers. Repository versions
do not publish, sign, notarize, or distribute the application automatically.

## [Unreleased]

## [1.3.3] - 2026-09-25

### Fixed

- Accepted user-selected regular source files with multiple hard links while
  retaining the single-link invariant for queue-owned private snapshots.
- Gated VideoToolbox Smooth Motion + Spatial Upscale with the Mac's reported
  2× source-frame maximum dimension and pixel-count limits. These processor
  limits are independent of connected-display resolution, and unsupported
  inputs are now shown as unavailable before processing begins.

### Product boundaries

- Deferred the resource-allocation control; it is not included in this
  release.
- Kept attached-picture preservation on the deterministic v4 whole-asset path.
  Conventional backends do not preserve attached pictures.
- Kept Automatic's existing opaque-input policy. It does not select the
  deterministic v4 routes for opaque H.264 sources.

### Verified

- Completed real-file deterministic CPU and Metal upscales of the retained
  960 × 960 H.264 fixture to playable 1920 × 1920 HEVC outputs with 241 frames,
  audio, attached picture, and identical decoded frames.
- Paused a deterministic Metal job after its first durable boundary, resumed
  it from the persisted checkpoint, and completed the verified output.
- Confirmed cancellation left no destination movie and did not prevent a
  later enqueue of the same source.
- Advanced repository and Xcode version authorities to 1.3.3 build 6 without
  asserting archive, notarization, installation, or distribution.

## [1.3.2] - 2026-09-23

### Fixed

- Preserved exact processed-video media origins and movie edit-map timescales
  during final whole-asset assembly, preventing frame loss or rounded edit
  mappings on ordinary MP4 inputs and scaled edit lists.
- Treated ISO and QuickTime AAC sample-entry wrappers as container
  representations only when the codec configuration is independently bound,
  while retaining fail-closed comparison for incomplete or unknown compressed
  audio formats.
- Kept dynamic-HDR-absent segment preflight in the decoded presentation-time
  domain and canonicalized missing decoded frame durations without trusting a
  coarsely rounded container end time.
- Accepted legal video-range footroom and headroom through the spatial kernel,
  clamped only bounded ASH analysis inputs, and continued rejecting malformed
  P010 packing.
- Preserved the authenticated original source basename in durable queue
  snapshots. Verified legacy snapshots that cannot prove that filename now
  fail before dispatch with explicit re-enqueue guidance and no checkpoint
  reuse.
- Bound deterministic temporary outputs to the destination directory's
  filesystem identity so safe aliases remain usable while directory escapes
  are rejected.
- Prevented an idle queue-drain pass from acquiring a global dispatch slot
  when no queued job exists, removing a race with immediate paused-job resume
  from a recreated controller.

### Verified

- Completed the full Debug scheme with 490 passing tests, zero failures, and
  three expected opt-in capture skips, plus an unsigned universal Release
  build.
- Reproduced the originally reported MP4 remux path with all 241 H.264 video
  samples and 470 AAC audio samples retained under the semantic verifier.
- Refreshed the stale quality-evaluator source lock in the P06 metric and
  verification contracts, reproduced the 12-artifact bundle twice, resealed
  its corrected production-source closure, and verified production-loader
  acceptance plus same-length artifact-tamper rejection.
- Reconciled the optional media-preservation fixture lock and aggregate release
  trust root with the qualified source tree. All 331 release-control tests and
  the independent trust-root reproduction passed.
- Advanced all repository and Xcode version authorities to 1.3.2 build 5.
  This patch preserves the completed simulator-only M7 decision; it does not
  assert signing, notarization, shipping, or distribution.

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
