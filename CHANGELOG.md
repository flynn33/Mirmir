# Changelog

All notable project changes are recorded here.

## Unreleased

### Roadmap and Evidence Status

- Published the complete Mirmir Apple-Native Adaptive Video Enhancement Roadmap
  1.0.0, dated 2026-07-18, as canonical Markdown and machine-readable JSON and
  embedded the complete Markdown roadmap in the repository README.
- Established R00-R13 as the forward product direction, with A01-A18 capability
  tracking, C01-C11 retained/repurposed work, explicit authorization gates, and
  evidence-backed completion rules.
- Published the current ASH V3 branch to preserve source, tests, partial results,
  failed results, and diagnostic evidence. This is not a product release and does
  not authorize a tag, GitHub Release, production Auto mode, holdout access, G08,
  or a market-position claim.
- Reclassified ASH V3 as a retained deterministic reference, control-plane
  substrate, and evidence source rather than the presumptive future reconstruction
  engine. Existing failed and partial evidence remains historical and unchanged.
- Recorded the target Forsetti boundary: retain approved architecture and templates
  without including or depending on the complete Forsetti framework repository.

### Added

- Added the Apple-native ASH V3 Metal spatial runtime for direct 2× and direct
  3/2× NV12 routes. Six cached compute pipelines perform luma/chroma analysis,
  state packing, immutable LUT dispatch decode, Y/CbCr reconstruction, and a
  fixed-size telemetry reduction.
- Added a cancellable three-slot reusable Metal resource ring. Frame resources
  remain retained through GPU completion and the AVFoundation append boundary;
  generation tokens prevent stale or duplicate lease release.
- Added production Metal summaries and bounded telemetry for decode status,
  state/message/operator histograms, declared and actual candidate invocation
  counts, affine correction/fallback, numerical fallback, parity
  recomputation, source-aligned preservation, luma/chroma output counts,
  command status, and GPU timestamps.
- Added release identity derivation for configuration, release manifest, route,
  whole-file and payload LUT hashes, format version, spatial-only status,
  coordinate/anisotropy modes, and analysis-grid step.
- Added AVFoundation timed output metadata for the complete release identity and
  final numerical-fallback total. Output verification reopens the encoded file
  and requires one exact full-duration metadata group before atomic publish.
- Added `Scripts/inject-ash-p06-release.sh` and the final app build phase for
  exact authorized P06 resource injection. The phase accepts exactly six
  single-link regular files, rejects linked/additional/missing members,
  byte-compares the copies, and removes stale injected bytes when disabled.
- Added the schema-2 `P06ProductionCoordinatorV2`, including typed provider
  boundaries, authenticated development replay, validation admission,
  split-separated candidate evaluation, transitive manifest closure, complete
  selection reopening, and explicit rejection of historical V1 documents.
- Added `ProductionCandidateEvaluationProviderV2`, the concrete bridge from an
  authorized Swift native measurement factory to schema-2 candidate evaluation
  or typed failure documents.
- Added `ProductionControlSelectionV2` for deterministic fixed and conventional
  ranking, persisted non-ASH predecessor verification, authenticated split
  snapshots, exact transitive authorization assembly, and mandatory verifier
  replay. The service has no holdout capability.
- Added schema-2 P07 execution-authority, transaction, runtime-evidence,
  holdout-measurement, failure, and G07 publication contracts.
- Added an unhosted `MirmirP08Tests` launcher under the Release-configured
  `Mirmir P08` scheme. It runs an ordinary `Mirmir.app` as a separate process,
  rejects `Contents/PlugIns`, binds the app tree before and after execution,
  and does not use `TEST_HOST`, `BUNDLE_LOADER`, or `@testable` access.
- Added dormant native P08 app modes for exhaustive Metal descriptor parity,
  compute-only and end-to-end performance, resource-ring/memory measurement,
  per-route Instruments observations, per-route GPU captures, and native
  evidence assembly. Normal app launch cannot enter these modes.
