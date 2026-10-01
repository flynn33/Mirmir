# Changelog

All notable changes to Mirmir are recorded in this file.

The project uses `release.feature.patch` version numbers. Repository versions
do not publish, sign, notarize, or distribute the application automatically.

## [Unreleased]

## [1.4.2] - 2026-10-01

### Fixed

- Routed queue-row deletion and the three Settings cache actions through one
  workspace confirmation presenter. Confirming now awaits the deletion or
  clear operation and reads back the durable queue before reporting success.
- Corrected the queue summary so contained jobs are not labeled active, and
  explained that the sandbox cache remains after reinstalling the app.

### Verification boundary

- Isolated-store regressions created completed, paused, and contained jobs,
  then exercised finished deletion, unfinished deletion, row deletion, and
  Clear Cache. The tests verified removal of job records and owned files,
  preserved completed output, zero counts, and an enabled location gate.
- The full macOS Debug result bundle reports 543 tests: 540 passed, zero
  failed, and three expected opt-in capture tests skipped.
- The existing `/Applications/Mirmir.app` and its live cache were not replaced
  or cleared by this source patch. The 1.4.1 build-10 archive remains a
  historical handoff, not a 1.4.2 artifact.

## [1.4.1] - 2026-09-30

### Fixed

- Reconstructed nominal Deterministic v4 presentation timestamps from the
  planned track start, exact frame ordinal, and exact cadence before submitting
  them to the segment writer. The Ferris frame-148175 start remains
  `5932927/960` rather than being truncated to `556211906/90000`.
- Added one shared exact-or-admitted-adjacent media-clock policy. Exact values
  remain exact; an incommensurable rational may use only an independently
  admitted immediate floor or ceiling tick on the same clock. Missing frames,
  real gaps, and boundaries at least two ticks away still fail closed.
- Applied the policy to both nonterminal lookahead and terminal segment
  boundaries, and removed lossy fallback normalization from segment identity
  and packaged smoke/parity timing identities.
- Added forensic sites 056 for an admitted boundary that is not exact on its
  declared clock and 057 for an exact rational that is not equal or adjacent
  to the admitted boundary. Site 054 remains the distinct no-admission exact
  conversion failure.
- Documented every deterministic, conventional video, audio, output validator,
  assembly, finalization, and cadence path that can convert or compare media
  clocks in `docs/v4/MEDIA_CLOCK_CONVERSION_POLICY_V4.md`.

### Qualification boundary

- Added named unit and production-path fixture coverage for the Ferris
  quarter-tick rational, exact frame-148175 reconstruction, exact terminal
  values, nonterminal 90 kHz lookahead, a two-tick mismatch, and a genuine
  missing-frame mismatch.
- Conventional video and audio paths were verified to forward native sample
  timestamps rather than projecting them onto the 90 kHz video clock; their
  existing timing/audio preservation suites remain the applicable regression
  coverage.
- The fresh full serial macOS Debug scheme completed 540 tests: 537 passed,
  zero failed, and three expected opt-in capture tests skipped. The focused
  timing and conventional-media run completed 23 of 23 tests.
- Created and strictly verified the local universal Apple Distribution archive
  at `/Users/jimdaley/Library/Developer/Xcode/Archives/2026-09-30/Mirmir-1.4.1-10-TestFlight.xcarchive`.
  It has not been uploaded, notarized, installed, or asserted as shipped. The
  previously documented Desktop path is not present.
- The preserved approximately 91 GB Ferris job was not resumed. Its
  authenticated checkpoint remains at ordinal 2,468 with 2,469 committed
  segments and `nextInputSampleIndex` 148,140. The 148,176-frame source therefore
  leaves a 36-frame terminal remainder. A zero-byte
  `recovery-v4/decision.lock` first observed during source-test verification is
  retained without interpretation or deletion. This source repair does not
  claim a completed large-media job, installed-app replacement, notarization, or
  shipment.

## [1.4.0] - 2026-09-30

### Cache management

- Added a security-scoped cache-location selector in Settings for the durable
  workflow root, with an explicit return to internal Application Support.
- Added confirmed deletion for individual cached jobs, finished jobs,
  unfinished jobs, and all inactive cache contents. Completed output movies
  remain outside cache deletion.
- Journaled job deletion before removing queue-owned source snapshots,
  checkpoints, and resumable state so deletion survives relaunch. Active jobs
  fail closed until paused or cancelled.

### Development diagnostics

- Upgraded the existing `Mirmir/Modules/Diagnostics` store in place while
  retaining the single `diagnostics-v1.jsonl` journal and its existing
  JSON/Markdown operator export surface.
- Added forensic failure context for job/workflow/queue identity, requested and
  actual backend, fallback, geometry, pixel/color/HDR state, exact sample
  timing and stable timing site, durable checkpoint/publication state, disk and
  volume facts, opened audio topology, nested errors, raw development paths,
  and file/function/line.
- Connected conventional processing, Deterministic v4 segment and cadence
  failures, atomic output publication, checkpoint publication/commit, and the
  application coordinator to that existing store.
- Preserved raw local paths for development diagnosis while rejecting
  credential-shaped values, authorization data, passwords, secrets, tokens,
  and security bookmarks. Shipping redaction remains a separate pre-release
  review; this change does not declare a shippable build.
