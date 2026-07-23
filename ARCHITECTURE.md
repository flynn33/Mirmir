# Mirmir Architecture

> **Current status:** This document records the preserved ASH V3 implementation
> and the Apple-native target architecture defined by
> [Roadmap 1.0.1](docs/roadmaps/Mirmir_Apple_Native_ASH_Roadmap_2026-07-18.md)
> and [ADR 0001](docs/decisions/0001-apple-native-adaptive-architecture.md).
> ASH V3 testing, failure evidence, and diagnostic artifacts are retained, but
> their publication is not a release or gate promotion.

- Roadmap phase `R00`: `passed`
- Roadmap phase `R01`: `passed`
- Roadmap phase `R02`: `passed` for declared software function
- Roadmap phase `R03`: `passed`
- Roadmap phase `R04`: `passed` for declared software function
- Roadmap phase `R05`: `in_progress`
- Roadmap phase `R06`: `in_progress` and unaccepted
- Roadmap phase `R07`: `passed` for deterministic software function
- Roadmap phase `R08`: `passed` for declared analysis-only software function
- Roadmap phase `R09`: `passed` for declared bounded-residual software function

Mirmir is a native Apple-silicon (`arm64`) macOS application. Its application
target is implemented in Swift and SwiftUI over Foundation, AVFoundation,
CoreMedia, CoreVideo, Metal, VideoToolbox, and Apple platform services. Python
modules under `validation/` implement offline calibration, evidence production,
schema validation, and gate finalization. They are not linked into or embedded
in `Mirmir.app`.

The R00 source uses an app-owned Pattern B runtime with one UI module and four
service modules assembled once through `MirmirAppBootstrap` and injected through
Mirmir-owned factories. The Forsetti repository is reference-only; it is not a
package, framework, submodule, vendored source, build, or runtime dependency.

R00 passed against the exact PR #13 merge checkpoint
`6b94564dda07acfba25e83876b5bf859d1970f15`. The accepted inventory preserves
the original baseline identities separately from the post-migration source
identities and records only tracked no-pixel holdout metadata.

Production launch activates the exact five-module set in a fixed order and
renders `MirmirProductionRootView` only after the UI module and primary view are
registered. Debug launch with `MIRMIR_DEVELOPER_WORKSPACE=1` adds a read-only
module/status surface. It provides no activation or deactivation controls.

Normal product upscaling remains fail-closed. The production composition injects
an unavailable transition engine, Start remains disabled, and the UI reports:
“No production-default backend is enabled; product routing remains unavailable.”

R02 began from local R01 closure commit
`555ae5a1afce1e492bdc89b6b14f2ba269edc524`, tree
`2fbe72d85ace42cc925c45b17d53dd8866a8275b`. That predecessor is explicitly
recorded as `local_unpublished_closure` with `accepted_merge_commit: null`; no
merge acceptance is claimed. The frozen R02 contract requires an immutable
capability registry, typed backend/session outcomes, explicit FIFO actor
serialization, five separate stage roles, deterministic single-primary planning,
visible fallback, complete processing identity, and preservation of the existing
media-transaction and Metal lifetime boundaries. Production remains unavailable.

R02 deterministic conformance is recorded at local unpublished closure commit
`673b0582c0b4d6b4ad81de6b01ba9e3f35f4e3d4`, tree
`a5e95d810abacbdb872ddc6e94125103831e6fba`; acceptance was not claimed at
that historical checkpoint. R03 starts locally from that exact closure under a
frozen 8-bit NV12, SDR BT.709, 720p-to-1080p and 1080p-to-2160p baseline
contract. Unavailable backend or support-stage execution is recorded as
`not_observed`; it does not qualify a backend, select a production default, or
support a performance or quality claim.

