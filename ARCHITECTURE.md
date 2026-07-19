# Mirmir Architecture

> **Current status:** This document records the preserved ASH V3 implementation
> and the Apple-native target architecture defined by
> [Roadmap 1.0.1](docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.md)
> and [ADR 0001](docs/decisions/0001-apple-native-adaptive-architecture.md).
> ASH V3 testing, failure evidence, and diagnostic artifacts are retained, but
> their publication is not a release or gate promotion.

- Roadmap phase `R00`: `in_progress`
- Roadmap phase `R01`: `planned`

Mirmir is a native macOS application. Its application target is implemented in
Swift and SwiftUI over Foundation, AVFoundation, CoreMedia, CoreVideo, Metal,
VideoToolbox, and Apple platform services. Python modules under `validation/`
implement offline calibration, evidence production, schema validation, and
gate finalization. They are not linked into or embedded in `Mirmir.app`.

The R00 baseline source still consumes Forsetti as a sealed package dependency
pinned in `project.yml` and the generated Xcode project to revision
`43eef7a739f3b78253c64aa4b070521ab5b1f43c`. Roadmap R00 must remove the
Forsetti repository as a build or runtime dependency while retaining the approved
Pattern B structure: one UI module plus cohesive services assembled once through
an app-owned composition root and injected through Mirmir-owned factories. The Forsetti
repository is reference-only; approved app-owned outputs adapted from its
templates may be committed to Mirmir, but the repository itself must not be
included, vendored, or referenced as a package dependency.

Production launch activates the five product modules and renders
`MirmirProductionRootView` only after the UI module is active. Framework
developer controls are limited to development deployment mode.

## Target Apple-Native Adaptive Architecture

The target data flow is AVFoundation decode, source profiling, capability
discovery, deterministic ASH orchestration, an immutable enhancement plan,
qualified Apple-native backend sessions, postflight quality monitoring, and
AVFoundation encode/reopen verification. ASH becomes the control, temporal
governance, policy, and explainability layer. Core AI remains optional and begins
with analysis; pixel residual work is separately blocked.

The current module inventory below is retained implementation evidence. Planned
interfaces and backends are not represented as implemented until their roadmap
phases produce accepted evidence.

## Current Retained Module Inventory

| Module ID | Entry point | Responsibility | Capabilities | Isolation |
| --- | --- | --- | --- | --- |
| `com.mirmir.app.ui` | `MirmirUIModule` | Product workspace and UI state | `view_injection` | Private |
| `com.mirmir.app.metal` | `MetalRenderingServiceModule` | Metal device, queue, and texture-cache readiness | None | Private |
| `com.mirmir.app.model-assets` | `ModelAssetsServiceModule` | VideoToolbox model-asset readiness | `storage`, `telemetry` | Private store |
| `com.mirmir.app.media-pipeline` | `MediaPipelineServiceModule` | AVFoundation read/write and atomic export | `file_export` | Private store |
| `com.mirmir.app.upscaler-engine` | `UpscalerEngineServiceModule` | Job orchestration and locked ASH execution | `telemetry` | Private store |

Bundled manifests use schema/template `1.1`, require Forsetti `0.1.4`, and
declare their runtime requirements. `ManifestRegistryAlignmentTests` bind the
Swift descriptors, JSON manifests, and registry factories.

## Preserved ASH V3 Product Composition

`DefaultUpscalerEngineService` depends on `ASHUpscaleBackendFactory`.
`MirmirForsettiBootstrap` injects
`ASHLockedUpscaleBackendFactoryV3(bundle: .main, metal: metalService)`. That
initializer selects the production Metal mode; the resource-root and
artifact-store-only initializers select the CPU locked-reference mode for
explicit development and tests.

```text
MirmirForsettiBootstrap
  -> DefaultUpscalerEngineService
       -> ASHLockedUpscaleBackendFactoryV3(bundle:metal:)
            -> ASHLockedArtifactStoreV3.artifacts
            -> ASHMetalUpscaleBackendV3
                 -> ASHMetalSpatialRuntimeV3
                      -> ash_v3_analyze_luma
                      -> ash_v3_analyze_chroma_and_pack_state
                      -> ash_v3_decode_dispatch
                      -> ash_v3_reconstruct_luma
                      -> ash_v3_reconstruct_chroma
                      -> ash_v3_finalize_reduction
       -> AVFoundationMediaSession
```

`ASHDevelopmentUpscaleBackendFactory` constructs the disposable P05 CPU
reference only when a development or test caller explicitly injects it. The
product bootstrap does not reference that factory, and the service does not
inspect errors to choose another algorithm. Artifact, Metal, or runtime errors
therefore remain terminal; they cannot switch to P05, a runtime compiler or
selector, a fixed control, or Lanczos.