- Added integration tests that invoke the production cadence validator and
  atomic publisher with an injected existing-store recorder, verifying the
  production failure paths submit the timing site and publication state.
- Made error-16 cadence recording independent of task-local processing context:
  the timing site, exact rationals, sample index, source location, and nested
  error persist even when optional job/workflow/backend context is unavailable.
- Bound coordinator finalize records to the durable job's real checkpoint-head
  URL on both success and failure instead of omitting the checkpoint path.
- Added production-path tests for context-free cadence failure recording and
  finalize failure export with its durable checkpoint path.
- Completed the full serial macOS Debug scheme on this development tree: 532
  tests, 529 passed, zero failed, and three expected opt-in capture tests
  skipped.

## [1.3.4] - 2026-09-28

### Changed

- Separated the Upscale job workspace from the primary Compare player. Upscale
  now presents only the live processing preview, while Compare accepts any two
  user-selected movies or the last completed job for synchronized playback,
  scrubbing, replay, audio, and draggable split review.
- Allowed a failed durable job to resume only from an authenticated,
  nonterminal checkpoint. Resume removes an uncommitted next-boundary artifact,
  revalidates the bound request and checkpoint, and does not rebuild already
  committed segments.
- Closed each deterministic segment writer session at the verified encoded end
  before publication, preserving the committed segment boundary.

### Reliability

- Disk-full checkpoint publication reports the underlying ENOSPC condition and
  leaves the previous authenticated head readable and nonterminal.
- Conventional processing keeps every requested source audio track with a
  serialized reader drain; Deterministic v4 planning and output validation
  preserve the source audio topology unless preservation is explicitly off.
- Deterministic cadence uses exact `1001/24000` for 23.976 fps sources, accepts
  legal 90 kHz NTSC timestamps, rejects real gaps, and attaches stable site IDs
  to error-16 timing failures.

### Qualification boundary

- The macOS Debug scheme completed 510 tests: 507 passed, zero failed, and
  three expected opt-in capture tests skipped.
- A visible production Deterministic v4 Metal run of the original 1:43 Ferris
  source, at 7680 × 3264 with audio preservation enabled, committed through
  source frame 8,760 without error 16, passing the timing path that previously
  failed. It then failed under ENOSPC. The reported error-16 timing defect is
  resolved; further large-media testing is retained as extended qualification
  and is not a first-release blocker.
- Removed deterministic resource allocation and automatic VideoToolbox
  geometry adaptation from the first-release target. Version 1.3.4 retains
  truthful VideoToolbox capability gating without hidden fallback.
- Version authorities are aligned at 1.3.4 build 8. The retained Desktop
  `Mirmir-Beta-1.3.3-7.xcarchive` remains the prior build-7 handoff artifact and
  is not part of this source release.

## [1.3.3] - 2026-09-25

### Fixed

- Preserved every source audio track when audio preservation is enabled in
  conventional and Deterministic v4 jobs. Conventional reads are serialized,
  Deterministic planning cannot consent to an audio drop in that mode, and
  output validation checks language, enabled/default state, and alternate
  audio-group topology rather than merely checking for an audio track.
- Accepted legal 90 kHz NTSC timestamp quantization in deterministic cadence
  validation while retaining rejection of real discontinuities. Every error
  16 (`invalidSampleTiming`) throw now includes a stable site identifier for
  the next failing source report.
- Accepted user-selected regular source files with multiple hard links while
  retaining the single-link invariant for queue-owned private snapshots.
- Gated VideoToolbox Smooth Motion + Spatial Upscale with the Mac's reported
  2× source-frame maximum dimension and pixel-count limits. These processor
  limits are independent of connected-display resolution, and unsupported
  inputs are now shown as unavailable before processing begins.

### Product boundaries

- At the build-7 boundary, the original 1:43 Deterministic v4 beta asset had
  not been rerun and the reported error-16 failure remained open. Version 1.3.4
  later passed the corrected timing path through frame 8,760; DV4-001 is now
  resolved while broader large-media qualification continues under DV4-002.
- Deferred the resource-allocation control; it is not included in this
  release.
- Kept attached-picture preservation on the deterministic v4 whole-asset path.
  Conventional backends do not preserve attached pictures.
- Kept Automatic's existing opaque-input policy. It does not select the
  deterministic v4 routes for opaque H.264 sources.

### Verified

- Completed the macOS Debug scheme with 500 tests: 497 passed, zero failed,
  and three expected opt-in capture tests skipped. Coverage includes
  conventional and Deterministic v4 second-audio-track retention and legal
  90 kHz NTSC cadence through the original source's approximate frame range.
- Created the local 1.3.3 build 7 TestFlight handoff archive at
  `/Users/jimdaley/Desktop/Mirmir-Beta-1.3.3-7.xcarchive`. The archive is not
  tracked by Git, and App Store Connect/TestFlight upload remains owner-run.
- Completed real-file deterministic CPU and Metal upscales of the retained
  960 × 960 H.264 fixture to playable 1920 × 1920 HEVC outputs with 241 frames,
  audio, attached picture, and identical decoded frames.
- Paused a deterministic Metal job after its first durable boundary, resumed
  it from the persisted checkpoint, and completed the verified output.
- Confirmed cancellation left no destination movie and did not prevent a
  later enqueue of the same source.
- Advanced repository and Xcode version authorities to 1.3.3 build 7 without
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