- Added strict P08 schemas and evidence verification for 416
  route/plane/phase/descriptor rows, exact fixture bytes, paired GPU overhead,
  30-frame warmup plus 300-frame measurement, both routes and performance
  modes, three result bundles, six Instruments traces, and two GPU captures.
- Added the self-hashed pre-G07 P08 seal. It binds the ordinary app tree,
  executable, metallib, exact six release resources, native document, P06
  inputs, and every raw archive while explicitly recording no G08 claim, no
  G07 binding, and no holdout access.
- Added post-G07 promotion and atomic G08 finalization. Promotion reopens the
  unchanged pre-G07 closure before adding G07, preserves the canonical seal and
  native envelope in the promoted identity, and compares copied bindings with
  their originals. The promotion-only finalizer derives all gate checks from
  supplied measurements and publishes an explicit pass or failure rather than
  accepting a caller-supplied decision; the standalone finalizer command is
  non-authorizing.
- Added the P06 V3 release-bundle manifest and exact 23-artifact closure,
  current-source G04/G05 staging, expanded G06 release integration classes,
  and native runtime-correction evidence bindings.
- Added `run_p06_production_calibration_v2.py` as the sole authorizing P06
  command. It composes actual G04/G05/G06 reopening, Apple-native schema-2
  measurement, V3-only release publication, and atomic exact-six publication
  with a terminal receipt. Added `export_p08_release_resources_v3.py` for
  idempotent exact-six recovery from an already authoritative V3 release.
- Added the earlier locked V3 artifact store, shared NV12 codec, CPU reference
  pipeline, backend/factory boundaries, development ASH resources, product
  workspace, app icon, and repository guardrails.

### Changed

- The default product composition now passes `DefaultMetalRenderingService` to
  `ASHLockedUpscaleBackendFactoryV3`; production jobs construct
  `ASHMetalUpscaleBackendV3`. The CPU locked backend remains an explicit
  development/test reference.
- Locked artifact validation and Metal backend construction occur after source
  probing and route selection but before AVFoundation output-session creation.
  Missing or invalid release bytes fail closed without output state or an
  algorithm fallback.
- Per-frame backend processing now receives the frame index and exact
  presentation timestamp identity. Command-buffer telemetry preserves that
  context.
- The backend completion object is retained across writer backpressure and
  append, moving ring-slot release from GPU completion to the frame transaction
  boundary.
- The product path performs no full-frame CPU reconstruction loop, runtime LUT
  tree generation, production `waitUntilCompleted`, or full-frame GPU
  readback. The fixed summary readback is the production diagnostic boundary.
- The locked contract remains BT.709-declared, 8-bit `420v`, video-range,
  left-sited 4:2:0, direct 2×/3/2×, and spatial-only. The pixel-buffer boundary
  validates range, siting, geometry, and route dimensions but does not use the
  YCbCr-matrix attachment as an independent authorization input.
- P06 release construction and reopening now bind the schema-2 calibration,
  selected evaluation, attempt ledger, non-ASH development/validation closure,
  locked policies/configuration, both LUTs, native parity, evidence closure,
  and artifact manifest as one exact V3 transaction.
- Selected mapping/operator documents remain the exact content-addressed
  `calibration_candidate` bytes covered by evaluation and compiler identities;
  the enclosing release/evidence authority supplies the pre-P07 lock without
  rewriting those bytes or creating a selection-hash cycle.
- P07 production execution now consumes schema-2 authority only and has no V1
  fallback path. Before holdout intent it authoritatively reopens the actual
  external G04/G05/G06 trees under the unchanged clean HEAD and requires their
  fresh semantics and tree identities to match the P06-sealed authority.
- The P07 guard now consumes only the exact V3 `configuration-lock-v2.json`,
  shares the P06 descriptor-safe nine-file validator, rejects legacy aliases,
  and preserves pre-intent startup failures in collision-safe non-opening
  diagnostics.
- P08 evidence is collected before holdout access and sealed. G07 is added only
  during promotion of unchanged bytes, preserving the one-opening P07 order.