The later additive R02 functional acceptance binds source commit
`eeabc4224100bc8ed86ae1208189bee508844210`, tree
`ac402f993805cca499d2f688c6186c4684ce8dba`, and a fresh six-suite Xcode run
with 27 tests passed, zero failed, and zero skipped. Two direct tests bind
production bootstrap to `UnavailableUpscalerEngineService` and prove its typed
fail-closed `backendUnavailable(reason:)` rejection. This is the intentional R02
production-unavailable boundary, not project completion or production
enablement. R02 is `passed` only for `declared_software_function_only`; the
frozen `not_claimed` record remains historical. Production upscaling, a
production default, Auto, holdout access, quality or performance claims, product
publication, and release remain unauthorized.

The additive R03 v2 decision binds source
`dfdf1f12ecb22be1c6395d57017bf750fd76496f`, tree
`c3558b90bf647febd900524e7afc40f8c2efbba4`, and qualifies only genuine
`r03.mps.lanczos` (`A11`) for `functional_product_eligibility`. The additive
operator-overridden functional acceptance record then revalidates the passing
R02 common-session and R03 A11 software evidence and marks R03 `passed`. The
production composition still injects the unavailable service; no default, Auto,
holdout, quality, performance, product-publication, or release authority follows.

The additive R04 functional acceptance binds source commit
`ab77e97867d51168e90c0190f6430d4acd769e68`, tree
`446f71bb584f5d1fffcd20a17ac5e5507d3222b6`, and 42 passing tests across the
contracts, session-adapter, availability, and functional suites. Its
deterministic runtime drives source-derived frames through the real separate
quality and low-latency R04 backends and production FIFO, proving complete 2×
media transactions, runtime-gated 1.5× admission, cancellation, identity,
reopen-before-publication, resource release, atomic publication, and no silent
fallback. R04 is `passed` only for `declared_software_function_only`. Native
VideoToolbox model execution and readiness, hardware, simulator, and operator
observation remain `not_observed`; the unavailable production composition and
all default, Auto, product, quality, performance, publication, and release
boundaries remain unchanged.

R07 implementation checkpoint
`1b46ad469265a6ba837a8449d28b8850889f1d3f`, tree
`09d3a48df01738bb26077aadfd83c08e389a1dc2`, adds a deterministic functional
coordinator over the existing R06 decision contract. It integrates scene-cut,
discontinuity, motion/occlusion, bounded history, A04 temporal filtering, A13
luma-guided chroma reconstruction, A15 protected-mask upsampling, artifact and
protected-region evaluation, and exact N+1 postflight feedback. State changes
commit only after the full transaction succeeds.

The operator-defined R07 acceptance covers this deterministic fixture-simulation
software function. Its frozen comparison requirement is outside the forward
roadmap and non-authorizing. The fixture executor records simulation identity
separately from referenced native identities; it does not claim native framework
or physical-hardware execution. The product composition remains unavailable,
R06 remains `in_progress` and unaccepted, and no production default, Auto,
quality, performance, publication, or release authority follows.

R08 begins from accepted R07 merge commit
`3fd13e57ec95b1ed98df71f4c83ab165bdfbab6b`, tree
`eb1614dd2a93e1bc4e1911bcf74f41cf372a3304`. Its architectural boundary is an
optional cohesive Core AI analysis subservice inside the existing model-assets
module; the fixed five-module composition does not change. The forward gate is
deterministic software function: typed analysis outputs, identity, cadence,
decision-context integration, lifecycle, budgets, cancellation, no final-pixel
output, and deterministic bypass must work as claimed. Comparison-based testing
is outside the forward roadmap. Native Xcode 27/Core AI execution is
supplemental and remains `not_observed` when unavailable. R08 itself supplied no
residual authority; the later operator `resume work` directive separately starts
R09 under an exact accepted-R08 evidence binding.