The offline LUT compiler and all Python calibration components remain outside
the application call graph. The runtime receives parsed, validated, immutable
LUT bytes and performs no per-frame JSON parsing, LUT compilation, or tree
generation.

## Preserved Exact Release-Resource Transaction

The application bundle lookup root is
`Contents/Resources/ASH/LockedV3`. `ASHLockedArtifactStoreV3` permits exactly:

| File | Runtime role |
| --- | --- |
| `lut-manifest-v3.json` | Canonical schema-3.0 manifest, route bindings, and self-hash |
| `locked-compiler-input-v2.json` | Shared locked configuration for both LUTs |
| `locked-mapping.json` | Hash-bound analyzer and input contract |
| `direct2x.ashlut` | Format-1.2 direct 2× LUT |
| `direct3over2.ashlut` | Format-1.2 direct 3/2× LUT |
| `native-lut-parity-manifest-v3.json` | Native parity evidence binding |

The store requires a non-symlink directory and regular non-symlink members,
rejects every missing or additional name, and verifies canonical encoding,
field sets, self-hashes, file sizes, SHA-256 values, route and configuration
identity, payload hashes, entry/parameter counts, and header/payload CRCs. It
publishes its cached `ASHLockedArtifactSetV3` only after both route LUTs pass
against one configuration. A failed transaction publishes no partial cache.

The source tree intentionally has no checked-in `LockedV3` directory. During an
authorized exact-release build, the `Inject Exact P06 ASH Release` post-build
phase runs `Scripts/inject-ash-p06-release.sh`. When
`MIRMIR_P08_P06_RELEASE_ROOT` is set, the script requires:

- an absolute, non-symlink source directory;
- exactly the six authorized names and no hidden or additional entry;
- a regular, non-symlink, single-hard-link inode for every member; and
- byte identity after staging and after installation in the app bundle.

The phase stages privately, replaces only the target build's `LockedV3`
directory, and compares every copied file. When the variable is unset, it
removes stale injected resources from both the app and target-temporary paths,
so a reused build directory cannot silently retain an earlier release set.

## Job Transaction

One product job executes in this order:

1. Acquire security-scoped input and output access.
2. Probe the source and select direct 2× or direct 3/2×.
3. Load and validate the complete six-file set.
4. Construct and reset the route-specific Metal backend.
5. Create the output profile with the backend's identity metadata template.
6. Begin the AVFoundation output transaction.
7. Process and append each frame in presentation order.
8. Finish audio, final identity metadata, writer, reopen verification, and
   atomic output publication, or cancel and remove partial state.

Because step 3 precedes step 6, unavailable or invalid release bytes cannot
create a writer or temporary output transaction. A processing, append,
verification, cancellation, or cleanup failure does not select a substitute
backend.

## Metal Frame Transaction and Resource Lifetime

`ASHMetalSpatialRuntimeV3` validates source/destination NV12 format, range,
plane geometry, chroma siting, and route dimensions before creating textures.
At construction it creates six pipeline states, one immutable route-LUT buffer,
one immutable 512-entry decoder buffer, and one three-slot resource ring. The
shared Metal texture cache comes from `DefaultMetalRenderingService`; none of
those objects is recreated per output sample.

For each frame, the runtime:

1. acquires one cancellable ring lease;
2. creates luma/chroma source and destination texture views;
3. sizes or reuses the slot's state, dispatch, telemetry-reduction,
   telemetry-summary, and uniform buffers;
4. encodes clear, luma analysis, chroma analysis/state packing, immutable LUT
   dispatch decode, luma reconstruction, chroma reconstruction, and fixed-size
   reduction into one command buffer;
5. commits through `MetalCommandBufferCompletionBridge`, which uses a completion
   handler and Swift continuation rather than `waitUntilCompleted`;
6. validates command status and the fixed-size summary, rejecting a fatal
   numerical-fault count; and
7. returns `ASHMetalCompletedFrameV3` while transferring ownership of the ring
   lease.

The runtime retains both pixel buffers, every `CVMetalTexture` reference and
`MTLTexture`, all per-slot buffers, and immutable LUT/decoder buffers through
GPU completion. `DefaultUpscalerJobHandle.processFrame` retains the returned
completion object while `AVFoundationMediaSession.appendOutput` applies writer
backpressure and appends the destination. Its `defer` then calls
`finishAfterAppend`, clearing retained frame resources and releasing the ring
slot. Error and deinitialization paths release once; generation tokens reject a
stale or duplicate release.

