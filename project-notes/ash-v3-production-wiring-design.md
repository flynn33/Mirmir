# ASH Plane-Aware V3 Production Wiring Design

Date: 2026-07-16

Status: implementation slices 1-5 merged; release activation and P08 remain gated

Design baseline: `108dbc5` (`Add authenticated format 1.2 calibration foundations`)

Implementation base: `80f981556847b248af158e0bd01a96d549beb66c`

Implementation commit: `47e9cef9d574ab03e7729c5f7125ec32e1484f6e`

Merge commit: `85b5d4637797ca84ab2ca2721a3165f7a2f21e0c` (PR #7)

## Decision

The app's default composition now selects a fail-closed, immutable, plane-aware
V3 backend. The backend becomes executable only when the complete authorized
release artifact set for both supported routes is present and valid. The P05
backend remains available only to explicit development and test callers. A
rejected V3 artifact or runtime failure never falls back to P05, a fixed
descriptor, the non-ASH selector, the former Lanczos polish route, or another
scaler.

This document began as the wiring design and now records the implemented
boundary plus its remaining release gates. It does not select a calibration
candidate, authorize production execution, claim a quality-gate result, or
represent the CPU reference implementation as the P08 production-performance
path.

## Evidence Boundary

Before implementation commit `47e9cef`, `DefaultUpscalerEngineService`
constructed `ASHDeterministicUpscaleBackend` directly. That backend used the
`.developmentP05` / `.p05DevelopmentOnly` configuration and
`ASHSpatialReferencePipelineV2`. It remains in the tree as a disposable CPU
reference and is reachable only through `ASHDevelopmentUpscaleBackendFactory`.

The merged product boundary is evidenced by:

- `MirmirForsettiBootstrap`, which injects
  `ASHLockedUpscaleBackendFactoryV3(bundle: .main)`;
- `DefaultUpscalerEngineService`, which requires an
  `ASHUpscaleBackendFactory` and creates its backend before `beginSession`;
- `ASHLockedArtifactStoreV3`, which publishes an atomic six-file set only after
  both route LUTs and all bindings validate;
- `ASHLockedUpscaleBackendV3`, which retains a route, configuration, mapping,
  and already loaded LUT; and
- `ASHLockedFramePipelineV3`, which prepares one frame and reconstructs Y, Cb,
  and Cr through the locked runtime before destination writing.

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

The locked integration tests add fixture-level proof for exact artifact-set
publication, both routes, repeated bit-identical output, one analyzer traversal,
two dispatch grids, source-aligned exactness, legal output, shared NV12 byte
arithmetic, and rejection before output or destination mutation. Those fixtures
are not authorized release assets and do not satisfy a quality gate.

The repository still does not bundle `Mirmir/Resources/ASH/LockedV3`. Fresh
G04 and G05 evidence, a selected P06 release with G06, G07 over the exact
release bytes, and P08/G08 remain open in `local-work-plan.md`.

## Implemented Call Graphs

Default product path, conditional on a valid locked release set:

```text
DefaultUpscalerEngineService.runJob
  -> ASHLockedUpscaleBackendFactoryV3.makeBackend
       -> ASHLockedArtifactStoreV3.artifacts
       -> ASHLockedUpscaleBackendV3(route, immutable artifact set)
  -> media.beginSession
  -> ASHLockedFramePipelineV3.process
       -> ASHLockedRuntimeV3.prepareFrame
       -> ASHLockedRuntimeV3.evaluateSample for Y, Cb, and Cr
       -> ASHNV12FrameCodec.write
```

Explicit development/test path:

```text
ASHDevelopmentUpscaleBackendFactory.makeBackend
  -> ASHDeterministicUpscaleBackend
  -> ASHSpatialReferencePipelineV2
  -> ASHSpatialDevelopmentSelectorV2
  -> ASHSpatialOperatorBankV2
```

The offline compiler remains outside the application call graph. Application
code must not call `ASHLUTLeafCompilerV3.compile` or create a LUT from runtime
inputs.

## Artifact Publication Boundary

The implementation adds an immutable `ASHLockedArtifactSetV3` value containing:

- the exact locked-configuration JSON bytes;
- the parsed `ASHLUTLockedConfigurationV3`;
- the exact locked-mapping JSON bytes and parsed analyzer configuration;
- one manifest-declared format-1.2 LUT for `.direct2x`;
- one manifest-declared format-1.2 LUT for `.direct3Over2`;
- the immutable bytes retained by each `ASHLUTLoadedV3`;
- the release-manifest bytes and verified manifest hash;
- the native-parity manifest bytes and verified file binding;
- the configuration ID and all six configuration hash bindings.

`ASHLockedArtifactStoreV3` is the application-facing loader. It requires the
resource root to be a non-symlink directory and every member to be a non-symlink
regular file. The directory must contain exactly:

- `lut-manifest-v3.json`;
- `locked-compiler-input-v2.json`;
- `locked-mapping.json`;
- `direct2x.ashlut`;
- `direct3over2.ashlut`; and
- `native-lut-parity-manifest-v3.json`.

It performs this atomic load before publishing the set:

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

Loading is once per artifact store, not once per frame. A failed load remains a
typed failure and publishes no partial cache or development substitute. A
successful set is cached and reused by subsequent backend requests.

The existing `ASHLockedReleaseLUTManifestV2` accepts the format-1.1/V2
configuration contract. The implementation therefore adds
`ASHLockedReleaseLUTManifestV3` for the schema-3.0 release manifest rather than
coercing `ASHLUTLockedConfigurationV3` into the V2 manifest type.

## Backend Boundary

The job loop now depends on this internal backend protocol:

```swift
protocol ASHUpscaleBackend: AnyObject, Sendable {
    func reset()
    func process(source: CVPixelBuffer, into destination: CVPixelBuffer) async throws
}
```

The existing P05 backend conforms without changing its algorithms.
`ASHLockedUpscaleBackendV3` implements these invariants:

- construction requires a route and a fully published
  `ASHLockedArtifactSetV3`;
- construction selects the already loaded LUT for that exact route;
- neither JSON nor LUT bytes are parsed during `process`;
- one frame analysis creates both plane dispatch grids;
- each LUT entry declares one primary and an optional secondary candidate, and
  the frame summary enforces that one-or-two declared candidate budget;
- luma uses `.luma`; Cb and Cr use `.cb` and `.cr` with the prepared chroma
  siting;
- no runtime tree, compiler path, selector search, or state-disabled control is
  available;
- cancellation is checked before analysis, between reconstructed planes, and
  before writing the destination;
- reset clears backend diagnostics. It does not mutate the immutable artifact
  set.

NV12 extraction, normalized-plane conversion, chroma-siting handling, and
destination writing now reside in `ASHNV12FrameCodec`. Both backends use that
boundary. `ASHNV12FrameCodecTests` bind active source bytes, video/full-range
conversion, destination codes, and chroma-siting propagation to the established
arithmetic.

The declared candidate count is not an invocation-level performance counter.
If an operator error is conservatively recoverable, the locked sample runtime
may invoke the conservative evaluator after a candidate attempt. Documentation
and performance evidence must not equate the one-or-two LUT budget with a hard
operator-call ceiling until invocation-level counting exists.

## Frame Pipeline

`ASHLockedFramePipelineV3.process` performs this sequence:

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
requests only the spatial context and exposes no temporal-quality claim.
Temporal history remains a separate P10 overlay bound to the final spatial LUT
hash.

The locked-mapping schema fixes its input contract to BT.709, 8-bit 420v video
range, left chroma siting, and 4:2:0 subsampling. The V3 backend rejects 420f
and every non-left chroma location before writing the destination. The broader
profile-contract enumeration is not release authorization for those inputs.
The mapping loader validates the BT.709 declaration in the hash-bound mapping;
the current pixel-buffer boundary does not inspect the source buffer's
YCbCr-matrix attachment and must not be described as doing so.

## Service Activation and Failure Policy

`DefaultUpscalerEngineService.runJob` implements the locked sequence:

1. Probe the input.
2. Select and validate the supported route.
3. Obtain the complete published V3 artifact set.
4. Construct the route-specific locked backend.
5. Begin the media output session.
6. Process frames using only that backend instance.

This ordering rejects unavailable or invalid release assets before an output
session can create or mutate the destination.

The product bootstrap requests the locked backend. Development tools and tests
may inject an explicit P05 factory. There is no automatic fallback. Artifact or
runtime errors propagate through the job failure boundary and are recorded by
the job telemetry recorder; the richer artifact identity described below is not
yet implemented.

Activation is prohibited until all of these conditions are evidenced:

- a fresh current-source G04 pass;
- a fresh current-source G05 pass;
- a selected, complete, immutable P06 release and G06 pass;
- a G07 locked-holdout pass over the exact release bytes;
- bundled resource bindings that reproduce the authorized release hashes;
- backend integration tests over both routes and all supported code ranges.

P08 Metal parity and performance remain required before representing the path
as the production-performance implementation.

## Remaining Telemetry and Output Identity Requirements

The current implementation records stage, counter, and error telemetry, plus an
in-memory locked frame summary. It does not yet record the release artifact
identity in job telemetry or bind that identity into exported output. Before
release activation, record once per job:

- configuration ID;
- release-manifest SHA-256;
- selected route;
- LUT whole-file and payload SHA-256 values;
- locked luma/chroma coordinate and anisotropy modes;
- analysis-grid source step.

Record aggregate counts for affine correction, affine fallback, numerical
fallback, declared primary/secondary candidates, and actual operator
invocations once invocation-level accounting exists. Do not emit source pixels,
state grids, local feature values, filesystem paths, or unbounded per-pixel
events.

Output identity must bind the locked configuration ID, manifest hash, route LUT
hash, format version, and spatial-only status. A job with any numerical fallback
may complete only if the existing locked runtime returns its declared
conservative result; telemetry and output identity must record the count.

## Incremental Implementation Slices

Slices 1-5 were reviewed, approved, implemented in `47e9cef`, and merged through
PR #7. The remaining slices are evidence and performance gates, not missing
fallback behavior.

| Slice | Status | Evidence boundary |
| --- | --- | --- |
| 1. V3 release artifact loader | Complete | Version-specific manifest, atomic store, immutable bytes, and corruption tests |
| 2. Shared NV12 frame codec | Complete | Development and locked backends share extraction/write arithmetic with regression tests |
| 3. Locked frame pipeline | Complete | Both routes and all three planes execute over generated locked fixtures |
| 4. Locked backend | Complete | Route-specific backend, deterministic repetition, diagnostics reset, and pre-write rejection tests |
| 5. Service wiring | Complete | Product bootstrap selects the locked factory; artifact failure precedes media-session creation |
| 6. Gate closure | Open | Local source guardrails passed, but authorized resources and fresh G04-G07 evidence are absent |
| 7. P08/G08 | Open | Metal parity, determinism, performance, and memory evidence is not implemented or claimed |

## Required Verification

Implemented artifact-store tests prove atomic publication and caching for a
complete generated set, and rejection without publication for:

- a missing or additional resource;
- a route-swapped LUT;
- mutated LUT bytes;
- noncanonical manifest bytes; and
- an invalid manifest self-hash.

Existing format-1.2 tests separately cover strict configuration schema and
self-hash handling, independent oracle parity for both routes, deterministic
header and parameter bindings, plane-local source-exact behavior, spatial
temporal-context mirrors, and resealed header or semantic corruption.

Exact-release verification must still exercise the complete corruption matrix
against the published bytes, including truncation/extension, file binding and
size mismatch, a LUT from a different configuration, and every unknown or
reserved value taxonomy.

Implemented runtime tests prove with generated fixtures:

- one artifact load per artifact set and zero loads per frame;
- one analysis traversal and exactly two dispatch-grid constructions per frame;
- route- and plane-local coordinate and anisotropy behavior;
- Cb and Cr independence while sharing the chroma dispatch grid;
- source-aligned exactness where the LUT declares it;
- legal-range finite output and exact route dimensions;
- one primary and at most one secondary candidate declared per LUT dispatch;
- no development selector or compiler invocation from the locked call graph;
- deterministic repeated output for identical input bytes and artifacts.

The declared candidate-budget assertion is not an invocation-level ceiling. A
recoverable candidate failure can invoke the conservative evaluator after the
candidate attempt. P08 performance work must count actual invocations.

Current service integration tests cover job completion with an injected backend,
failure before session creation, active-session cancellation, terminal cleanup,
and single-job exclusion. Exact-release integration must still preserve frame
timing, audio passthrough, progress, cleanup, code range, and chroma-siting
metadata over both authorized route LUTs.

The 2026-07-16 implementation validation recorded:

- 280 tests executed, with 279 passes, one expected skip, and zero failures;
- strict SwiftLint over 172 files with zero violations;
- successful Debug and Release builds;
- a successful repository guardrail run; and
- a successful app build-and-launch smoke check.

These results validate source wiring and generated fixtures. They are not fresh
G04-G07 evidence and do not authorize any release artifact.

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

The code-wiring slices are complete: the default composition requests the locked
factory, no P05 selector is reachable from that path, generated fixtures cover
both route runtimes, and invalid artifacts fail before output-session creation.

The release completion criterion is not met. It requires the default app path to
consume an authorized immutable V3 artifact set, both bundled route LUTs to
reproduce their locked CPU reference outputs, current G04-G07 evidence to pass
against the exact bytes, artifact/output identity telemetry to be completed,
and P08/G08 to establish the Metal production-performance boundary.