The R08 implementation checkpoint
`368b9284883c189be6a1139df6208bf0e88139dd`, tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`, preserves that boundary. Its 42
checkpoint-bound tests across 10 suites passed with zero failures and zero skips.
They verify the exact analysis-output and identity contracts, deterministic
scheduling and lifecycle, bounded cache and resource behavior, transactional
cancellation and bypass, conservative `ASHDecisionContext` integration,
protected-mask composition, and rejection of pixel or backend-selection
authority. R08 is `passed` only for `declared_software_function_only` under
deterministic fixture simulation. Comparison-based testing supplied no
acceptance authority. Native Core AI, Xcode 27, model,
hardware, simulator, and operator-observed execution remain `not_observed`; the
fixed five-module composition and unavailable product route remain unchanged.

R09 binds raw accepted-R08 evidence SHA-256
`0d81917a93cf56cae867c11b7c65fb3c85e53b7596929cf9eec2ef09c24634b0`,
implementation commit `368b9284883c189be6a1139df6208bf0e88139dd`, and tree
`f8e73d193b7b0c9df7005a7aa006de48ca48f77c`. Its architecture is a bounded
post-primary-scaler stage: the model may propose three-plane signed residuals,
but ASH alone authorizes localized application and supplies the plane, content,
edge, source, temporal, confidence, and resource bounds. Every request binds the
frame, shot, stream generation, primary route, model, processing, and contract
identity. The Apple-only result is immutable and is returned on every mismatch,
safety failure, cancellation, or budget failure. Deterministic fixture values
are software-test inputs, not product thresholds. Native execution remains
`not_observed`; production default, Auto, claims, publication, and release stay
unauthorized.

The R09 implementation checkpoint
`3ba7b2b5fdbde3a3f90f011cb548b85d46b2ac8b`, tree
`5f19024af0837d5efd54855bcf0fd705a50eadc9`, passed all 26 selected tests across
four settled suites with zero failures and zero skips. The accepted
`qualified_local_residual` outcome proves only the declared bounded proposal,
authorization, protected-region, identity, transactional rollback, and exact
NV12 software contracts under deterministic fixture simulation. R09 is
`passed` for `declared_software_function_only`; native Core AI/framework/model,
hardware, simulator, and operator observations remain `not_observed`, and no
product qualification, production/default/Auto routing, quality, performance,
publication, release, or R10 progression authority follows.

The later R10/R11 control boundary follows the same software-function rule. R10
must implement a deterministic, finitely bounded, constraint-preserving,
resumable optimizer/calibration service. R11 must implement traceable evidence
and claim-scope machinery, reject unsupported claims, and emit an honest
no-claim disposition by default. Any `market_leading_claim` remains separately
blocked without exact evidence and operator authorization.

## Target Apple-Native Adaptive Architecture

The target data flow is AVFoundation decode, source profiling, capability
discovery, deterministic ASH orchestration, an immutable enhancement plan,
qualified Apple-native backend sessions, postflight quality monitoring, and
AVFoundation encode/reopen verification. ASH becomes the control, temporal
governance, policy, and explainability layer. Core AI remains optional, begins
with analysis, and now has an accepted bounded R09 software experiment;
production residual routing remains disabled.

The current module inventory below is retained implementation evidence. Planned
interfaces and backends are not represented as implemented until their roadmap
phases produce accepted evidence.

## Current App-Owned Module Inventory

| Activation | Module ID | Kind | Entry point | Responsibility |
| ---: | --- | --- | --- | --- |
| 1 | `com.mirmir.app.metal` | Service | `MetalRenderingServiceModule` | Metal device, queue, and texture-cache readiness |
| 2 | `com.mirmir.app.model-assets` | Service | `ModelAssetsServiceModule` | Roadmap-transition model availability |
| 3 | `com.mirmir.app.media-pipeline` | Service | `MediaPipelineServiceModule` | AVFoundation read/write and atomic export |
| 4 | `com.mirmir.app.upscaler-engine` | Service | `UpscalerEngineServiceModule` | Job orchestration and backend availability |
| 5 | `com.mirmir.app.ui` | UI | `MirmirUIModule` | Product workspace and UI state |

Static `MirmirModuleDescriptor` values are the single source of truth. The
factory registry rejects duplicate module IDs and entry points and verifies the
identity returned by each factory. `MirmirModuleHost` requires the exact set,
exactly one UI module, and the UI module last; startup failure rolls back every
started module in reverse order. The former dynamic JSON manifests are removed.

## R00 Product Composition and Preserved ASH V3 References

```text
MirmirAppBootstrap
  -> DefaultMetalRenderingService
  -> RoadmapTransitionModelAssetsService
  -> AVFoundationMediaPipeline
  -> UnavailableUpscalerEngineService
       -> backendUnavailable(reason:)
  -> MirmirModuleFactoryRegistry
  -> MirmirModuleHost
  -> MirmirViewRegistry
