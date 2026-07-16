# ASH Plane-Aware V3 Production Wiring Design

Date: 2026-07-16

Status: wiring implemented locally; release activation remains gated

Source baseline: `108dbc5` (`Add authenticated format 1.2 calibration foundations`)

## Decision

Replace the app's disposable P05 spatial path with a fail-closed, immutable,
plane-aware V3 path only after the repository contains an authorized release
artifact set for both supported routes. Keep the P05 backend available only to
explicit development and test callers. Never fall back from a rejected V3
artifact or runtime failure to P05, a fixed descriptor, the non-ASH selector,
or a conventional scaler.

This document defines wiring and verification boundaries. It does not select a
calibration candidate, authorize production execution, change runtime code, or
claim a quality-gate result.

## Evidence Boundary

The current application constructs `ASHDeterministicUpscaleBackend` in
`Mirmir/Modules/UpscalerEngine/DefaultUpscalerEngineService.swift:178`. That
backend defaults to `.developmentP05` and `.p05DevelopmentOnly` at
`Mirmir/Modules/UpscalerEngine/ASH/ASHDeterministicUpscaleBackend.swift:20` and
invokes `ASHSpatialReferencePipelineV2.process` at line 46. The configuration
identifies itself as `development_only_not_release_locked` and
`p05_disposable_causal_selector_v1` in
`Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialRuntimeConfigurationV2.swift:4`.

The development selector also declares its disposable role at
`Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialDispatchV2.swift:53`. The active
pipeline supplies no history or temporal evidence at
`Mirmir/Modules/UpscalerEngine/ASH/ASHSpatialReferencePipelineV2.swift:270` and
records `temporal_history_used` as `false` at line 391.

The V3 foundation already provides these separately tested operations:

- strict locked-configuration JSON loading through
  `ASHLUTLockedConfigurationJSONLoaderV3.load`;
- immutable format-1.2 binary loading through `ASHLUTBinaryCodecV3.load` at
  `Mirmir/Modules/UpscalerEngine/ASH/ASHImmutableLUTLoaderV3.swift:23`;
- one analyzer traversal and separate luma/chroma dispatch grids through
  `ASHLockedRuntimeV3.prepareFrame` at
  `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedRuntimeV3.swift:4`;
- plane-local sample reconstruction through
  `ASHLockedRuntimeV3.evaluateSample` at
  `Mirmir/Modules/UpscalerEngine/ASH/ASHLockedSampleRuntimeV3.swift:18`.

`MirmirTests/ASHLockedPlaneAwareRuntimeV3Tests.swift` proves that frame
preparation constructs exactly two plane grids, luma and chroma can use
different locked modes and coordinates, Cb and Cr share the chroma dispatch,
and chroma edge confidence is transported exactly but remains behaviorally
inert. Production wiring must not claim that confidence changes selection.

The repository does not currently bundle a locked configuration, a format-1.2
route LUT, or a V3 release manifest under `Mirmir/Resources/ASH`. Fresh G04,
G05, and G06 evidence is still required by `local-work-plan.md:13-15`; P07 and
P08 remain open at lines 16-17.

## Current and Target Call Graphs

Current application path:

```text
DefaultUpscalerEngineService.runJob
  -> ASHDeterministicUpscaleBackend
  -> ASHSpatialReferencePipelineV2
  -> ASHSpatialDevelopmentSelectorV2
  -> ASHSpatialOperatorBankV2
```

Target locked path:

```text
DefaultUpscalerEngineService.runJob
  -> ASHLockedArtifactStoreV3.artifacts()
  -> ASHLockedUpscaleBackendV3(route, immutable artifact set)
  -> ASHLockedFramePipelineV3.process
       -> ASHLockedRuntimeV3.prepareFrame
       -> ASHLockedRuntimeV3.evaluateSample for Y, Cb, and Cr
       -> existing NV12 output boundary
```

The offline compiler remains outside the application call graph. Application
code must not call `ASHLUTLeafCompilerV3.compile` or create a LUT from runtime
inputs.

## Artifact Publication Boundary

Introduce an immutable `ASHLockedArtifactSetV3` value containing:

- the exact locked-configuration JSON bytes;
- the parsed `ASHLUTLockedConfigurationV3`;
- the exact locked-mapping JSON bytes and parsed analyzer configuration;
- one manifest-declared format-1.2 LUT for `.direct2x`;
- one manifest-declared format-1.2 LUT for `.direct3Over2`;
- the immutable bytes retained by each `ASHLUTLoadedV3`;
- the release-manifest bytes and verified manifest hash;
- the native-parity manifest bytes and verified file binding;
- the configuration ID and all six configuration hash bindings.