This boundary caps the configured and supported in-flight lease count at three.
The production path reads only the fixed-size telemetry summary after GPU
completion; development parity access to the full analysis state buffer is not
used by the product call graph.

The analyzer and reconstructor deliberately use different normalization
boundaries. Analyzer loads preserve luma and signed-chroma excursions outside
the nominal video-range endpoints so Metal state derivation remains identical
to the CPU analyzer. Reconstruction loads clamp each source code to `[0, 1]`
before exact, filtered, or fallback sampling, matching the CPU NV12 codec.
Boundary tests exercise both sides of the nominal range for each route and
plane.

## Locked Spatial Contract

| Property | V3 boundary |
| --- | --- |
| Routes | Direct 2× and direct 3/2× |
| Pixel layout | 8-bit NV12 `420v`, 4:2:0 |
| Mapping declaration | BT.709 |
| Code range | Video range |
| Chroma siting | Left |
| Dispatch | One primary plus an optional secondary LUT candidate |
| Boundary/coordinates/anisotropy | Exact hash-bound configuration values |
| Temporal state | None; spatial-only |
| Product execution | Metal analysis, dispatch, and Y/CbCr reconstruction |

The mapping parser validates the BT.709 declaration. Pixel-buffer runtime
validation enforces geometry, `420v`, left siting, and route dimensions; it
does not read the YCbCr-matrix attachment as an independent authorization
source. `420f`, non-left siting, 10-bit/HDR, and arbitrary route pairs are
outside this contract.

## Identity, Telemetry, and Output Reopen

Backend construction derives one release identity with:

- configuration ID and release-manifest SHA-256;
- selected route and route LUT whole-file/payload SHA-256;
- LUT format `1.2` and `spatial_only=true`;
- luma/chroma coordinate and anisotropy modes; and
- the route's analysis-grid source step.

The backend records that bounded identity once through job-scoped telemetry and
exposes the same fields as `com.mirmir.ash.*` output metadata. GPU reductions
record exact/corrected/rejected decode counts, declared candidate counts,
actual luma/chroma operator invocations, affine and numerical fallbacks, parity
recomputations, source-aligned preservation, output counts, analysis cells,
and command/GPU timing. Those ASH release-identity and frame-reduction payloads
exclude pixel values, per-sample state grids, and filesystem paths.

The reset backend's final metadata keys, including the current aggregate
numerical-fallback count, form the AVAssetWriter metadata input's format
template. At finish, the backend recomputes that count while preserving the key
set. AVFoundation writes exactly one timed group from time zero through the
video end. `OutputMediaVerifier` reopens the temporary encoded file before
publication and requires one metadata track, one group with the exact duration,
no duplicate keys, UTF-8 string values, and an exact dictionary match. Only
then can `AtomicMediaOutput` commit the output.

## Preserved Offline Schema-2 Calibration and Control Evidence

`P06ProductionCoordinatorV2` is an offline Python composition root, not an app
service. It accepts a concrete `CandidateEvaluationProviderV2`; a provider must
return a schema-2 success document or typed schema-2 failure. Historical V1
evaluation/control documents are rejected.

The coordinator enforces this dependency order:

1. Run or authenticate/replay the development search.
2. Publish and reopen the development attempt ledger.
3. Derive and publish one validation-admission artifact from the frozen
   development result.
4. Evaluate only admitted candidates in the distinct validation namespace.
5. Reopen every evaluation, failure, source-evidence binding, and transitive
   control-authorization dependency.
6. Publish the exact artifact manifest, schema-2 run ledger, and final
   calibration selection.
7. On a later invocation, return only after reopening an already complete
   selection closure.

A fresh run publishes the attempt ledger after the development search returns;
the implementation must not be described as a per-attempt crash journal. It
does authenticate and replay a supplied terminal ledger and can reopen a
complete final selection without calling the provider again.

`validation/calibration_v2/production_candidate_provider_v2.py` defines the
concrete `ProductionCandidateEvaluationProviderV2`. Its production factory is
`production_candidate_evaluation_provider_v2`; the callable requires the
authorized native Swift factory and exposes no analytic/fake production option.
The resulting provider must reopen source-gate evidence, obtain an exact
split-scoped control authorization, and bind native measurements to the
scheduler's candidate identity.

`ProductionControlSelectionV2` performs no candidate measurement and has no
holdout capability. It accepts only raw fixed, conventional, and non-ASH
aggregate publications plus a persisted non-ASH selection/predecessor closure
and authenticated snapshots. Development ranks are deterministic; validation
requires the distinct development predecessor sets and the exact validation
admission. It persists/reopens selected fixed and conventional controls,
assembles the complete transitive authorization bundle, and returns only after
`ControlAuthorizationVerifierV2` replays the closure.