```

`DefaultUpscalerEngineService`, `ASHLockedUpscaleBackendFactoryV3`, the Metal
spatial runtime, and the VideoToolbox model-staging scaffold remain compiled as
retained reference and research code. The normal product composition has no call
site for those implementations and does not select them as a fallback.

Explicit tests and future qualified phases may construct the retained ASH
factories directly. `ASHDevelopmentUpscaleBackendFactory` likewise remains an
explicit development/test reference; neither factory is reachable from
`MirmirAppBootstrap`.

The offline LUT compiler and all Python calibration components remain outside
the application call graph. The runtime receives parsed, validated, immutable
LUT bytes and performs no per-frame JSON parsing, LUT compilation, or tree
generation.

## Historical Exact Release-Resource Transaction

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

The source tree intentionally has no checked-in `LockedV3` directory. The former
P06 build design used `Scripts/inject-ash-p06-release.sh` to require:

- an absolute, non-symlink source directory;
- exactly the six authorized names and no hidden or additional entry;
- a regular, non-symlink, single-hard-link inode for every member; and
- byte identity after staging and after installation in the app bundle.

That script remains historical tooling, but the P06 post-build phase is removed
from `project.yml` and the generated Xcode project. Normal R00 builds neither
invoke the script nor inject a locked release. The historical implementation
staged privately, replaced only the target build's `LockedV3` directory, and
compared every copied file.

## Preserved ASH V3 Reference Job Transaction

When the retained backend is constructed directly by a test or research caller,
one reference job executes in this order:

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

`run_p06_production_calibration_v2.py` formerly composed current-source
G04/G05/G06 reopening, the concrete Apple-native schema-2 provider, V3-only
release publication, and exact-six publication plus receipt. R00 retires that
monolithic authority: both the P06 V2 entry point and
`run_p07_locked_holdout.py` now return status `2` before parsing arguments or
accessing paths. The earlier `run_p06_production_calibration.py` entry point
also remains non-authorizing. A separate
`export_p08_release_resources_v3.py` recovery command can reopen an existing
authoritative V3 release and idempotently publish/reopen only its exact-six set
and receipt; it cannot alter the release decision.

The former P06 design sealed semantic receipts and complete external-tree
identities for G04, G05, and G06. Before creating holdout intent, the former
schema-2 P07 design reopened the actual external gate trees with their
authoritative validators under the unchanged clean HEAD and compared freshly
derived semantics/tree hashes with the P06 execution authority. Copied receipt
claims were not sufficient.

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

In the retired design, after the one authorized P07/G07 execution,
`promote_after_g07` first reopens
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

The source implements the app-owned runtime and preserves release-closure
machinery as historical evidence, but source presence is not a release claim.
Normal product upscaling remains unavailable because no production-default
backend has been selected or enabled, so product routing remains unavailable.
The P06/P07 commands are fail-closed, P08 remains dormant and absent from normal
workflows, and no G04-G08, holdout, release, quality, or market claim is
authorized. Failed evidence is preserved and must not be rewritten as a pass.

See [project-notes/ash-v3-production-wiring-design.md](project-notes/ash-v3-production-wiring-design.md)
for the dependency-ordered implementation record.