Introduce `ASHLockedArtifactStoreV3` as the only application-facing loader.
It must perform an atomic load before publishing the set:

1. Read the release manifest, locked-configuration JSON, locked mapping,
   native-parity manifest, and both route LUTs from one bundled resource root.
2. Validate the manifest schema, self-hash, status, configuration identity,
   route identities, filenames, sizes, and whole-file SHA-256 bindings.
3. Parse the configuration with
   `ASHLUTLockedConfigurationJSONLoaderV3.load`. The loader already requires
   schema `2.0.0`, status `locked`, an exact field set, and a valid self-hash.
4. Parse the locked mapping against the configuration's mapping SHA-256 and
   require `locked_before_p07`, the same configuration ID, boundary mode, and
   route analysis-grid steps.
5. Load each LUT with `ASHLUTBinaryCodecV3.load`, passing its declared route and
   the same parsed configuration. The loader already verifies format version,
   route, dimensions, CRCs, payload SHA-256, configuration hashes, entry
   provenance, parameter indices, and spatial-context mirrors.
6. Require exactly one artifact for each supported route. Duplicate, missing,
   unknown, or route-swapped artifacts reject the complete set.
7. Publish only after both routes pass. Retain the exact validated bytes for the
   lifetime of the set.

Loading is once per artifact set, not once per frame. A failed load remains a
typed failure; it must not publish a partial cache or a development substitute.

The existing `ASHLockedReleaseLUTManifestV2` accepts the format-1.1/V2
configuration contract. V3 wiring therefore requires a version-specific
release-manifest loader rather than coercing `ASHLUTLockedConfigurationV3` into
the V2 manifest type.

## Backend Boundary

Add an internal backend protocol with the two operations already used by the
job loop:

```swift
protocol ASHUpscaleBackend: AnyObject, Sendable {
    func reset()
    func process(source: CVPixelBuffer, into destination: CVPixelBuffer) async throws
}
```

Make the existing P05 backend conform without changing its algorithms. Add
`ASHLockedUpscaleBackendV3` with these invariants:

- construction requires a route and a fully published
  `ASHLockedArtifactSetV3`;
- construction selects the already loaded LUT for that exact route;
- neither JSON nor LUT bytes are parsed during `process`;
- one frame analysis creates both plane dispatch grids;
- each output sample evaluates at most the primary and secondary candidates
  already recorded in the LUT;
- luma uses `.luma`; Cb and Cr use `.cb` and `.cr` with the prepared chroma
  siting;
- no runtime tree, compiler path, selector search, or state-disabled control is
  available;
- cancellation is checked before analysis, between reconstructed planes, and
  before writing the destination;
- reset clears backend diagnostics. It does not mutate the immutable artifact
  set.

Move the NV12 extraction, normalized-plane conversion, chroma-siting handling,
and destination writing currently private to
`ASHDeterministicUpscaleBackend` into a shared internal frame-codec boundary.
The extraction and writing arithmetic must remain byte-identical during this
refactor; separate tests must bind that property before the locked backend uses
it.

## Frame Pipeline

`ASHLockedFramePipelineV3.process` must perform exactly this sequence:

1. Validate 4:2:0 NV12 geometry, code range, route output dimensions, and
   destination geometry before analysis.
2. Convert source Y, Cb, and Cr codes into the existing analyzer code planes and
   normalized `ASHSpatialPlaneV2` values.
3. Call `ASHLockedRuntimeV3.prepareFrame` once with the route LUT, the same
   locked configuration, all three code planes, and the source chroma siting.
4. Reconstruct every luma destination coordinate using the luma dispatch grid.
5. Reconstruct every Cb and Cr destination coordinate using the shared chroma
   dispatch grid and the same chroma-siting rule.
6. Require finite, legal-range results and exact expected plane dimensions.
7. Encode the normalized results to destination NV12 codes and preserve chroma
   siting metadata.

Format 1.2 mirrors all temporal contexts to spatial behavior. This integration
must request only the spatial context and must expose no temporal-quality claim.
Temporal history remains a separate P10 overlay bound to the final spatial LUT
hash.

The currently implemented locked-mapping schema fixes its input contract to
BT.709, 8-bit 420v video range, left chroma siting, and 4:2:0 subsampling.
Until a separately calibrated and hash-bound mapping expands that contract, the
V3 backend must reject 420f and every non-left chroma location before writing
the destination. The broader profile-contract enumeration is not release
authorization for those inputs.