- P08 profile/capture checks now consume measured GPU analysis/reconstruction,
  command completion/status, CPU-loop/tree-generation, candidate/fallback, and
  full-frame-readback counters. End-to-end speed and frame-rate thresholds are
  enforced for both routes.
- The historical `run_p06_production_calibration.py` entry point is explicitly
  non-authorizing: it can validate legacy anchor diagnostics but constructs no
  candidate or release and exits with status `2`.
- Python remains offline validation and test tooling only. The application and
  its runtime dependencies remain Apple-native Swift/SwiftUI/AVFoundation/
  Metal code and neutral resources.

### Fixed

- Split Metal analysis and reconstruction normalization. Analysis now preserves
  video-range luma/chroma excursions for CPU-equivalent state derivation, while
  reconstruction clamps every source code before exact, filtered, or fallback
  sampling; adversarial coverage spans both routes and both NV12 planes.
- Corrected Metal telemetry separation so rejected LUT decodes, affine
  fallback invocations, parity recomputations, and numerical fallbacks are
  distinct counters.
- Corrected luma versus chroma operator and fallback accounting in the reduced
  per-frame summary.
- Prevented a hosted XCTest plugin or a testability-rebuilt app from qualifying
  as exact P08 production-app evidence.
- Prevented same-geometry substitute benchmark media from satisfying P08 by
  binding exact fixture SHA-256 values.
- Prevented mutation of the app, executable, metallib, release resources,
  native measurements, P06 inputs, or raw archives between pre-G07 validation
  and G08 promotion.
- Prevented stale release resources in reused build products when exact P06
  injection is not enabled.
- Prevented an exact-six export from claiming `published_and_reopened` without
  reopening the new terminal receipt and all six members after receipt
  publication. The exporter now replays the complete release/support authority
  and exact raw release-manifest bytes before committing the staged receipt as
  the final transaction action; failed final readback quarantines the owned
  receipt instead of leaving a success artifact.
- Prevented exact-six resource or receipt outputs from overlapping and mutating
  the authenticated V3 release or any of its six frozen support trees.
- Quarantined failed or interrupted exact-six resource/receipt staging
  artifacts under collision-safe, nonblocking `.failed` names so their bytes
  remain diagnosable without being adopted or preventing an explicit recovery
  attempt.
- Corrective diagnostic CLI tests resolve POSIX paths before comparing temporary
  roots, avoiding the macOS `/var` to `/private/var` alias mismatch.
- Repository guardrails exclude preserved `Artifacts` evidence from mutable
  source scans while retaining source, metadata, lint, build, and test checks.

### Validation Status

- Focused source-level Metal parity, route/plane coverage, two-candidate chroma
  counting, resource-ring, output-identity, injection, schema-2 coordinator,
  control-selection, candidate-provider, and P08 evidence tests are part of the
  current implementation.
- The prior merged V3 wiring checkpoint recorded 280 tests: 279 passed, one
  expected skip, and zero failed. It also recorded zero strict SwiftLint
  violations across 172 files, successful Debug and Release builds,
  repository guardrails, and an app launch smoke check.
- Those historical results predate this release-closure source and are not
  claimed as current G04-G08 evidence. Fresh results are authoritative only in
  their exact same-commit immutable publications under `Artifacts/ASH/`.

### Release Boundaries

- No authorized `Mirmir/Resources/ASH/LockedV3` set is checked into source.
  Exact six-file release bytes are injected only for an authorized build.
- Fresh G04 and G05, native runtime correction, G06, P06 publication, exact-app
  integration, the single P07/G07 execution, and derived G08 finalization must
  complete in dependency order. This changelog does not claim those gates have
  passed.
- Fixture tests establish contract enforcement for their exact tested bytes;
  they do not authorize a release or establish perceptual superiority.
- P08 GPU captures cover exhaustive synthetic route/plane/phase/descriptor
  parity fixtures. They are not represented as natural-frame exhaustive
  descriptor coverage.
- The locked input contract does not authorize `420f`, non-left chroma, 10-bit,
  HDR, BT.2020, or arbitrary resolution pairs.
- The repository has no iOS or Windows target.