The production P06 transaction copies the selected mapping, operator bank,
compiler input, and route LUTs without rewriting them. Those documents retain
their content-addressed `calibration_candidate` status because selection-hash
insertion would invalidate the compiler/LUT hashes and form a cycle with the
selected evaluation. The enclosing schema-3 release bundle, evidence closure,
and P07 execution authority bind those exact bytes and provide the
`locked_before_p07` decision. The transaction independently recompiles both
format-1.2 LUTs, requires byte identity, closes 23 artifact roles, and exports
only the six app-consumable files after reopening the immutable release.

`run_p06_production_calibration_v2.py` is the sole authorizing production P06
entry point. It composes current-source G04/G05/G06 reopening, the concrete
Apple-native schema-2 provider, V3-only release publication, and exact-six
publication plus receipt. The historical `run_p06_production_calibration.py`
entry point performs anchor diagnostics only and returns status `2`; it cannot
construct a candidate, run calibration, or publish a release. A separate
`export_p08_release_resources_v3.py` recovery command can reopen an existing
authoritative V3 release and idempotently publish/reopen only its exact-six set
and receipt; it cannot alter the release decision.

P06 seals semantic receipts and complete external-tree identities for G04,
G05, and G06. Before it creates holdout intent, the schema-2 P07 runner reopens
the actual external gate trees with their authoritative validators under the
unchanged clean HEAD and compares freshly derived semantics/tree hashes with
the P06 execution authority. Copied receipt claims are not sufficient.

## Preserved P08 Exact-App and G08 Design

`MirmirP08Tests` is an unhosted XCTest target exercised by the
Release-configured `Mirmir P08` scheme. Its build settings leave `TEST_HOST` and
`BUNDLE_LOADER` empty. The launcher receives or locates an ordinary
`Mirmir.app`, rejects a linked/aliased app and any `Contents/PlugIns`, hashes
the complete app tree, then launches `Contents/MacOS/Mirmir` as a separate
`Process`. It requires the same tree hash after every slice.

The app-side producer is dormant during normal launch. It runs only when the
sole launch argument is `--mirmir-p08-native-evidence` and
`MIRMIR_P08_APP_MODE` is present; an unmatched argument/environment pair fails
startup. Native slices cover descriptor parity, performance, resource-ring
behavior, per-route profiles, per-route GPU captures, and final assembly. The
native context reopens the P06 release, selected evaluation, control
authorization, fixed-control selection, external exact six-file root, bundled
six-file root, app tree, executable, metallib, and exact benchmark fixtures.

`stage_pre_g07` validates the native schema and app/release identity, copies the
ordinary app, selected P06 inputs, three XCTest result bundles, six Instruments
traces, and two GPU captures, evaluates every check available without G07, and
writes `p08-pre-g07-manifest.json`. That self-hashed seal binds every file/tree
and explicitly records `g08_claimed=false`, no G07 hash, and
`holdout_accessed=false`.

After the one authorized P07/G07 execution, `promote_after_g07` first reopens
the unchanged pre-G07 seal, native document, app/executable/metallib/six-file
identity, input files, and raw archives. It then adds the exact G07 publication
and invokes internal finalization. Promotion preserves the canonical pre-G07
seal and native-measurement envelope in the final identity and compares the
copied bindings with their sealed originals. The standalone finalizer command
is non-authorizing; the supported `promote-after-g07` path accepts measurements,
not a caller-supplied decision, derives all 15 mandatory checks, writes a pass
or fail manifest, fsyncs, atomically renames the hidden staging directory, and
reopens the published gate. Runtime predicates use measured GPU/CPU,
command-buffer, invocation, and readback counters, and speed/FPS thresholds
cover both routes. Gate results therefore remain external, immutable evidence
and require no tracked post-gate documentation edit.

## Activation Boundary

The source implements the product runtime and release-closure machinery, but
source presence is not a release claim. Activation remains conditional on a
clean committed source identity, fresh G04/G05, native runtime evidence, G06,
an immutable P06 V3 release, an ordinary Release app containing the exact six
authorized bytes, a single P07/G07 execution over those bytes, and a derived
G08 result over the unchanged app/native/raw evidence. Failed evidence is
preserved and must not be rewritten as a pass.

See [project-notes/ash-v3-production-wiring-design.md](project-notes/ash-v3-production-wiring-design.md)
for the dependency-ordered implementation record.