## Service Activation and Failure Policy

`DefaultUpscalerEngineService.runJob` currently begins the media output session
before constructing the P05 backend. The locked sequence must be:

1. Probe the input.
2. Select and validate the supported route.
3. Obtain the complete published V3 artifact set.
4. Construct the route-specific locked backend.
5. Begin the media output session.
6. Process frames using only that backend instance.

This ordering rejects unavailable or invalid release assets before an output
session can create or mutate the destination.

The default service factory must request the locked backend. Development tools
and tests may inject an explicit P05 factory. There is no automatic fallback.
At the service boundary, typed artifact and runtime errors may be presented as
an `UpscalerEngineError`, but telemetry must retain a stable non-sensitive
failure category.

Activation is prohibited until all of these conditions are evidenced:

- a fresh current-source G04 pass;
- a fresh current-source G05 pass;
- a selected, complete, immutable P06 release and G06 pass;
- a G07 locked-holdout pass over the exact release bytes;
- bundled resource bindings that reproduce the authorized release hashes;
- backend integration tests over both routes and all supported code ranges.

P08 Metal parity and performance remain required before representing the path
as the production-performance implementation.

## Telemetry and Output Identity

Record once per job:

- configuration ID;
- release-manifest SHA-256;
- selected route;
- LUT whole-file and payload SHA-256 values;
- locked luma/chroma coordinate and anisotropy modes;
- analysis-grid source step.

Record aggregate counts for affine correction, affine fallback, numerical
fallback, and primary/secondary evaluations. Do not emit source pixels, state
grids, local feature values, filesystem paths, or unbounded per-pixel events.

Output identity must bind the locked configuration ID, manifest hash, route LUT
hash, format version, and spatial-only status. A job with any numerical fallback
may complete only if the existing locked runtime returns its declared
conservative result; telemetry and output identity must record the count.

## Incremental Implementation Slices

Each slice requires review and approval before the next begins.

1. **V3 release artifact loader:** add the version-specific manifest model,
   atomic artifact store, corruption tests, and no application-path change.
2. **Shared NV12 frame codec:** extract the current private conversion boundary
   with byte-for-byte regression tests and no selector change.
3. **Locked frame pipeline:** wrap `prepareFrame` and `evaluateSample`; validate
   dimensions, plane roles, siting, ranges, and construction counters on small
   fixtures.
4. **Locked backend:** implement the backend protocol and route-specific V3
   backend; keep service selection unchanged.
5. **Service wiring:** load artifacts and construct the backend before beginning
   the media session; require explicit test injection for P05.
6. **Gate closure:** rerun focused and full Xcode tests, guardrails, fresh
   G04-G06, G07, and the resource-manifest audit before default activation.
7. **P08:** replace the CPU reference evaluation with Metal only after byte or
   tolerance parity, determinism, performance, and memory gates pass.

## Required Verification

Artifact tests must reject:

- missing or duplicate route LUTs;
- route-swapped LUTs;
- truncated, extended, or resealed files;
- configuration self-hash mismatch;
- manifest size or SHA-256 mismatch;
- a LUT compiled from a different configuration;
- unknown versions, planes, contexts, policies, or reserved bits.

Runtime tests must prove:

- one artifact load per artifact set and zero loads per frame;
- one analysis traversal and exactly two dispatch-grid constructions per frame;
- route- and plane-local coordinate and anisotropy behavior;
- Cb and Cr independence while sharing the chroma dispatch grid;
- source-aligned exactness where the LUT declares it;
- legal-range finite output and exact route dimensions;
- maximum two operator evaluations per output sample;
- no development selector or compiler invocation from the locked call graph;
- deterministic repeated output for identical input bytes and artifacts;
- cancellation and malformed-buffer failures do not append a partial frame.

Integration tests must preserve frame timing, audio passthrough, progress,
cleanup, code range, and chroma-siting metadata already owned by the media
pipeline.

## Non-Goals

- Selecting or fabricating calibration values.
- Treating current V3 test fixtures as release assets.
- Activating chroma edge confidence before a versioned, calibrated semantic
  contract makes it causal.
- Adding temporal reconstruction before P10.
- Adding state-graph regularization without a preregistered ablation.
- Compiling LUTs in the app.
- Silently recovering from release-asset rejection with a different algorithm.

## Completion Criterion

The wiring is complete only when the default app path consumes an authorized,
immutable V3 artifact set, no P05 selector is reachable from that path, both
routes reproduce their locked CPU reference outputs, invalid assets fail before
output-session creation, and the required evidence gates pass against the exact
bundled bytes.
