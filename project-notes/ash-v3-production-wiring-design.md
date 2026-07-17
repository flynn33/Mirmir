# ASH Plane-Aware V3 Production Wiring and Release-Closure Design

Date: 2026-07-16

Status: source implementation present; exact-byte G04-G08 execution remains
dependency-gated and is not claimed by this document

Historical wiring implementation: `47e9cef9d574ab03e7729c5f7125ec32e1484f6e`

Historical wiring merge: `85b5d4637797ca84ab2ca2721a3165f7a2f21e0c`
(PR #7)

## Decision

The product path is a fail-closed, immutable, plane-aware ASH V3 Metal
implementation. It executes only after the complete authorized six-file
runtime set has been loaded and validated. The CPU locked implementation is a
development, parity, and benchmark reference. P05, runtime compilers/selectors,
fixed controls, non-ASH selection, and Lanczos are never error fallbacks for a
product job.

Calibration and release evidence remain offline. The macOS application is
implemented with Swift, SwiftUI, AVFoundation, CoreVideo, Metal, VideoToolbox,
and Apple platform libraries. Python under `validation/` creates and verifies
calibration/evidence artifacts; it is not linked into or bundled with the
application target.

Source implementation is necessary but not sufficient for activation. The
authoritative outcome is the dependency-ordered immutable evidence over one
clean source commit, one P06 release, and one ordinary Release app. This tracked
document records contracts and procedures only; it does not predict a gate
result.

## Release Invariants

The release transaction enforces these invariants:

1. Development and validation complete before any holdout access.
2. The selected calibration, control authorization, LUTs, and policies form one
   schema-2 P06 V3 closure.
3. Both runtime LUTs and all release identity files are immutable before P07.
4. The ordinary Release app contains exactly the authorized six P06 runtime
   files, byte for byte.
5. P08 native measurements bind that exact app, executable, metallib, release
   set, fixtures, device, source, and raw archives.
6. The P08 pre-G07 closure is sealed before the holdout is opened.
7. P07 is opened once through schema-2 execution authority over the exact P06
   bytes.
8. G08 reopens the unchanged pre-G07 closure and adds the exact G07 publication;
   it derives the decision from measurements rather than accepting a caller's
   pass/fail value.
9. A failed stage is preserved as failure evidence. It is never relabeled.

## Apple-Native Product Boundary

The `Mirmir` Xcode application target includes Swift, SwiftUI, Metal source,
asset catalogs, JSON/CSV resources, and the pinned Forsetti Swift package. The
offline Python packages are absent from `project.yml`'s application sources.

The product bootstrap constructs `DefaultMetalRenderingService`,
`AVFoundationMediaPipeline`, and `DefaultUpscalerEngineService`, injecting:

```swift
ASHLockedUpscaleBackendFactoryV3(bundle: .main, metal: metalService)
```

That initializer chooses the factory's production-Metal execution mode. The
factory's `resourceRoot` and `artifactStore` initializers choose the CPU
locked-reference implementation and are reserved for explicit development or
test composition.

## Product Call Graph

```text
MirmirForsettiBootstrap
  -> DefaultUpscalerEngineService.submit
       -> media.probe
       -> StrategySelector.choose
       -> ASHLockedUpscaleBackendFactoryV3.makeBackend
            -> ASHLockedArtifactStoreV3.artifacts
            -> ASHMetalUpscaleBackendV3
                 -> ASHMetalSpatialRuntimeV3
       -> media.beginSession
       -> for each FrameRecord
            -> backend.process(source:into:context:)
                 -> acquire three-slot ring lease
                 -> create CVMetalTexture-backed luma/chroma views
                 -> encode six ASH V3 compute pipelines
                 -> commit with completion-handler bridge
                 -> read fixed-size summary and return completion/lease
            -> AVFoundationMediaSession.appendOutput
            -> completion.finishAfterAppend
       -> session.finish(finalMetadata:)
            -> append timed ASH identity
            -> finish writer
            -> reopen exact output and verify identity, timing, and decoded planes
            -> atomically publish output
```

Backend construction precedes `beginSession`, so release rejection cannot
create output state. A frame lease survives GPU completion and writer
backpressure, and is returned only after append accepts the destination. Any
error cancels the active media transaction and follows the existing cleanup
boundary; no substitute scaler is selected.

## Exact Six-File Runtime Set

The product runtime permits exactly:

| File | Authority |
| --- | --- |
| `lut-manifest-v3.json` | Canonical schema-3.0 release manifest and route/file bindings |
| `locked-compiler-input-v2.json` | Shared locked format-1.2 configuration |
| `locked-mapping.json` | Analyzer, route, input-format, and spatial-policy binding |
| `direct2x.ashlut` | Direct 2× immutable LUT |
| `direct3over2.ashlut` | Direct 3/2× immutable LUT |
| `native-lut-parity-manifest-v3.json` | Native compilation/parity binding |

`ASHLockedArtifactStoreV3` requires one non-symlink directory and exactly six
non-symlink regular members. It verifies canonical JSON, exact fields,
self-hashes, sizes, whole-file SHA-256 values, configuration and mapping
identity, route identity, payload SHA-256, parameter/entry counts, provenance,
and header/payload CRCs. Both LUTs must load against the same configuration.
The actor assigns its cache only after the entire set succeeds; a failure
publishes no partial object.

The source tree contains no authorized `Mirmir/Resources/ASH/LockedV3`. Root
ASH assets are development/reference material and cannot substitute for P06.

### Exact Build Injection

`Scripts/inject-ash-p06-release.sh` is the last explicit application build
phase. Its authority input is `MIRMIR_P08_P06_RELEASE_ROOT`.

When set, the input must be an absolute non-symlink directory with exactly the
six names above. Every member must be a regular, non-symlink file with one hard
link. The script removes prior staging/output state, copies through
`TARGET_TEMP_DIR`, byte-compares each staged file, moves the complete directory
into `Contents/Resources/ASH/LockedV3`, and byte-compares every bundled file.

When unset, it removes both staging and any injected `LockedV3` from the build
product. This prevents a reused DerivedData location from carrying an earlier
release into an unrelated build.

The application store still performs its independent runtime reopening; build
injection is not trusted as runtime validation.

## Metal Runtime

`ASHMetalSpatialRuntimeV3` constructs these six pipeline states once:

1. `ash_v3_analyze_luma`
2. `ash_v3_analyze_chroma_and_pack_state`
3. `ash_v3_decode_dispatch`
4. `ash_v3_reconstruct_luma`
5. `ash_v3_reconstruct_chroma`
6. `ash_v3_finalize_reduction`

It also creates one immutable route-LUT buffer and a 512-entry decoder table.
It consumes the shared device, command queue, and `CVMetalTextureCache`. Per
frame it reuses ring-slot buffers for state samples, decoded dispatches,
telemetry reduction, summary, and uniforms.

### Frame Validation

Before encoding, the runtime requires:

- source and destination `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`;
- exact NV12 plane geometry;
- left-sited source chroma matching the locked mapping;
- destination dimensions exactly derived by direct 2× or direct 3/2×; and
- the selected LUT route and configuration equal the loaded artifact set.

It sets the destination chroma-siting attachment from the locked mapping. The
mapping validates a BT.709 declaration, but the pixel-buffer boundary does not
treat the source YCbCr-matrix attachment as an independent authorization field.

Analysis and reconstruction intentionally use different video-range
normalization domains. The luma/chroma analyzers preserve legal-boundary
excursions when producing deterministic state, matching the CPU analyzer.
Reconstruction first clamps every source code to the normalized `[0, 1]`
domain before exact, filtered, or conservative-fallback sampling, matching the
CPU NV12 codec. Adversarial tests cover codes below and above the nominal
16...235 luma and 16...240 chroma ranges for both routes and both planes.

### Command and Resource Transaction

One command buffer clears the diagnostic buffers, runs both analyzers, decodes
all luma/chroma phase dispatches from the immutable LUT, reconstructs both NV12
planes, and reduces diagnostics. The production command path uses
`MetalCommandBufferCompletionBridge`, which installs an `addCompletedHandler`,
commits, resumes a checked continuation exactly once, checks cancellation, and
returns the status/GPU timestamps. There is no product
`waitUntilCompleted` call.

Retained GPU resources include:

- source and destination `CVPixelBuffer` objects;
- luma/chroma `CVMetalTexture` references and their `MTLTexture` values;
- state, dispatch, reduction, summary, and uniform buffers; and
- immutable LUT and decoder buffers.

The ring permits one to three slots and defaults/maxes at three. Waiting
acquisitions are FIFO and cancellable. Each lease carries a UUID generation;
release is ignored unless the slot/generation pair is current. Returning a slot
clears frame-retained objects while keeping reusable buffers allocated.

`ASHMetalCompletedFrameV3` owns the lease after a successful GPU completion.
`DefaultUpscalerJobHandle` defers its `finishAfterAppend` call until
`appendOutput` returns. Deinitialization is a second fail-safe; lock-protected
lease removal makes the release idempotent.

### Reduction and Failure Policy

The product reads a fixed 18-word summary rather than a full-frame state or
output readback. It reports exact/corrected/rejected dispatch decode, one/two
candidate dispatches, actual total/luma/chroma operator invocations, numerical
fallback totals split by plane, affine fallback, parity recomputation,
source-aligned preservation, output counts, fatal faults, and analysis cells.

Rejected decode, affine fallback, parity recomputation, and numerical fallback
are distinct counters. A nonzero fatal fault throws and prevents append.
Recoverable fallback follows the locked conservative result and remains visible
in telemetry and final output identity.

Development parity access can read analysis state words from the retained
buffer. That method is not used by the product call graph and is not a
production full-frame readback.

## Output Identity and Telemetry

Both CPU-reference and Metal locked backends derive the same bounded release
identity:

- `configuration_id`;
- `release_manifest_sha256`;
- `route`;
- `lut_whole_file_sha256` and `lut_payload_sha256`;
- `lut_format_version=1.2`;
- `spatial_only=true`;
- luma/chroma coordinate modes;
- luma/chroma anisotropy modes; and
- `analysis_grid_source_step`.

Construction emits one `ash_locked_release_identity` media observation. Metal
frames add fixed reductions and command-buffer observations keyed by frame
index and PTS. Counters saturate. The release-identity and Metal-frame payloads
contain no source pixels, per-sample features, state grids, or filesystem
paths.

Before the writer is created, `backend.finalOutputMetadata` supplies the full
metadata key set, including a current numerical-fallback count. Finalization
recomputes that count after all frames while preserving the exact key set.
AVFoundation writes one QuickTime timed metadata group from zero through the
session end. `OutputMediaVerifier` reopens the temporary MP4 and requires:

- exactly one metadata track and one timed group;
- group duration equal to the completed video timeline;
- no duplicate `com.mirmir.ash.*` key;
- nonempty UTF-8 values; and
- exact equality to the backend's final dictionary.

The output transaction publishes only after that reopen succeeds.

## Schema-2 P06 Calibration Coordinator

`validation/calibration_v2/production_coordinator_v2.py` composes the scheduler,
persistence adapters, concrete candidate provider, validation admission,
selection, and manifest closure. It does not provide a measurement algorithm.

`CandidateEvaluationProviderV2` must return exactly one of:

- `CandidateEvaluationSuccessV2` containing a schema-2 evaluation with a
  schema-2 control-authorization bundle; or
- `CandidateEvaluationFailureV2` containing typed failure reasons and a
  schema-2 failure document.

Provider exceptions are not silently converted; coordinator-domain exceptions
are fatal. A historical evaluation schema or historical control bundle is
rejected.

The coordinator's dependency order is:

1. Compute exact logical/physical candidate and cache identities.
2. Run development only, preserving typed success/failure attempts.
3. Publish and reopen `attempts-v2.ndjson` after the development search returns.
4. Build and publish the validation-admission document from that frozen ledger.
5. Open validation only for admitted candidates and use a distinct cache
   namespace plus the exact admission binding.
6. Publish/reopen validation successes or typed failures.
7. Traverse each evaluation's source evidence, control bundle, and bundle
   dependencies into one path- and hash-unique artifact manifest.
8. Publish/reopen the schema-2 run ledger and calibration selection.

An authenticated preexisting terminal attempt ledger can be replayed. A fully
published selection can be reopened on restart without provider calls. A fresh
run does not journal each attempt during the active development search, so the
coordinator must not be represented as mid-search crash-resumable.

The run ledger records that all development attempts preceded validation,
development and validation cache namespaces were distinct, validation opened
after development freeze, the holdout was not accessed, and calibration did
not write release locks.

## Concrete Candidate Provider and Control Authorization

`validation/calibration_v2/production_candidate_provider_v2.py` defines
`ProductionCandidateEvaluationProviderV2`. Its production construction
boundary is the callable `production_candidate_evaluation_provider_v2`, which
requires a native Swift factory and exposes no analytic/fake production option.

For each exact scheduler request it:

1. reopens every bound source-gate file;
2. opens a native split-scoped measurement session;
3. obtains the control-selection request and verifies its run/split/shared-bank
   scope against the candidate;
4. calls `ProductionControlSelectionV2.authorize`;
5. measures only the authorized candidate; and
6. binds native measurements, source evidence, candidate identity, and the
   verified control-authorization bundle into schema `2.0.3` output, or returns
   a typed failure.

`ProductionControlSelectionV2` has no holdout path and performs no candidate
measurement. It consumes raw aggregate publications from
`RawControlAuthorizationArtifactPublisherV2` and an already persisted V2
non-ASH selector closure containing the selected artifact, all predecessor and
dependency bindings, and an exact authenticated snapshot.

For development, the service accepts only development publications and ranks
the complete fixed descriptor and conventional algorithm sets by the locked
lexicographic objective with deterministic stable-ID tie breaks. For
validation, it additionally requires distinct development matrices and
publication sets, the exact validation admission, a one-file authenticated
admission snapshot, and semantic admission verification.

The service persists/reopens fixed and conventional selections, objective
summaries, output manifests, non-ASH dependencies, and the complete bundle.
`ControlAuthorizationVerifierV2` must replay every transitive binding before
`ProductionControlSelectionResultV2` is returned.

## P06 V3 Release Closure and G06

The V3 P06 release manifest binds 23 artifact roles:

- schema-2 calibration selection, selected evaluation, run ledger, validation
  admission, and attempt ledger;
- non-ASH development ledger/selection and validation neighbor/selection;
- baseline-ablation budget and live-holdout preopen verification;
- locked mapping, operator bank, quality policy, metric policy, and compiler
  input;
- both format-1.2 LUTs, native parity manifest, and V3 LUT manifest;
- configuration lock, evidence closure, and artifact manifest.

The release builder publishes once and the validator reopens the exact
filesystem closure, canonical documents, transitive hashes, schema identities,
selection/control relationships, configuration identity, and release-local
support evidence.

The sole authorizing production entry point is
`validation/calibration_v2/tools/run_p06_production_calibration_v2.py`. Its
dependency-ordered transaction reopens the actual current-source G04/G05/G06
trees, runs the concrete Apple-native schema-2 measurement/calibration path,
publishes and reopens only the schema-3 release family, and then atomically
publishes/reopens the exact-six P08 resource set plus its terminal receipt. It
does not call the legacy release publisher.

The similarly named `run_p06_production_calibration.py` is retained only for
historical anchor diagnostics. It constructs no provider, candidate,
calibration run, or release and exits with status `2`. If an authoritative V3
release already exists but the six-file export was not completed,
`export_p08_release_resources_v3.py` reopens that release and publishes or
idempotently replays only the exact-six resource set and receipt. Recovery does
not rerun P06 or change the release decision.

The release also seals one semantic receipt and complete external-tree binding
for each fresh G04, G05, and G06 result. Before P07 can construct a holdout
guard or persist transaction intent, the P07 runner requires the real external
gate roots plus the G05 instruction package/baseline and G06 execution-run
identity. It invokes the authoritative gate reopeners again under the unchanged
clean HEAD, recomputes every external tree, and requires those fresh semantics
and tree hashes to equal the P06-sealed execution authority. Receipt assertions
alone cannot authorize the holdout.

The live guard accepts only `configuration-lock-v2.json`. It calls the same
descriptor-safe schema-2 validator used by the V3 release reopen, requires the
ordered nine-entry `configuration_files` table, and reopens the exact V3 names,
including `locked-compiler-input-v2.json` and `lut-manifest-v3.json`. The old
scalar-hash binder and its filename aliases are not reachable from this path.
Failures before a configuration can enter the executor are published as an
exclusive, canonical, fsynced non-opening diagnostic. Existing or foreign
collision state is rejected; the diagnostic cannot serve as holdout authority.

The selected mapping and operator-bank documents remain the exact
content-addressed `calibration_candidate` bytes measured by the selected
evaluation. They are not rewritten to embed selection hashes: doing so would
change the compiler input and both LUT identities, and embedding the selected
evaluation hash in bytes already covered by that evaluation would create a
cryptographic cycle. `locked_before_p07` authority is therefore asserted only
by the enclosing V3 release bundle, evidence closure, and execution-authority
documents that bind those immutable candidate bytes.

G06's V3 application integration set is exactly:

- `ASHLUTFormat12V3Tests`;
- `ASHLockedArtifactStoreV3Tests`;
- `ASHLockedPlaneAwareRuntimeV3Tests`;
- `ASHLockedFramePipelineV3Tests`;
- `ASHLockedUpscaleBackendV3Tests`; and
- `ASHBackendIntegrationTests`.

G06 also binds Debug/Release execution, native runtime correction, the release
product, release-lock suites, lint, and its enclosing evidence tree. Metal
production-performance authorization remains G08's responsibility; source
Metal unit tests do not replace G08.

## Exact-App P08 Producer

### Unhosted Launcher

`MirmirP08Tests` is a separate unhosted unit-test target exercised by the
Release-configured `Mirmir P08` scheme. It has no app target dependency,
`TEST_HOST`, or `BUNDLE_LOADER`, and it does not import the app module with
`@testable`. Instead it launches the ordinary Release executable with
`Foundation.Process`.

The launcher requires an ordinary normalized `Mirmir.app`, rejects symlinks,
aliases, special/multiply-linked files, and rejects `Contents/PlugIns` before
hashing. The tree hash is the SHA-256 of canonical sorted records binding every
directory and every file path/size/hash. Each slice receives the pre-launch
tree hash and must leave the tree identical after exit.

This avoids both invalid evidence modes:

- inserting the XCTest bundle under `Mirmir.app/Contents/PlugIns`; and
- rebuilding the measured app with testability enabled.

### Dormant App Entry Point

Normal launch has neither the exact argument nor P08 environment and follows
the product UI path. Evidence mode requires exactly one argument,
`--mirmir-p08-native-evidence`, plus nonempty `MIRMIR_P08_APP_MODE`. Supplying
only one half is invalid and exits. Supported modes are:

- `metal-parity`;
- `performance`;
- `resource-ring`;
- `profile-direct-2x` and `profile-direct-3-over-2`;
- `capture-direct-2x` and `capture-direct-3-over-2`; and
- `assemble`.

The native context reopens and binds source commit/tree, production app tree,
executable, default metallib, external P06 release root, bundled six-file root,
P06 release manifest, selected evaluation, control-authorization bundle,
best-fixed selection, device identity, and the exact fixture files.

### Measurement Contract

Metal parity contains exactly 416 ordered route/plane/phase/descriptor rows:

```text
direct 2x:       2 planes * 4 phase pairs * 16 descriptors = 128
direct 3-over-2: 2 planes * 9 phase pairs * 16 descriptors = 288
total:                                                     416
```

Rows bind numeric error limits, exact state/message/LUT lookup bytes, and
repeat-output hashes. GPU captures use this exhaustive synthetic parity scope;
they are not represented as natural-frame exhaustive descriptor coverage.

Performance covers both routes in `compute_only` and `end_to_end` modes. It
binds exact fixture filenames, SHA-256 values, dimensions, frame counts,
ordered PTS, and product writer settings. Each Metal side uses 30 warmup and
300 measured frames. Full ASH and same-bank fixed control run under identical
conditions, with paired GPU samples used to derive p95 dispatch overhead. CPU
reference frames provide the same-machine speedup denominator.

Resource evidence runs both full-resolution routes with the same 30/300
protocol, ring capacity at most three, zero in-flight frames after drain, no
resource failure, bounded retained resources, repeat identity, and memory
drift at or below the preregistered limit. The native producer does not claim
an acquisition-timeout property because this path does not independently
measure a bounded acquisition deadline.

Profile and capture predicates consume objective runtime observations rather
than producer constants: analysis and reconstruction GPU frame counts,
full-frame CPU reconstruction loops, runtime-tree generation, candidate and
fallback invocation summaries, asynchronous command-completion mode, submitted
and completed command-buffer counts, failed-command counts, full-frame GPU
readbacks, and captured command-buffer status/error. Speedup and frames-per-
second thresholds apply to the end-to-end full-ASH row for both routes.

Raw evidence requires three XCTest result bundles, Time Profiler/Allocations/
Metal System Trace for each route (six traces), and one GPU capture per route.
The G08 limits and dispatch budget come from the locked policy/tolerance
contracts, not producer defaults.

## Pre-G07 Seal and G08 Promotion

`stage_p08_native_evidence.py` calls `stage_pre_g07`. Before any G07 input
exists, it validates and copies:

- canonical native measurements;
- the ordinary `Mirmir.app` tree with no `Contents/PlugIns`;
- exact executable, metallib, and bundled six-file identity;
- P06 release, selected evaluation, and locked metric policy;
- all three XCTest results, six traces, and two captures; and
- the exact current repository identity.

It derives every check available before G07, then writes
`p08-pre-g07-manifest.json`. The canonical self-hashed manifest binds the native
file, app tree, input files, raw archive trees, source identity, check-set hash,
and the observed `available_checks_all_satisfied` value, while explicitly
stating `g08_claimed=false`, `g07_publication_manifest_sha256=null`, and
`holdout_accessed=false`. Post-G07 promotion refuses the seal unless the
available-check value is true.

After G07, `promote_after_g07` reopens that seal and independently rehashes the
native file, app tree, executable, metallib, six resources, P06 inputs, every
raw archive, and exact top-level closure. Any mutation rejects promotion. It
copies those unchanged bytes into a hidden G08 staging root and adds the exact
schema-2 G07 publication. The copied staging identity also preserves the
canonical pre-G07 seal and native-measurement envelope as first-class files;
promotion compares each copied binding with the original before finalization.

The supported post-G07 entry is `stage_p08_native_evidence.py
promote-after-g07`; the standalone `finalize_g08.py` command is intentionally
non-authorizing. Internal finalization rejects a caller-created gate manifest,
validates the preserved seal/native provenance plus all evidence and identity
bindings, derives 15 mandatory checks, and writes either `status=pass` or
`status=fail`. It preserves raw artifacts, fsyncs the staging directory,
atomically renames it to `Artifacts/ASH/<run-id>`, fsyncs the parent, and
reopens the final manifest.

The checks are:

1. Metal execution;
2. parity coverage;
3. numeric parity;
4. exact state/message/LUT identity;
5. same-device determinism;
6. measurement protocol;
7. same-machine speedup;
8. frames per second;
9. dispatch-overhead budget;
10. calibration-estimate error;
11. no runtime tree/full-frame CPU loop;
12. no production wait;
13. no avoidable full-frame readback;
14. bounded resource ring and memory; and
15. profile/capture closure.

## Dependency-Ordered Execution

All tracked source and documentation must be committed before gate execution.
No tracked edit may be introduced between source checkpoint and the gates whose
identity names that commit.

```text
1. clean source checkpoint
2. fresh G04 over that commit
3. fresh G05 over that commit
4. native runtime correction evidence
5. fresh G06 and immutable P06 V3 release
6. inject exact six P06 files into ordinary Release Mirmir.app
7. exact-release app integration and P08 preflight
8. run all native P08 slices and create the pre-G07 seal
9. execute P07 once and publish G07 over the exact P06 bytes
10. promote unchanged P08 bytes with G07 and finalize G08
```

G04/G05/G06/P06 precede P07 because the holdout authority is bound to their
exact closed configuration. P08 native measurement precedes P07 so the app and
performance evidence are sealed without access to holdout results. G08 follows
G07 because its final evidence identity includes the G07 publication.

Gate reports, manifests, result bundles, traces, captures, and release bytes
remain in external immutable `Artifacts/ASH` run trees. No README/changelog edit
is required after a pass or failure, preserving the same-commit identity.

## Verification Boundary

Source tests and builds can establish implementation properties such as exact
resource rejection, route/plane parity, deterministic fixture output,
lease/cancellation behavior, metadata reopen, schema validation, closure
reopening, and adversarial mutation rejection. They cannot establish:

- that the current source has passed fresh G04-G08;
- that a particular candidate is authorized;
- that holdout quality passed;
- that an app tree contains the authorized release bytes; or
- that performance or memory thresholds passed on the measured device.

Those are facts only after the corresponding immutable evidence artifacts are
created and reopened.

## Non-Goals

- Selecting or fabricating calibration values in application code.
- Treating generated fixtures or root ASH resources as release assets.
- Adding a product Python runtime.
- Compiling LUTs or selecting control algorithms in the app.
- Claiming chroma edge confidence is causal when the locked contract keeps it
  behaviorally inert.
- Adding temporal reconstruction before its separately authorized phase.
- Treating synthetic parity capture as natural-video descriptor coverage.
- Silently recovering from release, Metal, identity, or evidence rejection.

## Completion Criterion

Source completion requires the implemented native Metal product call graph,
exact release injection, identity/metadata boundary, schema-2
calibration/control composition, unhosted P08 producer, pre-G07 seal, and
promotion-only G08 finalization path to pass their source verification.

Release completion is stricter. The exact clean commit must have fresh G04,
G05, runtime correction, G06, immutable P06, exact-app integration, one P07/G07
execution, and a derived G08 publication over unchanged app/native/raw bytes.
Until those external artifacts exist and validate, release activation remains
unclaimed.
